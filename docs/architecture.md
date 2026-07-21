# Architecture (detailed)

This is the full implementation-detail walkthrough of the five phases
summarized in `CLAUDE.md`. Read that file first for orientation; come here
when you need the specifics of how a phase actually works. Domain vocabulary
(Spec, Arg, Variant, Validator, etc.) is defined in `CONTEXT.md` — this file
assumes that vocabulary and focuses on code-level mechanics. See
`docs/gotchas.md` for Nim-language/compiler traps hit while building this.

## 1. Spec construction (`src/argumint.nim`)

User calls `arg`, `opt`, `flag`, `command`, `help` to build a tuple of `Arg`
objects, then `newSpec`/`parse` assembles them into a `Spec` (`backend.nim`).
Each arg is indexed into `spec.arguments` (positional, keyed by `<name>`),
`spec.options` (optional/flag, keyed by `-o`/`--option`), or `spec.commands`
(subcommands, keyed by the command word). If no `usage` string is given, one
is auto-generated from the declared args (see "autoFillUsage" below).

## 2. Usage-string compilation → FSM (`lexer.nim` → `parser.nim` → `backend.nim`)

The usage string (e.g. `[-r] <src>... <dest>`) is tokenized by `SpecLexer`
and recursively-descent parsed (`atom`/`sequence`/`choice` in `parser.nim`)
into a graph of `State`/`Transition` objects. Each token becomes a `Matcher`
(`Argument`, `Option`, `Options`, `Command`, or `Shortcut` for
optional/repeated branches). `backend.prepare` (`simplify` +
`sortTransitions`) collapses shortcut chains and orders transitions by
matcher priority (`ord(MatcherKind)`) so, e.g., positional args aren't
greedily consumed ahead of options. `simplify` collapses shortcuts via an
epsilon-closure per state (`shortcutClosure`) rather than iterative
delete-and-copy, so it terminates even when shortcut edges form a cycle
spanning more than the immediate state being simplified — see
`docs/gotchas.md`. The per-line lex/parse/splice loop
itself lives in `parser.addUsageLines` (shared with `autoFillUsage`, see
below); `genFsm` calls it once for every line in `spec.usage`, then calls
`result.prepare()` directly after.

`dot.nim` renders any FSM to Graphviz dot for debugging/visualization but is
not called anywhere by default — wire up `spec.fsm.dot` (or `cmd.spec.fsm.dot`
for a subcommand) manually when debugging FSM construction.
`scripts/dot2png.sh` renders that dot output to a viewable PNG (requires
Graphviz's `dot` CLI installed separately).

While parsing a Usage Line, `atom`'s own `tkShortOption`/`tkLongOption`/
`tkShortOptions` branches record each option they see into
`SpecParser.explicitOptions` (reset per line, not once for the whole Usage
String), so the `[options]` catch-all (`tkAnyOption`) can exclude them from
its own `Options` matcher — e.g. in `[options] --verbose`, `--verbose` can
only be matched once (via its own explicit atom), not once via `[options]`
and again via the explicit mention. Because a `[options]` atom earlier in
the line can't yet know about an explicit mention later in the same line,
its `Options` matcher is built unfiltered and its `Matcher` (a `ref`, see
`backend.nim`) stashed in `SpecParser.pendingOptions`; once the whole line
is parsed and `explicitOptions` is final, `addUsageLines` patches each pending
matcher's `opts` in place. Using the `Matcher` itself (rather than its
surrounding `Transition`) for this is what makes the patch stick: `sequence`
composes atoms by copying each one's transitions onto its own growing
state, so a captured `Transition` would go stale the moment that copy
happens, but the `Matcher` ref travels with it. An option named explicitly
on one Usage Line is unaffected on a different Usage Line, where it remains
reachable through that line's own `[options]`. See
`docs/adr/0002-catch-all-options-repeatable-by-default.md` for why the
catch-all's default differs from an explicitly-named Arg's.

