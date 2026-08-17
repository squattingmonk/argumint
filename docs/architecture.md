# Architecture (detailed)

This is the full implementation-detail walkthrough of the five phases
summarized in `CLAUDE.md`. Read that file first for orientation; come here
when you need the specifics of how a phase actually works. Domain vocabulary
(Spec, Arg, Variant, Validator, etc.) is defined in `CONTEXT.md` — this file
assumes that vocabulary and focuses on code-level mechanics. See
`docs/gotchas.md` for Nim-language/compiler traps hit while building this.

## 0. Module layering

Three modules are leaves with no local imports — `errors.nim`,
`configsource.nim`, and `flagclamp.nim` — and everything else layers on top:
`lexer` → `backend`/`validators` → `fsmgraph`/`parser` → `fsm` → `argumint`.

`errors.nim` holds every exception argumint raises (`SpecDefect`,
`ParseError`, `ValidationError`, `MessageError`, `HelpError`,
`CompletionError`). Keeping them in a leaf is what lets any module name an
exception without depending on whichever module raises it — `fsm.nim` needs
`ValidationError` but has no business importing the validator combinators,
and `lexer.nim` raises `SpecDefect` while staying free of everything above
it. The two modules whose own API would be incomplete without one
(`lexer.nim` for `SpecDefect`, `validators.nim` for `ValidationError`)
re-export it, so importing either alone still names what it raises.

## 1. Spec construction (`src/argumint.nim`)

User calls `arg`, `opt`, `flag`, `command`, `help` to build a tuple of `Arg`
objects, then `newSpec`/`parse` assembles them into a `Spec` (`backend.nim`).
Each arg is indexed into `spec.arguments` (positional, keyed by `<name>`),
`spec.options` (optional/flag, keyed by `-o`/`--option`), or `spec.commands`
(subcommands, keyed by the command word). If no `usage` string is given, one
is auto-generated from the declared args (see "autoFillUsage" below).

Match Accumulation is per-`Arg` lifetime, not per-parse, so a spec tuple is
single-use — parsing one twice appends to the same `ValueArg.value` and
re-applies a `FlagArg`'s Flag Operation. `parsed*`/`parsedOrQuit*` are the
fresh-spec-per-parse entry points; both take a builder `proc (): S` and call
it once per parse rather than copying an existing tuple, for reasons
`docs/adr/0031-parsed-fresh-spec-per-parse.md` records. All four tuple entry
points share one private `buildAndBind`, which builds the `Spec` and binds
`before`/`action`/`after` closing over the *same* tuple its caller returns.

Those index fields — along with `prolog`/`epilog`/`usage`/`args`/`fsm` — are
private to the library; only `Spec.settings` and the three hook fields are
exported (`docs/adr/0030-core-types-exported-spec-opaque.md`). Internal
modules reach the rest via `std/importutils.privateAccess(Spec)`, present in
`argumint.nim`, `fsm.nim`, and `parser.nim`. That call **does not survive
template or generic instantiation in another module**, so `newSpec*` — which
is generic over the spec tuple and therefore instantiates in the caller's
file — delegates its private-field work to two non-generic bookends,
`beginSpec` and `finishSpec`, leaving only the field-free `addArgs` generic
in between. Any new generic or template needing a private `Spec` field has to
be split the same way; see `docs/gotchas.md`.

## 2. Usage-string compilation → FSM (`lexer.nim` → `parser.nim` → `backend.nim`/`fsmgraph.nim`)

The usage string (e.g. `[-r] <src>... <dest>`) is tokenized by `SpecLexer`
and recursively-descent parsed (`atom`/`sequence`/`choice` in `parser.nim`)
into a graph of `State`/`Transition` objects (their data model lives in
`backend.nim`; the construction/simplification operations below live in
`fsmgraph.nim`). Each token becomes a `Matcher`
(`Argument`, `Option`, `Options`, `Command`, `OptsEnd` for a usage-string
End-of-Options Marker (`--`) -- see
`docs/adr/0020-usage-string-end-of-options-marker.md` -- or `Shortcut` for
optional/repeated branches). `fsmgraph.prepare` (`simplify` +
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
not called anywhere by default — wire up `spec.dot` (or `cmdArg.spec.dot` for
a subcommand) manually when debugging FSM construction. Those are
`argumint.nim`'s `dot*(Spec)`/`dot*(tuple)` wrappers; `spec.fsm.dot` reaches
`dot.nim`'s own `dot*(State)` directly and only compiles inside the library,
since `Spec.fsm` is private (see below).
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
failed path that got *furthest into the input* so error messages point at the
most specific match attempt, not just "invalid arguments". Classification of *what a `RawToken`
actually is* — Command, Option/Flag (and which one), or plain positional
text — is decided lazily, inline, by `match`'s own `Command`/`Option`/
`Options`/`Argument` branches, each checking a token's fitness for *itself*
against `pc.spec` (the Spec currently in scope for this specific walk
attempt, already updated by a matched `Command` transition) rather than
trusting a precomputed global answer:

- **Command** checks the raw string against `pc.spec.commands` directly —
  only at the very next position, never scanning further (a Command
  matcher never looks past position 0).
- **Option**/**Options** resolves cluster-splitting/attached-`=value`
  syntax against `pc.spec.options`, scanning forward past tokens that
  don't classify as *this specific* Arg; if a shape doesn't resolve to any
  declared option at all, the matcher simply doesn't match — no
  exception — leaving the token for a different matcher to try.
- **Argument** scans forward past tokens that classify as a real
  Option/Flag (`State.prepare`'s priority sort, `Option < Options <
  Command < Argument < OptsEnd < Shortcut`, see §2, already gave a real
  competing sibling transition first crack at the same token), accepting
  the first token
  that classifies as either plain positional text *or* a Command — a real
  Command matcher only ever looks at position 0, so nothing further down
  the scan could have legitimately claimed a Command-shaped token either,
  and skipping ahead in search of a later Positional would consume a
  repeating `<file>...`-style self-loop's values out of the order they
  were typed in. `classify`'s `Positional` and `Command` results carry the
  same `consumed`/`remainder` shape for the same raw token, so there's
  nothing left to distinguish once the scan has decided to stop — both
  are handled by one `of Positional, Command:` arm. That arm is gated by
  `refusesAsPositional` — Strict Option Checking, `SpecSettings.strictOptions`,
  default on: a `Positional` result that is option-shaped, unresolved, and
  not a Non-Option Short is skipped rather than accepted, so it survives as
  a leftover token for `finalComplaints` to name (see §3b). The same
  setting gates the value slot inside `classify` (`refusesAsValue`), so a
  declared Optional followed by an unrelated option starves instead of
  eating it. Both refuse rather than raise, keeping backtracking intact.
  See `docs/adr/0034-strict-option-checking.md`, which narrows ADR 0019's
  gap 3 without touching the classification mechanism itself.

  A post-`--` token is exempt because `refusesAsPositional` consults
  `pc.optsEnd` directly: `classify` short-circuits past all option-shape
  reasoning once end-of-options is crossed, which yields a plain
  `Positional` indistinguishable from an unknown option's, so the gate has
  to know about `optsEnd` itself rather than reading it off the result.

`classify` also carries a non-accepting outcome, `starvedOpt`/`starvedName`,
set when a token *is* a declared Optional but no value is available. That is
what lets the leftover complaint say `option --port requires a value` rather
than calling a name it recognizes unrecognized, and it is an error under
both settings.

Four failure paths ask that question — the `Option` matcher, the `Options`
catch-all, the `Argument` matcher, and `walk`'s tail — so
`addStarved` classifies the leading token for itself and returns whether it
complained, letting each caller fall back to its own blunter wording. Two of
them are why it can't simply be handed a `Classification` computed once:
`Options` rolls back each failed probe's messages, so the question has to be
re-asked *after* the rollback, and `Argument` reports its own `missing
argument` without ever reaching a terminal state's leftover token. It's also
added even when other complaints already exist, unlike the other leftover
wordings — a starved option can never be consumed as anything else, so it is
always the real error. The token blamed for starving it is named only when
genuinely unknown, so a declared option is never called unrecognized.

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
independent copy and reclassifies independently.

One place still needed decoupling despite that: `walk`'s merge step, which
records the furthest-reaching failed branch's spec/command for the final error
message, used to write into the *same* `ParseContext.spec`/`.command`
fields a later sibling transition's own `fresh` copy starts from — harmless
before this change (a failed Command descent could never be followed by a
sibling Argument attempt reusing the same leftover token), but reachable
now. `ParseContext` has dedicated `errorSpec`/`errorCommand` fields for
this, written only by the merge step and read only when formatting the
final failure message, so `.spec`/`.command` stay reserved for live walk
state. See `docs/adr/0019-lazy-token-classification.md`. `errorTokens`
(§3b) is a third field on the same terms.

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
machinery, via `applyFallbacks`: for every `Arg` in `spec.args` no
higher-precedence tier has already supplied (`arg.seenBy < byEnv`), it
tries the environment-variable tier, then — only if that had nothing — the
Config Source tier, calling `arg.setFromEnv(...)`/`arg.setFromConfig(...)`
to apply whichever tier's value through the same conversion/validation
path a CLI value would take, and recording that tier on `arg.seenBy`.
Doing this after `walk` rather than folding it into the FSM means an
option only reachable via `[options]` (never explicitly attempted during
matching) still picks up a fallback value; gating on `seenBy` gives an
explicit CLI value precedence *and* dedupes an Arg reachable from two spec
levels, both for free (see §5 and
`docs/adr/0039-per-arg-provenance.md`). See
`docs/adr/0004-required-options-env-fallback.md`,
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
`applyFallbacks` gates on provenance per-Arg (not per-position),
an Arg reachable at more than one position in the matched Usage Line where
*some* positions matched a real CLI token and others were satisfied by a
fallback tier *during the walk* (via `probe`, which never writes to
`pc.matches`) has its walk-time fallback contribution silently dropped —
`applyFallbacks` never even looks at it, since the Arg already has a real
match. See `docs/adr/0018-config-source.md`'s "Consequences" section.

## 3b. Failure reporting (`fsm.nim`)

Everything above concerns a walk that fails; this is what the user sees when
it does. Two channels accumulate during the walk, both on `ParseContext` and
both subject to the same replace-on-further / merge-on-tied bookkeeping at
the bottom of `walk`'s transition loop:

- **`messages`**, a `seq[Complaint]`. A `Complaint` is `(kind, subject,
  names)`. `kind` groups same-kind complaints onto one `|`-joined line at
  render time and is empty for a conversion/validation failure, which
  renders as a bare sentence under the same bullet. `names` marks a
  Complaint that points at a token the user actually typed — a property of
  the Complaint, never inferred from its wording, so ADR 0034's
  starved-option complaint participates without being special-cased.
- **`errorTokens`**, a `seq[Leftover]`: what a failed branch couldn't
  consume, plus the `Spec`/`optsEnd` needed to re-`classify` it. Recorded
  during the walk, worded only afterwards, so the wording can draw on the
  whole message rather than one branch's local view. Three recording sites:
  the tail of `walk` (a terminal state whose every transition failed — the
  general case); a failed `Command` matcher (the only place that knows a
  Command was expected *at this exact position*, and which fires whether or
  not the grammar has a terminal state the leftover could reach); and a
  failed `Option` matcher holding an unresolved option-shaped token, which
  likewise never reaches `walk`'s tail and is what names the headline
  `unrecognized option: --nope` case.

Which branch wins is decided by **Reach** (`CONTEXT.md`), not by how many
matchers it satisfied: where the first token it could not consume sits, whole
input if it consumed everything. That position is an `(idx, subIdx)` pair
compared lexicographically — a peeled Short-Option Cluster remainder keeps its
parent's `idx` (Flag Op composition order depends on that), so `subIdx` counts
letters already peeled to tell "got two letters into `-abc`" apart from "got
none", without ever outweighing a branch that reached the next argument. An
`Option` matcher scans ahead, so
counting matchers lets an options-only usage line skip the token the user got
wrong, match something later, and outrank the branch that understood the
leading input — see ADR 0036. A transition scores the greater of its own Reach
and its descendants', since a failed descent leaves this level's token list
untouched; being a global argv index, Reach is comparable across nesting
levels in a way `depth` never was.

`maxReach` only ever rises, including when a lesser branch's complaints
are adopted because nothing has complained yet — otherwise a branch that got
nowhere sets the bar every later sibling ties against, and gets to name the
offending token. The tie merge itself is deliberate: it is what accumulates
same-kind complaints onto one `|`-joined line.

`finalComplaints` then builds the message: word each leftover (as an
`unrecognized command` when a Command was expected there, otherwise from
`classify`'s answer), then drop every `missing option` — and `missing
command` too, if the named token stood in a command's position. One further
suppression happens at the complaint site itself, since only it knows the
context: the `Options` catch-all never complains at all, an option reached
that way being optional by construction.

The `Argument` matcher suppresses on the same terms, but has to be *told* its
context. `[X]` compiles to a Shortcut bypassing the group, and `prepare`'s
epsilon-closure collapses every Shortcut away, so by walk time the bracket
survives only as `State.terminal`. `walk` therefore passes the state's
terminality down as `match`'s `atTerminal`, and a matcher reached from a state
the grammar could have accepted at reports no `missing argument` — nothing was
owed there. It is a property of the *position*, not the `Arg`: preparation may
hoist one transition onto several states of differing terminality, and each
occurrence is judged on its own. See ADR 0037.

Note what is deliberately *not* suppressed: a `missing option` for an `Arg`
already in `pc.matches`. Membership answers "did this Arg match at all on
this branch", not "did the user supply every occurrence the grammar asked
for" — with `--foo=<v> --foo=<v>` and one `--foo` supplied, suppressing on
it empties the complaint list entirely. See ADR 0035. Nor is an alternation
arm: `(<a> | <b>)` reaches acceptance either way, but only by *consuming*, so
neither state is terminal and both stay reportable — which is why ADR 0037
keys on terminality rather than asking whether some accepting path skips the
`Arg` entirely.

`didYouMean` serves options and commands from one rule — Damerau–Levenshtein
(`osaDistance`, hand-rolled over `Rune`s since `std/editdistance` has no
transposition variant) within `min(2, max(1, n div 4))` of the candidate's
dash-stripped length, all best-distance candidates offered, sorted so
declaration order can't decide a tie. A candidate shorter than
`MinSuggestable` is skipped outright, which by the option PEGs' own shapes
means "never suggest a short option". Whether the *typed* token is eligible
at all is settled a level up, in `unknownOption`: a short-form token gets no
suggestion, decided before a candidate list is even built, since it can't
vary by candidate.

`unknownOption` narrows the *name* on the same reasoning it withholds the
suggestion: a short-form token is cluster syntax, so a run longer than two
characters is named by its first two — the one short option that failed —
and the tail, never tested and possibly holding declared options, is not
blamed. Because the name may then be neither what the user typed nor
something they'd recognize, the typed token comes along as ` (in -1.5)`,
omitted when it would only repeat the name. Peeling destroys that original,
so `RawToken` carries it in `cluster` (read via `userTyped`); `subIdx` cannot
stand in, being ranking-only and textless. See ADR 0038.

`formatComplaints` renders the bullets with no leading newline;
`raiseParseError`/`withUsage` (`backend.nim`) append the usage block; and
`parse*` wraps `applyFallbacks`/`parseAllValues` so a conversion or
validation failure — whose raise site in `arg.parse` has no view of the Spec
— comes out in that same shape. See
`docs/adr/0035-parse-failure-reporting.md`.

## 4. Value conversion (`src/argumint.nim`, top)

`ValueArg[T: not seq, multi: static bool]` / `FlagArg[T]` are generic ref
objects holding a parsed `seq[T]`/`T`. A single `ValueArg` type backs
both scalar args (instantiated as `ValueArg[T, false]`, storing its value as
a 1-element seq) and multi-value args (instantiated as `ValueArg[T, true]`,
appending on each match). `arg*`/`opt*` construct the scalar arity only
(`default: T = ""`); the multi-value arity is built by the separate
`args*`/`opts*` procs (`default: seq[T] = newSeq[T]()`) — see
`docs/gotchas.md` for why these are separate procs rather than an overload.
Because `multi` is a `static bool`, `ValueArg[T, false]` and `ValueArg[T,
true]` are distinct concrete types to the compiler, so `toT`/`toSeqT` can be
overloaded per-arity without ambiguity.

Both type names are exported, on the same terms as `Spec` — nameable, state
private — so an arg can cross a proc or module boundary
(`docs/adr/0033-value-arg-flag-arg-exported.md`). `FlagOp[T]` is not, since
`FlagArg.ops` is private. Tests reaching either type's fields need
`privateAccess` *per instantiation*, not once per generic.

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
Flag Operation's requested op is actually supported for that type.

A Flag's Variants are declared one of two ways (see `docs/adr/
0027-flag-op-declarations.md`): bare spellings in `flag*`'s own `variants`
string always share the type's implicit blank-op behavior against the
Flag's own `default`; `flagOp*(variants, op, value, help = "")` builds one
explicit `FlagOpGroup[T]`, passed to `flag*`'s `ops: varargs[FlagOpGroup[T]]`
param, with `op`/`value` mandatory (`flagOp*` validates `op` against
`getFlagOps($T)` itself, the same check the old string-parsing path used to
do inline). `flag*` flattens every declared group (the one implicit group,
plus each explicit `flagOp*` group) into `FlagArg[T].ops: OrderedTableRef[
string, FlagOp[T]]` (`FlagOp[T] = tuple[op, arg, desc]`, unchanged), keyed
by bare variant name, and builds `FlagArg[T].aliases` directly from each
group's own spellings -- no cross-group `(op, value)` comparison, since two
separately-declared groups are always independently reachable even if their
op/value happen to coincide.

`defineArg`/`defineFlag` also generate a `method variantDesc` per type,
used by `genHelp` (via the `variantGroups` helper) to auto-describe a flag
variant when its behavior diverges from its siblings: `desc` (a `flagOp*`
call's own `help` argument, if given) wins, else it falls back to generic
wording from `op`/`arg` — `"Set to {arg}"` (`=`), `"Increase by {arg}"`
(`+=`), `"Decrease by {arg}"` (`-=`), all type-generic. Blank op (`""`) has
no generic wording since its meaning is type-specific — `defineArg[T](
typeName, flagHandler)` leaves it as `""`, while `defineFlag[T](typeName,
blankDesc, flagHandler)` lets a type's author supply it (`bool`/`int` use
this for `"Toggle the value"`/`"Increment by 1"`).

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

Since a `flagOp*` call's `value: T` is always a real, already-typed Nim
value rather than text parsed out of a variants string, there's no
string-parsing escape hatch to speak of anymore -- a multi-element `set[E]`
variant with no natural short string spelling is just
`flagOp("--warm", "=", {red, orange, yellow})`, no different from any other
`flagOp` call.

### Flag Clamp

`FlagClamp[T]` (`argumint/flagclamp.nim`) is a leaf module with no
dependency on `backend`/`argumint`, deliberately structured to mirror
`Validator[T]` (`validators.nim`) without being one -- see
`docs/adr/0016-flag-clamp.md` for why the two are kept separate. It's a
`case`-discriminated `ref object` with two kinds, built via two
constructors: `clamp[T](bounds: Slice[T], desc = none(string))` (requires
`T` to support `<`, duck-typed at the point `apply` is called, same as
`Validator.range`) and `adjust[T](proc: proc(v: T): T, desc = none(string))`
(any `T`). Not named `range` -- that collides ambiguously with `validators.range`
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
`adjust`), and `help[T](self): string` returns `self.desc.get` if
`desc.isSome` (including `""` if `desc` is `some("")`, which suppresses
help output entirely -- see issue #12), else an auto-generated
`"clamp: a..b"` for the range kind or `""` for `adjust` (an arbitrary proc
has no description to generate). `help` is the same name as
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
whole-`Arg`'s. Each group becomes its own row using the same 2-space row
margin — groups are peers (different variants of the same `Arg`), not a
wrap continuation of one another, so they render at the same indent; only a
group's own text wrapping onto multiple lines uses the deeper 4-space
`continuationIndent`. Every group's row shows the arg's shared `help` text
and arg-level annotations (`validatorHelp`/`defaultStr`/`envName`/
`configKey`), not just the first-declared variant's — that repetition, not
indentation, is what visually ties divergent rows together as variants of
the same value. When `variantGroups().len > 1` and a group's own
`variantDesc` is non-empty, that desc is appended as `[action: ...]`
(deliberately labeled `action:`, not `default:`, so it can't collide with a
hypothetical future `[default: <value>]` for a flag's own starting value) —
but only when `help` is non-empty, since otherwise there'd be nothing for
the bracket to disambiguate from; in that case each row shows its own
`variantDesc` directly instead, with no shared text to repeat. When a row's
variants exceed the cap, `genHelp` wraps them into their own
`wrapWords`-wrapped lines and zips them line-by-line against the
(independently wrapped) help-text
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

Both are one-line delegations to `get*`, the explicit accessor that reads
the same value where a converter can't fire (generic inference binding `T`
to the Arg itself — `join`, `in`, `some`, a `case` selector). The
`get*(arg, otherwise)` overloads are `template`s rather than `proc`s so
`otherwise` stays unevaluated on the supplied path; each binds `arg` to a
local so the operand is evaluated exactly once. They read `ValueArg`'s
private `value` field from an expansion in the caller's module, which works
for the same reason `defineArg`/`defineFlag` can (`docs/gotchas.md`). All
three branch on `seen` (ADR 0039), including the `ValueArg` overloads: a
`FlagArg` has no storage-based alternative, and since ADR 0032/0039
resolve values and provenance for the whole tree before dispatch, a `seen`
`ValueArg` always has a stored value to index. The no-arg `get` is
the same template called with the Arg's coded default as `otherwise`
(`arg.get(otherwise = arg.default[0])`), so the library holds exactly one
supplied-or-not test; `FlagArg`'s returns `value` outright, its coded
default being its starting value rather than a substitution tier. See
`docs/adr/0040-explicit-value-accessor.md`.

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
than one grammar level. Two consumers still rely on it: `matchedCommand`
(which also drives `applyFallbacks`' recursion) and `parseMessageArgs`.
Value parsing no longer does — see `parseAllValues` below.

After a successful walk, and before the env/Config Source sweep, `Spec.parse`
calls `parseAllValues`, which parses every non-Command, non-`MessageArg` match in
`pc.matches` — the whole tree, before any hook fires. Because `pc.matches`
is already flat across every level, this is a plain loop over the table: no
spec-tree recursion, no `Match.spec` filtering, and no dedupe pass, since
an Arg shared by two levels holds all its matches under one key and so is
parsed exactly once. Each Arg's own matches are still sorted by `Match.idx`
individually, exactly as the per-level pass sorted them — not flattened
into one sort across the whole table. That composes a shared Arg's matches
identically to the old level-by-level walk, because ADR 0010 makes each
level's tokens a contiguous run in command-line order.

The env and Config Source tiers are likewise parsed up front, inside
`applyFallbacks`; every tier is converted before `dispatch`, so a value
that fails to convert or validate raises before any hook can run a side
effect, on every tier. See
`docs/adr/0032-parse-all-values-before-dispatch.md`.

The three supplied tiers run strongest-first, which is Value Precedence
read top-down:

```
walk
                 # seenBy = byCli on every matched Arg, from matchedArgs
parseAllValues   # CLI tier
applyFallbacks   # env tier if seenBy < byEnv, then config if seenBy < byConfig
dispatch         # hooks only
```

`byCli` is written in `parse*` itself, straight from
`matchedArgs(pc.matches)` and before anything is converted, so provenance
is complete for the whole tree — commands and help args included — before
the first hook, and `applyFallbacks` has a per-Arg gate to read whichever
of the two tiers' passes runs first. Ordering the passes strongest-first
is a separate choice, with one consequence: a bad command-line value now
surfaces before a bad env or config one. See
`docs/adr/0039-per-arg-provenance.md`.

`Spec.parse` then builds a `HookInfo(matched:
seq[Arg])` from `pc.matches` -- every Arg with at least one match, across
every level, computed once from the walk already performed (not a second
walk) -- then recursively re-walks the *declared* Spec tree -- not
`pc.matches` itself, which carries no scope information on its own -- via
`dispatch(spec, pc.matches, command, info)`, threading `info` unchanged
through every recursive call. At each `Spec` level: `spec.before(info)`
fires, if set, with every matched level's values already parsed;
`parseMessageArgs` then parses (and raises
on) any matched `MessageArg`/`HelpArg` at this level (still filtered by
the `Match`'s `Spec` provenance, so a shared `help()` fires at the level it
was typed at rather than the shallowest one declaring it); `matchedCommand`
finds whichever single Command was matched at this level, if any (at most
one ever can be — a matched `Command` transition permanently updates
`pc.spec` to the nested spec for the rest of the walk, so a sibling
command word can never be recognized afterward);
if none, `spec.action(info)` fires (this Spec is the dynamic leaf for this
invocation); if one, `dispatch` recurses into its own nested `Spec`;
finally `spec.after(info)` fires, wrapped in a `try/finally` around the
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

Since `info` is a single value computed once and threaded unchanged
through the whole recursion, `info.matched` (and its `showsMessage(info)`
convenience -- true if any matched Arg is a `MessageArg`) is a flat view
across the *whole* matched dispatch chain, not scoped to the receiving
hook's own level -- an ancestor Command's `before` can see
`info.showsMessage: true` even when the actual matched `HelpArg` belongs
to a nested Command's Spec several levels down. This lets a `before` hook
skip expensive setup (a DB connection, config loading) for a
`--help`/`--version`/message invocation without a second FSM walk. See
`docs/adr/0021-hook-info-matched-args.md`.

## `autoFillUsage`

`newSpec` builds the FSM first, then calls `autoFillUsage` to patch any
gaps: it uses `fsmgraph.referencedArgs` to collect every `Arg` actually
referenced by a matcher, then appends usage lines for whatever isn't
reachable. Rather than rebuilding the FSM from scratch a second time (which
would re-lex/re-parse every line, including ones already built moments
earlier), the newly-appended lines are spliced directly onto the existing
`spec.fsm` root via the same `parser.addUsageLines` `genFsm` itself uses,
then `spec.fsm.prepare()` runs once more over the combined graph.
`addUsageLines` itself recomputes the root's `terminal` flag after
splicing, so neither caller needs to know that a spec which started with a
fully empty `usage` string left that flag `true` and now needs it cleared
-- but also so that a root whose *existing, already-simplified* usage line
was itself fully skippable (e.g. `[-- <arg>...]`) keeps that earned
`terminal = true` instead of losing it just because a new line got spliced
on top (see `docs/gotchas.md`'s "terminal flag" entry, issue #6). This runs
regardless of
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

Each candidate is a `CompletionCandidate = tuple[value, help: string]`, not
a bare string — see `docs/adr/0022-completion-candidate-help-text.md`.
`help` is populated only for an Arg's own name (option/flag/command
candidates, via `fsm.describeVariants`), never for one of its enumerated
*values* (an `Argument` matcher's `completions()`, or a pending option's
own `completions()`), which always carry `help == ""` — there's no
per-value description in the data model to draw from. `describeVariants`
sources each variant's description from `Arg.variantDesc(variant)`
(`backend.nim`) when an Arg's variants genuinely diverge in what they do
(e.g. a flag's `-i`/`-d` incrementing/decrementing differently), falling
back to the Arg's shared `.help` otherwise — mirroring `argumint.
variantGroups`'s own grouping rule (used by `genHelp`) so completion's
descriptions agree with what help text would actually show.

`completion.genCompletionScript*` generates a thin, mostly-static per-shell
adapter (`Shell = bash | zsh | fish`) that just shells out to
`<binaryName> __complete <words...>` and feeds stdout into that shell's own
reply mechanism — it needs almost nothing about the `Spec`'s own contents,
since completion is resolved dynamically by the binary itself. Stdout is
one candidate per line, each `"value\thelp"` (`help` possibly empty, tab
always present); fish and zsh render `help` in their own completion menu
(fish natively, since a tab-separated line is its own candidate+description
convention; zsh via `compadd -d`), while bash — which has no per-candidate
description slot at all — strips it before building its word list. See ADR
0022 for why. `parseOrQuit*` gives `CompletionError` (a `MessageError`
peer of `HelpError`) its own `echo`-based handling rather than reusing the
shared `except MessageError as e: quit(e.msg, QuitSuccess)` branch: `quit`'s
non-nimscript/js implementation writes to stderr, not stdout, which a shell
adapter's `$(...)` capture can't see.