## 3. Runtime matching (`fsm.nim`)

Actual `os.commandLineParams()` (or passed-in `args`) are first split into
`RawToken`s (`tokenizeArgs`) via *shape-only* recognition — no `Spec`
lookups at all: does a token look like `-o`/`--opt`/`-o=val`/`--opt=val`/a
`-xyz`-shaped cluster candidate, or is it a literal `--`? This is the only
thing that's genuinely position-independent; everything else about a raw
token's meaning depends on which `Spec` governs this position, which is
only known once the walk has actually gotten there (see below).

`walk` then recursively tries the FSM's transitions against the token
stream, backtracking via a copied `ParseContext` (`fresh = pc`) on each
branch attempt, accumulating the best-effort error `messages` from the
deepest failed path so error messages point at the most specific match
attempt, not just "invalid arguments". Classification of *what a `RawToken`
actually is* — Command, Option/Flag (and which one), or plain positional
text — is decided lazily, inline, by `match`'s own `Command`/`Option`/
`Options`/`Argument` branches, each checking a token's fitness for *itself*
against `pc.spec` (the Spec currently in scope for this specific walk
attempt, already updated by a matched `Command` transition) rather than
trusting a precomputed global answer:

- **Command** checks the raw string against `pc.spec.commands` directly.
- **Option**/**Options** resolves cluster-splitting/attached-`=value`
  syntax against `pc.spec.options`; if the shape doesn't resolve to any
  declared option at all, the matcher simply doesn't match — no
  exception — leaving the token for a different matcher to try.
- **Argument** accepts the first available raw token outright, no shape
  check at all. This is safe because `State.prepare`'s priority sort
  (`Option < Options < Command < Argument`, see §2) already tries
  Option/Command transitions at the same grammar position first —
  Argument only gets a turn once those have already failed to claim the
  token.

This is why a word that happens to be a declared Command name can still be
used as a plain positional value in a *different* Usage Line, why a
negative number like `-1` is accepted as a positional value with no
disambiguation needed when nothing else could claim it, and why an
option-shaped token unrecognized by one Usage Line can still fall through
to a more permissive alternative instead of raising immediately — none of
these require special-casing, they fall out of deferring the decision to
the same backtracking machinery that already exists for everything else.
`ParseContext` being a plain value `object` (not a `ref`) is what makes
this safe without a separate cache: a failed branch attempt's guesses are
simply discarded along with the rest of its `fresh` copy, and a different
attempt that revisits the same raw position starts from its own
independent copy and reclassifies independently. See
`docs/adr/0019-lazy-token-classification.md`.

A literal `--` is recognized in the same eager shape pass and, the first
time the walk encounters it on a given path, sets `pc.optsEnd = true`
(dropped, never handed to any matcher as a value) — from then on, on that
path, Option/Options/Command stop resolving shapes/names entirely and
every remaining token is available to Argument only, exactly as before.

A successful walk populates `pc.matches: OrderedTable[Arg, seq[Match]]`,
which is then fed back into each `Arg`'s `parse` method to actually
convert/store values.

After a successful walk, `Spec.parse` (`fsm.nim`, not to be confused with
`Arg.parse` above) does one more pass entirely outside the FSM/backtracking
machinery, via `applyFallbacks`: for every `Arg` in `spec.args` that
*wasn't* explicitly matched (`arg notin matches`), it tries the
environment-variable tier, then — only if that had nothing — the Config
Source tier, calling `arg.setFromEnv(...)`/`arg.setFromConfig(...)` to
apply whichever tier's value through the same conversion/validation path a
CLI value would take. Doing this after `walk` rather than folding it into
the FSM means an option only reachable via `[options]` (never explicitly
attempted during matching) still picks up a fallback value, and `arg notin
matches` gives an explicit CLI value precedence for free with no extra
bookkeeping. See `docs/adr/0004-required-options-env-fallback.md`,
`docs/adr/0005-env-supplied-multi-value-options-and-flags.md`, and
`docs/adr/0018-config-source.md` for the design decisions behind the two
fallback tiers; CONTEXT.md's Value Precedence / Env Delimiter / Config
Source entries have the user-facing semantics.

### Env var / Config Source mechanics

Value Precedence's environment-variable and Config Source tiers share one
mechanism, `fsm.nim`'s `ValueCursor` type (embedded twice on
`ParseContext`, as `env` and `configValues`), rather than two independent
implementations. `ValueCursor.probe` is consulted from `match`'s `Option`
branch during the walk — CLI token first, then `pc.env.probe`, then (only
if env had nothing) `pc.configValues.probe` — lazily resolving and caching
an Arg's available values (via a tier-specific `resolve` closure,
`resolveEnv`/`resolveConfig`) and handing out the next unconsumed value
each time that Arg's matcher is visited. `resolve` runs at most once per
Arg per cursor (cached in `ValueCursor.tried`, including a miss) — cheap
either way for env (`existsEnv`), but load-bearing for Config Source, since
a user-supplied `ConfigSource.lookup` may be arbitrarily expensive. Nothing
decides in advance how many times a matcher gets visited — it falls out
entirely from however many times `walk` actually visits it: a real repeat
(`...`, or reachable only through `[options]`) loops back and keeps
consuming until the list runs out; the same Arg named more than once in one
Usage Line with no `...` is just two separate matcher instances, and the
cursor is consulted twice either way.

The two tiers differ only in how they arrive at that per-Arg `seq[string]`
of candidate values. `resolveEnv`: the raw env string is always split
(`backend.splitEnvValue`) — on `\x1e` (ASCII Record Separator) if present,
since that's how fish auto-joins a native list variable's elements when
exporting it to a subprocess, otherwise on `Spec.settings.envDelim`
(cascades like `width`, default `:`), keeping empty segments as literal
values rather than dropping them. `resolveConfig`: `arg.configKey` is
looked up via `lookupConfigSources(spec.settings.configSources, key)`,
which already returns an assembled `seq[string]` (the last layered source
with a hit for that key, in full — see CONTEXT.md's Config Source entry
for why there's no delimiter-splitting step here at all).

After a successful walk, `Spec.parse`'s post-walk sweep (`applyFallbacks`,
via the per-Arg, per-tier helper `applyTier`) applies exactly as many
values as the walk consumed for each Arg from whichever tier supplied them
(cached on that tier's own `ValueCursor`), falling through to the
Config Source tier only when the env tier had nothing at all for that Arg;
if values are left over (the tier had more than the grammar had positions
for), that's a `ParseError` — `"unexpected option"`/`"unexpected flag"`,
the same wording already used for a genuinely excess CLI token — rather
than a silent truncation to a prefix of the values. An Arg whose matcher
was never consulted at all this walk (reachable only through a different,
unmatched Usage Line of the same spec) has no walk-derived count to bound
it by, so every available value from whichever tier resolves is applied.
For `flag`, each value (from either tier) names one of the Arg's own
declared Variants (matching `self.ops`' keys exactly) and is applied via
*that* Variant's own Flag Operation, not forced through `=`.

A pre-existing nuance, not introduced by the Config Source tier: since
`applyFallbacks` gates on `arg notin matches` per-Arg (not per-position),
an Arg reachable at more than one position in the matched Usage Line where
*some* positions matched a real CLI token and others were satisfied by a
fallback tier *during the walk* (via `probe`, which never writes to
`pc.matches`) has its walk-time fallback contribution silently dropped —
`applyFallbacks` never even looks at it, since the Arg already has a real
match. See `docs/adr/0018-config-source.md`'s "Consequences" section.

## 4. Value conversion (`src/argumint.nim`, top)

`ValueArg[T: not seq, multi: static bool]` / `FlagArg[T]` are generic ref
objects holding a parsed `Option[seq[T]]`/`T`. A single `ValueArg` type backs
both scalar args (instantiated as `ValueArg[T, false]`, storing its value as
a 1-element seq) and multi-value args (instantiated as `ValueArg[T, true]`,
appending on each match). `arg*`/`opt*` construct the scalar arity only
(`default: T = ""`); the multi-value arity is built by the separate
`args*`/`opts*` procs (`default: seq[T] = newSeq[T]()`) — see
`docs/gotchas.md` for why these are separate procs rather than an overload.
Because `multi` is a `static bool`, `ValueArg[T, false]` and `ValueArg[T,
true]` are distinct concrete types to the compiler, so `toT`/`toSeqT` can be
overloaded per-arity without ambiguity.

`defineArg[T]` is a template that generates a `method parse` for a given `T`
(both arities) by calling `parseImpl`, which converts the raw string via an
implicit `converter` (`toInt`, `toFloat`, `toBool`, `toChar`; strings pass
through) and then runs the arg's `Validator[T]` (`validators.nim`) if
present — validation always happens against the scalar element type, never
`seq[T]`, since it runs before the value is stored/appended. `defineArg[T]`
also generates a per-arity `method defaultStr`, used by `genHelp` to render
`[default: <value>]` in help text (stringified via `$`; suppressed when the
scalar default equals `T`'s zero value — `default(T)` — since that's the
fallback used when no default was given). The base `Arg.defaultStr`
(commands, flags, message args) returns `""`, so flags never show a default.
`defineArg[T]` likewise generates a per-arity `method validatorHelp`, which
calls `self.validator.help()` when a validator is present — `Validator[T].help`
returns a short description per kind, or every kind's own `desc` verbatim
instead when one was given (`Validator[T].desc` is a single field shared by
every kind, declared *before* the `case kind` discriminator rather than
inside a specific `of` branch — a field name can't be redeclared across two
separate `of` branches even with an identical type in each, but a field
declared ahead of the `case` is implicitly shared by all branches). `genHelp`
combines `validatorHelp` and `defaultStr` into one bracket, `;`-separated
(e.g. `[choices: foo, bar; default: foo]`). `defineFlagArg` (see "Flags"
below) also generates a `method validatorHelp` for `FlagArg[T]` -- reusing
the same extension point, even though a Flag never carries a `Validator` --
delegating to its `FlagClamp[T].help()` if one is attached (see "Flag
Clamp" below). `FlagArg` still has no `defaultStr` override, so a flag's
coded default never appears in help output regardless of whether it has a
clamp.

Every one of these generated methods, plus `parseImpl`'s own exception
handlers, calls into `validators.nim`/`backend.nim`/`std/strutils` by their
bare (unqualified) names -- `argumint.nim`'s top-of-file `export`
statements are what make that resolve correctly for a caller registering
their own custom type via `defineArg`/`defineFlag`/`defineSetFlag`, not
just for code living inside `argumint.nim` itself. See
`docs/adr/0017-argumint-reexports-for-custom-arg-types.md`.

### Flags

Flags don't take user converters — instead `defineArg[T](typeName,
flagHandler)` registers per-type flag operations (e.g. `=`, `+=`, `-=` for
`int`) via the `defineFlagOps` macro, stored in the `flagOps` `CacheTable`
and looked up by `getFlagOps` at spec-construction time to validate that a
flag variant's requested op (parsed out of the variant string itself, e.g.
`--verbose+=2`) is actually supported for that type.

Each variant's `(op, value)` (plus an optional user-supplied override) is
stored as a `FlagOp[T] = tuple[op, arg, desc]` in `FlagArg[T].ops`, keyed by
the bare variant name. `defineArg`/`defineFlag` also generate a `method
variantDesc` per type, used by `genHelp` (via the `variantGroups` helper) to
auto-describe a flag variant when its behavior diverges from its siblings:
`desc` (if the user supplied one via `flag*`'s `variantHelp: Table[string,
string]` param) wins, else it falls back to generic wording from `op`/`arg`
— `"Set to {arg}"` (`=`), `"Increase by {arg}"` (`+=`), `"Decrease by
{arg}"` (`-=`), all type-generic. Blank op (`""`) has no generic wording
since its meaning is type-specific — `defineArg[T](typeName, flagHandler)`
leaves it as `""`, while `defineFlag[T](typeName, blankDesc, flagHandler)`
lets a type's author supply it (`bool`/`int` use this for `"Toggle the
value"`/`"Increment by 1"`).

`defineArg`/`defineFlag`/the private `defineFlagArg` they both delegate to
are three separately-named templates (see `docs/gotchas.md` for why they
can't be overloads of one name).

`defineSetFlag*[E: enum](elemType: typedesc[E])` is a ready-built extension
on top of this same mechanism, registering flag support for `set[E]`: each
variant's value names one element of `E`, and `=`/`+=`/`-=`/`*=` set/
include/exclude/intersect it (`value = value * arg` for `*=`). Call it once
per concrete enum before declaring `flag[set[E]](...)`, the same opt-in
discipline as `Priority`/`Level`/`Speed`. Plain `set[int]` isn't supported
(Nim's `set` needs a bounded ordinal) — enum element types only.

`flag*`'s `variantValues: Table[string, T]` param (keyed by bare flag name,
same convention as `variantHelp`) is the escape hatch from string parsing
entirely: a variant's `arg: T` can be supplied directly as typed Nim code
instead of text in `variants` — useful for a `T` with no natural short
string spelling, or a multi-element `set[E]` variant (e.g.
`variantValues = {"--warm": {red, orange, yellow}}.toTable`). A variant may
get its value from `variants` or `variantValues`, not both (`SpecDefect` if
both are given); `<op>` always comes from `variants` regardless.

### Flag Clamp

`FlagClamp[T]` (`argumint/flagclamp.nim`) is a leaf module with no
dependency on `backend`/`argumint`, deliberately structured to mirror
`Validator[T]` (`validators.nim`) without being one -- see
`docs/adr/0016-flag-clamp.md` for why the two are kept separate. It's a
`case`-discriminated `ref object` with two kinds, built via two
constructors: `clamp[T](bounds: Slice[T], desc = "")` (requires `T` to
support `<`, duck-typed at the point `apply` is called, same as
`Validator.range`) and `adjust[T](proc: proc(v: T): T, desc = "")` (any
`T`). Not named `range` -- that collides ambiguously with `validators.range`
the instant both modules are imported into the same file, which
`argumint.nim` does; Nim doesn't disambiguate two identical-signature
generic procs by the caller's expected return type, so this needed a
distinct name, not just a preference. Named simply `clamp` -- confirmed by
scratch compile that it doesn't collide with `system.clamp`/
`std/math.clamp`: both of those take a bare value as their required first
arg, a different shape from this proc's required `Slice[T]` first arg, so
Nim's arity/type-based overload resolution never considers them for a
`clamp(0..10)`-shaped call. `apply[T](self, value): T` performs the actual
adjustment (`std/math.clamp` for the range kind, `self.adjustProc` for
`adjust`), and `help[T](self): string` returns `self.desc` if set, else an
auto-generated `"clamp: a..b"` for the range kind or `""` for `adjust` (an
arbitrary proc has no description to generate). `help` is the same name as
`validators.help[T](self: Validator[T])`, and unlike `range`/`clamp`
above, this isn't a real collision: the two take different concrete
parameter types (`FlagClamp[T]` vs `Validator[T]`), which Nim's overload
resolution filters on before return type would ever matter, so both can be
named `help` and coexist without ambiguity.

A separate, genuinely real issue applies regardless of `FlagClamp`'s own
naming, and applies to registering *any* custom Arg type, not just a
`FlagClamp`-using one: see `docs/adr/0017-argumint-reexports-for-custom-arg-types.md`
and `docs/gotchas.md`.

`flag*`'s `clamp: FlagClamp[T] = nil` param stores directly onto
`FlagArg[T].clamp`. `defineFlagArg`'s generated `parse*`/`setFromEnv*`
(the same two methods that call `self.value.handleFlag(op, arg)` for every
Flag Operation, CLI- or env-sourced) each call
`self.value = self.clamp.apply(self.value)` immediately afterward when a
clamp is present -- so the clamp runs once per Flag Operation actually
applied, not once per `parse*`/`setFromEnv*` invocation (`setFromEnv*` can
apply several operations in its own loop, one per env-supplied value).
`flag*` itself also runs `clamp.apply(default) != default` once, at spec
construction, before returning -- since `FlagArg.value` is seeded directly
from `default` with no separate substitution tier the way `ValueArg`'s
default has (contrast the previous section's `defineArg[T]`, where the
default is stored separately and never even passed through `Validator`), a
default that doesn't already satisfy its own clamp is a `SpecDefect`, not
something silently corrected at runtime.

### Env values, validators, help layout

`opt*`/`opts*`/`flag*` (not `arg*`/`args*` — env vars map naturally to a
named value, which a Positional Argument doesn't have) take an `env` param
naming an environment variable — see the Runtime Matching section above for
the mechanics and `docs/adr/0004`/`docs/adr/0005` for the design rationale.

`Spec.settings.width` (default `terminalWidth()`, itself falling back to
`DefaultWidth = 80`) and `Spec.settings.maxVariantsWidth` (default
`DefaultMaxVariantsWidth = 30`) control `genHelp`'s wrapping: `width` wraps
usage lines (`formatUsage`) and each row's help/description text, while
`maxVariantsWidth` caps the "variants" column (e.g. `-v, --verbose,
--quiet`) so one arg with many aliases can't inflate the shared column width
for every other row. `genHelp` goes through `arg.variantGroups()`
(`argumint.nim`, near `genHelp`), which groups an arg's variants by their
`variantDesc` text and returns one group per distinct behavior. `colWidth`
is computed from the widest single group's joined names, not the widest
whole-`Arg`'s. Each group becomes its own row: the first group keeps the
arg's shared `help` text and uses the normal 2-space row margin — plus, only
when `variantGroups().len > 1` and its own `variantDesc` is non-empty, that
desc is appended as `[action: ...]` (deliberately labeled `action:`, not
`default:`, so it can't collide with a hypothetical future `[default:
<value>]` for a flag's own starting value). Any further group shows its own
`variantDesc` text instead and is indented with the same 4-space
`continuationIndent` used for wrap-continuation lines. When a row's variants
exceed the cap, `genHelp` wraps them into their own `wrapWords`-wrapped lines
and zips them line-by-line against the (independently wrapped) help-text
lines, so the help text stays inline with the first wrapped variants line.
`0` disables the cap.

`width`/`maxVariantsWidth`/`envDelim`/`configSources` live together on
`Spec.settings: SpecSettings` (`src/argumint/backend.nim`), a `ref object`
built once by `newSpec*`'s `settings = newSpecSettings()` param and shared
by reference — not copied — into every nested subcommand's `Spec` via
`cascadeSpecSettings` (`src/argumint.nim`). `settings` is deliberately not
a parameter to `command*` itself: since it's the same shared instance
throughout the tree, it only needs to be set once at the top-level
`newSpec`/`parse*` call regardless of nesting depth. Being a ref rather
than four plain fields also means a later mutation of that same
`SpecSettings` — e.g. from a `before` hook — applies live to every
not-yet-dispatched `Spec` in the tree, including the current level's own
message/help output once `parseMessageArgs` runs after `before` (see
`docs/adr/0013-message-args-fire-after-before.md`). `envDelim` and
`configSources` are the exceptions: both fallback tiers' resolution
(`applyFallbacks`, §3) runs to completion across the whole tree before
`dispatch`/any hook is ever called, so a hook-time mutation to either has
no effect on that parse's fallback-tier handling, even though both are
cascaded the same way for consistency (see
`docs/adr/0018-config-source.md`'s "Corrected claim" section for the
Config Source case specifically).

Converters `toT*[T](arg: ValueArg[T, false]): T` and `toSeqT*[T](arg:
ValueArg[T, true]): seq[T]` return the field's value transparently at
use-sites — code reads `spec.dest` rather than `spec.dest.value`.

## 5. Subcommands

`command*` builds a `CommandArg` wrapping its own nested `Spec` (built via
`newSpec` from a nested arg tuple), optionally binding `before`/`action`/
`after` hook closures onto that nested `Spec` (not onto the `CommandArg`
itself — see below). A subcommand's FSM is spliced into the parent's FSM
as a single `Command`-kind transition (see `atom()`'s `tkCommand` branch in
`parser.nim`), with all of the subcommand's terminal states wired via
shortcut back to a single continuation state in the parent graph.

### Dispatch order

Runtime matching (§3 above) populates one flat `pc.matches:
OrderedTable[Arg, seq[Match]]` across the *entire* spliced FSM, regardless
of depth. Each `Match` additionally carries the `Spec` it was recorded
under (`fsm.nim`'s `push`, reading `pc.spec` at the exact moment of the
match — safe because `ParseContext` is a plain `object`, not a `ref
object`, so `walk`'s backtracking clones it per candidate branch and only
commits the winning branch back) — this is what lets dispatch scope a
match to the correct level even when the same `Arg` is reachable at more
than one grammar level.

After a successful walk, `Spec.parse`'s final step recursively re-walks
the *declared* Spec tree — not `pc.matches` itself, which carries no scope
information on its own — via `dispatch(spec, pc.matches, command)`. At
each `Spec` level: `parseOwnValues` parses that level's own non-Command,
non-`MessageArg` matches (filtered by the `Match`'s `Spec` provenance);
`spec.before()` fires, if set, now that those values are ready;
`parseMessageArgs` then parses (and raises on) any matched `MessageArg`/
`HelpArg` at this level; `matchedCommand` finds whichever single Command
was matched at this level, if any (at most one ever can be — a matched
`Command` transition permanently updates `pc.spec` to the nested spec for
the rest of the walk, so a sibling command word can never be recognized
afterward);
if none, `spec.action()` fires (this Spec is the dynamic leaf for this
invocation); if one, `dispatch` recurses into its own nested `Spec`;
finally `spec.after()` fires, wrapped in a `try/finally` around the
message-arg/action-or-recursion step so it's guaranteed to run once
`before` (or its absence) has completed without raising, regardless of
what happens afterward — including a `MessageArg` match, which is treated
as this level's action-equivalent for firing purposes: it runs after
`before` and inside the same `try/finally`, so `before`-time state changes
are visible to it and `after` still fires as cleanup even though it raises.
Applied recursively, this gives `before` a root-to-leaf firing order,
`action`/a matched `MessageArg` firing exactly once at whichever level
turns out to be the leaf, and `after` a leaf-to-root order — and, since
each level's `after` is reached via its own `try/finally`, an ancestor
whose `before` already ran still gets a chance to clean up even when
something nested inside it fails, with no explicit bookkeeping. See
`docs/adr/0009-command-before-action-after-hooks.md` and
`docs/adr/0013-message-args-fire-after-before.md`.

## `autoFillUsage`

`newSpec` builds the FSM first, then calls `autoFillUsage` to patch any
gaps: it uses `backend.referencedArgs` to collect every `Arg` actually
referenced by a matcher, then appends usage lines for whatever isn't
reachable. Rather than rebuilding the FSM from scratch a second time (which
would re-lex/re-parse every line, including ones already built moments
earlier), the newly-appended lines are spliced directly onto the existing
`spec.fsm` root via the same `parser.addUsageLines` `genFsm` itself uses,
then `spec.fsm.prepare()` runs once more over the combined graph.
`addUsageLines` itself recomputes the root's `terminal` flag after splicing
(true only if the root still has no transitions at all), so neither caller
needs to know that a spec which started with a fully empty `usage` string
left that flag `true` and now needs it cleared. This runs regardless of
whether `usage` was left blank or passed in explicitly, and the fill-in rule
differs by category:

- **Commands** that are unreachable are joined into a single `(cmd1 | cmd2)`
  alternation line (all their variants flattened into one `|`-list) rather
  than one line per command, so a shared `[options]` prefix isn't repeated
  for each one. **`MessageArg`s** (e.g. `help()`) are still filled in
  per-arg — each missing one gets its own appended line — since they never
  carry the `[options]` prefix to begin with and are independently optional
  to mention. Mentioning one variant of a multi-variant arg counts as
  reachable; it won't be duplicated.
- **Positional args** are all-or-nothing: only auto-appended (as one joined
  `<a> <b>` line, in declaration order) when *none* of them are reachable
  yet. A partially-specified sequence is left alone.
- **Options** (`opt`/`flag`, non-`MessageArg`) aren't their own usage line;
  `[options]` rides along as a prefix on whatever command/positional line
  gets auto-appended above. If nothing else gets appended but some option is
  still unreachable, a standalone `[options]` line is added as a fallback.
  Weaving `[options]` into an arbitrary hand-written line that's missing it
  is not attempted.

## 6. Shell completion (`fsm.completeArgs*`, `completion.nim`)

A compiled binary's `parse*`/`parseOrQuit*` intercepts a magic leading arg,
`mycli __complete <partial words...>`, before any real FSM matching, env
fallback, or dispatch — short-circuiting into `fsm.completeArgs*`, which
re-walks `spec.fsm` to resolve candidates dynamically rather than via a
static generated script. See
`docs/adr/0012-fsm-driven-shell-completion.md` for why.

`fsm.collectFrontier` generalizes `walk`'s single-winner backtracking into
"every state simultaneously still reachable after consuming the tokens
typed so far" (a `Frontier`), since several Usage Lines or `choice`
alternatives can all still be live for a command line that isn't finished
yet. It reuses `Matcher.match` unmodified, so env-var fallback (`docs/adr/
0004`, `docs/adr/0005`) applies to completion exactly as it would to a real
parse. `completeArgs*` reads each live frontier state's own outgoing
transitions for next-word candidates (`candidateWords`) — or, when the last
already-typed word is itself a bare Optional-kind option name still
awaiting its value (`pendingOptionalArgs`), completes that Arg's own
`completions()` instead (populated from a `Validator`'s enumerable
candidates — see `validators.completions`/`Arg.completions`). Candidate
words are read from `spec.options` (the canonical bare-spelling → `Arg`
map `match`'s `Option`/`Options` branches themselves resolve against), not
`Arg.variants` directly — the latter, for an Optional-kind `ValueArg`
(`opt`/`opts`), still carries any declaration-time `=<placeholder>` suffix
used only for help-text rendering.

`completion.genCompletionScript*` generates a thin, mostly-static per-shell
adapter (`Shell = bash | zsh | fish`) that just shells out to
`<binaryName> __complete <words...>` and feeds newline-separated stdout
into that shell's own reply mechanism — it needs almost nothing about the
`Spec`'s own contents, since completion is resolved dynamically by the
binary itself. `parseOrQuit*` gives `CompletionError` (a `MessageError`
peer of `HelpError`) its own `echo`-based handling rather than reusing the
shared `except MessageError as e: quit(e.msg, QuitSuccess)` branch: `quit`'s
non-nimscript/js implementation writes to stderr, not stdout, which a shell
adapter's `$(...)` capture can't see.
