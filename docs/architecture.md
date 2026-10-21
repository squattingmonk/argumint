# Architecture (detailed)

This is the full implementation-detail walkthrough of the five phases
summarized in `CLAUDE.md`. Read that file first for orientation; come here
when you need the specifics of how a phase actually works. Domain vocabulary
(Spec, Arg, Variant, Validator, etc.) is defined in `CONTEXT.md` — this file
assumes that vocabulary and focuses on code-level mechanics. See
`docs/gotchas.md` for Nim-language/compiler traps hit while building this.

## 0. Module layering

Only public import paths sit at the top of `src/argumint/`: `help.nim`,
`customarg.nim` (what only a Custom Arg needs, ADR 0076),
`configsource.nim` and its `configsource/` adapters. Every withheld module
lives in a subdirectory for its layer:

- `text/`: `style`, `console`, `prose`. Styled text, terminal detection
  and wrapping.
- `core/`: `errors`, `variant`, `completer`, `envvar`, `settings`,
  `backend`, `outcome`. The data model and what it points at.
- `grammar/`: `lexer`, `parser`, `usage`, `fsmgraph`, `specbuild`, `dot`.
  From a spec tuple and its usage string to the FSM.
- `values/`: `argtypes`, `validators`, `flagclamp`, `display`. Converting,
  validating and storing values.
- `walk/`: `tokens`, `fsm`, `matching`, `complaints`, `precedence`,
  `completion`. Matching a command line against the FSM.

The layers stack `text` → `core` → `grammar` and `values` → `walk`. A
module imports only from its own layer, a layer below it, or
`configsource`, and `grammar` and `values` don't import each other. Test
code inside `when isMainModule` may reach further (`variant`'s tests
check it against `lexer`).

Seven modules are leaves with no local imports — `errors.nim`,
`completer.nim`, `configsource.nim`, `display.nim`, `envvar.nim`,
`style.nim`, and `variant.nim` — and everything else layers on top:
`console`/`flagclamp`/`lexer`/`outcome`/`validators` →
`prose`/`settings`/`usage` → `backend` →
`argtypes`/`fsmgraph`/`help`/`tokens` → `complaints`/`dot`/`parser` →
`precedence`/`specbuild` → `matching` → `completion` → `fsm` → `argumint`.

`display.nim` renders a value in help and errors: a string or char always
quoted (escaping only `"`, `\` and control characters, so UTF-8 stays
readable), anything else as its `$`. Validators use it for choices and
ranges, arg types for defaults and conversion failures.

`errors.nim` holds every exception argumint raises (`SpecDefect`,
`ParseError` and its subtypes `UsageError`, `ConversionError` and
`ValidationError`, `MessageError`, `HelpError`, `CompletionError`).
Keeping them in a leaf is what lets any module name an exception without
depending on whichever module raises it — `complaints.nim` names every
`ParseError` subtype but has no business importing the validator
combinators or the arg types, and `lexer.nim` raises `SpecDefect` while staying free of everything above
it. The two modules whose own API would be incomplete without one
(`lexer.nim` for `SpecDefect`, `validators.nim` for `ValidationError`)
re-export it, so importing either alone still names what it raises.
`errors.nim`'s withheld `newPlainError` builds one whose `styledMsg` is its
`msg`, for the raise sites with no Styler to hand (ADR 0059).

`completer.nim` is the Completer model: what an Arg declares about
completing its value (`Completer`, from a `CompleterProc` or a fixed
`Offer`), what a Completer is told (`CompletionContext`), and what it
answers (`Offer`, with its `CompletionCandidate`s and `PathCompletion`). It
sits below `backend` because `Arg.complete` is a `Completer`; `backend`
re-exports it. `completion.nim` is the other half, much higher up: how a
shell's request is answered, using these (see "Completers" in §6).

`variant.nim` is the other grammar leaf: the Variant grammar, written once
as PEG source fragments (`ShortChar`, `ShortName`, `LongName`,
`AngledName`, `Angled`, `Upper`, `Equals`, `CommandName`). Three readers build their patterns from them, so
none can drift from the others: the lexer's usage-string tokens, `tokens`'
runtime option shapes, and `parseVariant`, which reads one declared Variant
against a `VariantShape` and returns its bare name and metavar, or `none`.
The shapes are what the lexer knows (positional, option, command); `Flag`
is an option with the metavar forbidden, a rule only spec construction
can apply. `parseVariant` raises nothing: each caller raises its own
`SpecDefect`, naming the field or spelling at fault. `splitVariants` is
the comma split every `variants` string goes through. Its own tests check
that the lexer reads each accepted Variant as its shape's tokens, and
doesn't read a rejected one that way.

`console.nim` answers what the terminal can do: how wide output can be
(`resolvedWidth`, over `detectWidth` and `DefaultWidth`/`DefaultMaxWidth`)
and whether it can take colour (`resolvedStyler`), which `SpecSettings`'
`width`/`style` getters call on first read (ADR 0058). Each rule is a pure
decider taking its environment as parameters (`chooseWidth`, `wantsColor`)
beside a thin probe of the real process, and the one `winlean` import
lives here. It imports only `style`, for `ansiStyler`. `settings`
re-exports the public width names, and the facade re-exports `wantsColor()`.

`settings.nim` holds `SpecSettings`, the settings one Spec tree shares:
`newSpecSettings`, the compile-time defaults behind it (ADR 0053), and the
`width`/`style` getters that detect on first read (ADR 0058). It sits
below `backend` because a `Spec` holds one, and it is the only part of the
data model that imports `console`, so the terminal probe stays out of
`backend` itself. `backend` re-exports it.

`envvar.nim` is the env tier's counterpart to `configsource.nim`:
`EnvSource` and its constructors (`env`, `toEnvSource`), `DefaultEnvDelim`,
the split rule (`splitEnvValue`), and `lookupEnv`, which reads a variable
and splits it the way `lookupConfigSources` answers for a Config Key.
`backend` re-exports it, since `Arg.envSource` returns an `EnvSource`, and
`settings` imports it, since `newSpecSettings` defaults to
`DefaultEnvDelim`. It can't be called
`envsource`: see `docs/gotchas.md`.

`outcome.nim` is what `parseOrQuit*` does with each exception it catches:
`outcome(e, styler)` returns the text to print, whether it goes to stderr,
and the exit code, as an `Outcome`. Failures (`ParseError` and its
subtypes, `SpecDefect`) get an `srError` label and go to stderr
with `QuitFailure`; messages (`MessageError` and its subtypes) go to stdout
unlabelled with `QuitSuccess` (ADR 0050). Returning data rather than
quitting is what makes the rule testable; the facade's private `quitWith`
prints it and quits. It imports only `errors` and `style`.

`help.nim` sits directly above `backend` because that is as high as it needs
to sit: the `variantDesc`/`defaultStr`/`validatorHelp`/`configKey` display
methods, the derived `envName` beside them, and `Spec`'s own private fields
are all `backend`'s. A `HelpFormatter` renders the whole message from the
`HelpContext` `help.nim` hands it (its `groups`, `rows`, `prose`, `usage`,
and `render`), plus `joinSections` and the `prolog`/`epilog` accessors
`backend` defines, or builds on the Help Frame (`frame`) and writes only
its rows -- see `docs/adr/0048-pluggable-help-formatters.md` and
`docs/adr/0057-help-context.md`. Usage Lines have their own module,
`usage.nim`, which takes a plain usage string and needs no Spec: it splits
one into Usage Lines (`splitUsage`, which the parser calls too, §2), lays
them out (`usageLines`, a usage with none as one bare command line, since
an empty usage accepts a bare call -- #68), and puts them under their
`Usage:` heading (`usageBlock`), which help's `frame` and
`Report.failureMessage` both call. `backend` does no wrapping of its own. Its position
below `fsm` is what makes `Arg.action`'s dependency inversion a choice
rather than a necessity — see "The write side" below.

`specbuild.nim` sits above FSM compilation rather than beside the data model
in `backend`, because building a `Spec` *means* compiling its usage string
into one: `finishSpec` calls `genFsm` (`parser`) and `autoFillUsage` calls
`referencedArgs` (`fsmgraph`), both of which import `backend`. Putting spec
construction in `backend` is a recursive module dependency, and Nim rejects
it outright. What never touches a usage string can sit lower:
`newSpecSettings` lives in `settings`, beside the `SpecSettings` type it
builds, and `subject`, which has consumers on both sides of the split,
lives in `backend`.

`argtypes.nim` sits directly above `backend`/`validators`/`flagclamp` and
below the `argumint.nim` facade, and holds the `ValueArg`/`ValuesArg`/
`FlagArg` data model plus **everything that touches their private fields**:
`ValueArgBase`, `FlagArgBase` and the hooks their methods call, `fromString`
and `acceptImpl`, the Flag Operations (`namedOp`, `opError`, `describeOp`,
the Implicit Operations), the `initValueArg`/`initValuesArg`/`initFlagArg`/
`initFlagOp` constructors, the `rawValue`/`rawDefault` read accessors, and
the parsers for a flag's spellings and the string form of its `ops`. Every
public name over that machinery — `arg`/`args`/`opt`/`opts`/`flag`,
`flagOp`/`flagOpIt`, `get`/`toT`/`toSeqT` — stays in `argumint.nim` with
its documentation and delegates. The split is forced
rather than stylistic: `privateAccess` does not survive instantiation in
another module, so anything generic or templated that reads a private field
has to live beside the type (see `docs/gotchas.md`). `argtypes` is exported
for the facade's benefit and withheld from its re-export list, exactly like
`specbuild`'s `beginSpec`/`finishSpec`; it is an implementation-detail module,
not a promised import path.

`tokens.nim` sits directly above `backend` and below `complaints`/`fsm`, and
holds `RawToken`/`Classification` plus every operation that decides what one
token *is* against a `Spec`: `classify` (ADR 0019), `refusesAsPositional`
(ADR 0034), `consume`/`consumeOptsEnd`, and the shape-only predicates
(`isOptShape`, `isNonOptionShort`, `exemptFromStrict`, `mustResolve`,
`userTyped`, `fromCluster`). A `TokenCursor` carries a token stream
together with the `Spec` governing it and whether `--` has been crossed,
replacing what used to be four arguments threaded by hand through every
call. Unlike `argtypes`, `tokens` needs no withholding — `complaints`,
`matching`, `completion`, and `fsm.nim` all import it, so it's invisible to
the facade by construction, the same shape as the `fsmgraph.nim` split out
of `backend.nim`.

`complaints.nim` sits directly above `tokens` and below `precedence`/
`matching`/`fsm`, and holds everything ADR 0035 (parse-failure reporting)
onward names: `Complaint`, `Leftover` (still `= TokenCursor`, now local to
this module), the Did-You-Mean rule (`didYouMean`/`osaDistance`/
`unknownOption`/`unknownCommand`), and a `Report` object replacing what used
to be four loose `ParseContext` fields (`messages`/`errorTokens`/
`errorSpec`/`errorCommand`) written and read together at exactly two sites
(`walk`'s tie-break/adoption, and the one raise site). `Report`'s two-phase
shape mirrors the walk itself: verbs like `missingOption`/`leftover`/
`starved` record during the walk without wording anything, and
`finalComplaints`/`failureMessage`/`raiseFailure` word and render only
once the walk is over. `matching.nim`'s `ParseContext` embeds one `Report`
(`report`); neither `walk` (`fsm.nim`) nor `match`/`push` (`matching.nim`)
reach into it directly, only through `Report`'s verbs. `fsm.nim` owns the
backtracking walk itself; `matching.nim` owns the `match`/`push` primitives
both `walk` and `completion.collectFrontier` drive against a shared
`ParseContext` — split out in issue #78, since neither could be split by
caller (the Value Precedence tiers, which also report through a `Report`,
moved to `precedence.nim` below — see issue #65). Unlike `argtypes`,
`complaints` needs no withholding — `matching.nim` and `precedence.nim`
both import it, the same shape as `tokens.nim`.

`precedence.nim` sits directly above `complaints`/`configsource`/`envvar`
and below `matching`/`fsm`, and holds everything Value Precedence's
fallback tiers name: `FallbackTier` (`range[byConfig..byEnv]`, the `SeenBy`
members the two tiers supply) and `FallbackOrder` (`[byEnv, byConfig]`,
strongest first, the order they're consulted in; iterating the type itself
would run weakest first), `Tiers` (one `ValueCursor` per tier), `probe`,
and `applyFallbacks`, which records a fallback that fails into its `Report`
and carries on. `Tiers` replaces what used to be two loose `ParseContext`
fields (`env`/`configValues`) plus six ad hoc closure constructions at
their four call sites (`matching.match`'s `mkOption` arm, and
`applyFallbacks`'s per-tier `resolve`/`setValue` pair) — a `resolve: proc
(): Option[seq[string]]` parameter existed to keep `ValueCursor`
tier-agnostic, but there are exactly two tiers, both compiled in, so it
bought genericity nowhere it was spent; dispatching on `FallbackTier` via
`case` inline replaces it, and also removes a `let spec = pc.cursor.spec`
workaround `match`'s `mkOption` arm needed only because a closure can't
capture a `var ParseContext` parameter. `fsm.nim` keeps only the walk
itself and dispatch — `match`/`push` moved out to `matching.nim` entirely
in issue #78, so this is no longer just a division of labor within one
file. Unlike `argtypes`, `precedence` needs no withholding — `matching.nim`
and `fsm.nim` both import it, the same shape as
`tokens.nim`/`complaints.nim`. `initTiers(settings)` captures the parse's
one `SpecSettings` (every level shares the root's), so `probe` and
`applyFallbacks` take Args, never a `Spec`; `initParseContext` builds them
for both the parse walk and completion's, since completion's walk probes
too.

`matching.nim` sits directly above `precedence` and below `completion`/
`fsm`, and holds the matching primitives both the parse walk and shell
completion drive: `Match`/`MatchTable`/`Reach` (types) and `ParseContext`,
plus `initParseContext` (its one constructor, seeding the root level),
`push`/`match` (the proc that applies one `Matcher` against the live cursor,
mutating `pc.report`/`pc.tiers`/`pc.matches` as a side effect), and
`storeValues` (writing a finished walk's values into the Args, raising on a
bad one for `parse` or skipping it for a Completer's fill). Both `walk`
(`fsm.nim`) and `collectFrontier` (`completion.nim`) call `match` directly,
and `match` touches every field on `ParseContext` regardless of which caller
is driving it, so this couldn't be split by caller — it's one cohesive unit
sitting below both. It needs no `privateAccess(Spec)` of its own: `match`
never touches a private `Spec` field directly, only through `TokenCursor`
methods `tokens.nim` already encapsulates. See issue #78.

`completion.nim` sits directly above `matching` and below `fsm`, and —
beyond the always-existing `genCompletionScript*` (§6) — now also holds the
FSM-walking half of shell completion: `Frontier`, `collectFrontier`,
`bareVariants`, `describeVariants`, `addUnseen`,
`candidateWords`, `pendingOptionalArgs`, and `completeArgs*` (now
`resolveCompletion*`), moved from
`fsm.nim` in issue #78 once `matching.nim` existed to import instead of
`fsm.nim` (avoiding the import cycle `completion` ↔ `fsm` a direct move
would otherwise have needed). It picks up its own `privateAccess(Spec)` for
`bareVariants`' `spec.options` read.

## 1. Spec construction (`specbuild.nim`, `src/argumint.nim`)

User calls `arg`, `opt`, `flag`, `command`, `help` (the Arg constructors,
`src/argumint.nim`) to build a tuple of `Arg` objects, then `newSpec`/`parse`
(`specbuild.nim`) assembles them into a `Spec` (`backend.nim`). Each arg is
indexed into `spec.arguments` (positional, keyed by `<name>` or `NAME`),
`spec.options` (optional/flag, keyed by `-o`/`--option`), or `spec.commands`
(subcommands, keyed by the command word), and filed under its Help Group in
`spec.groups`. An empty `group` becomes its kind's `defaultGroup`: the Arg
constructors fill it in, and `addArg` fills it in again on the Arg itself
for a custom `Arg` that didn't, so everything reading `group` agrees. If no
`usage` string is given, one is auto-generated from the declared args (see
"autoFillUsage" below).

Match Accumulation is per-`Arg` lifetime, not per-parse, so a spec tuple is
single-use — parsing one twice appends to the same `ValuesArg.value` and
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
`argumint.nim`, `completion.nim`, `fsm.nim`, `help.nim`, `parser.nim`, and
`specbuild.nim`.
That call **does not survive template or generic instantiation in another
module**, so `newSpec*` — which is generic over the spec tuple and therefore
instantiates in the caller's file — delegates its private-field work to two
non-generic bookends, `beginSpec` and `finishSpec`, leaving only the
field-free `addArgs` generic in between. Any new generic or template needing
a private `Spec` field has to be split the same way; see `docs/gotchas.md`.

`Arg`'s own `kind`, `variants` and `seenBy`, and `CommandArg.spec`, are
private too, since the Spec's indexes and FSM are keyed by them (ADR
0076). Each has a public getter of the same name. The library writes them
through three procs `backend.nim` exports but the facade withholds:
`initBase` (kind and Variants, from every constructor), `setSeenBy` (the
write side only) and `setSpec` (`command*`). These need no
`privateAccess`, since a proc declared in `backend` writes its own private
fields wherever a template or generic expands it. A Custom Arg sets its
kind and Variants with `customarg.initArg`, which calls `initBase` once
and raises `SpecDefect` on a second call.

## 2. Usage-string compilation → FSM (`lexer.nim` → `parser.nim` → `backend.nim`/`fsmgraph.nim`)

The usage string (e.g. `[-r] <src>... <dest>`) is tokenized by `SpecLexer`
and recursively-descent parsed (`atom`/`sequence`/`choice` in `parser.nim`)
into a graph of `State`/`Transition` objects (their data model lives in
`backend.nim`; the construction/simplification operations below live in
`fsmgraph.nim`). Each token becomes a `Matcher`
(`mkArgument`, `mkOption`, `mkOptions`, `mkCommand`, `mkOptsEnd` for a
usage-string End-of-Options Marker (`--`) -- see
`docs/adr/0020-usage-string-end-of-options-marker.md` -- or `mkShortcut` for
optional/repeated branches). `fsmgraph.prepare` (`simplify` +
`sortTransitions`) collapses shortcut chains and orders transitions by
matcher priority (`ord(MatcherKind)`) so, e.g., positional args aren't
greedily consumed ahead of options. `simplify` collapses shortcuts via an
epsilon-closure per state (`shortcutClosure`) rather than iterative
delete-and-copy, so it terminates even when shortcut edges form a cycle
spanning more than the immediate state being simplified — see
`docs/gotchas.md`. The per-line lex/parse/splice loop
itself lives in `parser.addUsageLines` (shared with `autoFillUsage`, see
below); `genFsm` calls it once for every Usage Line `usage.splitUsage`
finds in `spec.usage`, then calls `result.prepare()` directly after.
`splitUsage` is the one rule for what a Usage Line is, shared with help so
the usage block shows exactly what parses: a blank line is dropped, and an
indented line continues the line before it, even across a blank line
(#137), and a leading `{cmd}` is stripped, raising `SpecDefect` for one
anywhere else. A line left empty is a Bare Call, which `addUsageLines`
splices as a shortcut to a terminal State, and help shows as the
command alone (ADR 0061). A blank line isn't a Bare Call; before #137 help
showed one as a bare command line (#68's reading) while the parser dropped
it.

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
its own `mkOptions` matcher — e.g. in `[options] --verbose`, `--verbose` can
only be matched once (via its own explicit atom), not once via `[options]`
and again via the explicit mention. Because a `[options]` atom earlier in
the line can't yet know about an explicit mention later in the same line,
its `mkOptions` matcher is built unfiltered and its `Matcher` (a `ref`, see
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

## 3. Runtime matching (`walk` in `fsm.nim`, matching primitives in `matching.nim`, token classification in `tokens.nim`)

Actual `os.commandLineParams()` (or passed-in `args`) are first split into
`RawToken`s (`tokens.initCursor`, `tokenizeArgs` internally) via
*shape-only* recognition — no `Spec` lookups at all: does a token look like
`-o`/`--opt`/`-o=val`/`--opt=val`/a `-xyz`-shaped cluster candidate, or is
it a literal `--`? This is the only thing that's genuinely
position-independent; everything else about a raw token's meaning depends
on which `Spec` governs this position, which is only known once the walk
has actually gotten there (see below). `initCursor` pairs the result with
the root `Spec` into a `TokenCursor` (`tokens.nim`) — a token stream plus
the `Spec` governing it and whether `--` has been crossed, the three
pieces of state every classification question below needs together.
`matching.nim`'s `ParseContext` embeds one as `cursor`.

`walk` then recursively tries the FSM's transitions against the token
stream, backtracking via a copied `ParseContext` (`fresh = pc`) on each
branch attempt, accumulating the best-effort error `messages` from the
failed path that got *furthest into the input* so error messages point at the
most specific match attempt, not just "invalid arguments". Classification of *what a `RawToken`
actually is* — Command, Option/Flag (and which one), or plain positional
text — is decided lazily by `tokens.classify`, called inline from `match`'s
own `mkCommand`/`mkOption`/`mkOptions`/`mkArgument` branches, each checking a
token's fitness for *itself* against `pc.cursor.spec` (the Spec currently
in scope for this specific walk attempt, already updated by a matched
`mkCommand` transition) rather than trusting a precomputed global answer:

- **mkCommand** checks the raw string against `cursor.spec.commands` directly
  — only at the very next position, never scanning further (a Command
  matcher never looks past position 0).
- **mkOption**/**mkOptions** resolves cluster-splitting/attached-`=value`
  syntax against `cursor.spec.options`, scanning forward past tokens that
  don't classify as *this specific* Arg; if a shape doesn't resolve to any
  declared option at all, the matcher simply doesn't match — no
  exception — leaving the token for a different matcher to try.

  **Option scans stop at a Command.** The scan breaks at a token that
  classifies as one of `cursor.spec`'s own Commands, so a parent's option
  given after the command word (`add -v`) is left for the subcommand's
  level, where it's unrecognized: nothing follows a Command in a Usage Line
  and a matched Command takes every remaining argument (ADR 0010). The one
  exception is a Command word that is really an Optional's separate-token
  value (`--name add -v add`, `-vn add -q add`), which the scan steps past.
  `tokens.isSeparateValue` decides that by reading a copy of the cursor in
  order from the start, peeling clusters as `consume` does, since the token
  just before the word can be a cluster or itself a value. The scan itself
  still steps one token at a time rather than skipping a whole Optional's
  `consumed`, which ADR 0034's starved-option case depends on (issue #171).
- **mkArgument** scans forward past tokens that classify as a real
  Option/Flag (`State.prepare`'s priority sort, `mkOption < mkOptions <
  mkCommand < mkArgument < mkOptsEnd < mkShortcut`, see §2, already gave a real
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
  `tokens.refusesAsPositional` — Strict Option Checking,
  `SpecSettings.strictOptions`, default on: a `Positional` result that is
  option-shaped, unresolved, and not a Non-Option Short is skipped rather
  than accepted, so it survives as a leftover token for `finalComplaints`
  to name (see §3b). The same setting gates the value slot inside
  `classify` (a private `refusesAsValue` in `tokens.nim`), so a declared
  Optional followed by an unrelated option starves instead of eating it.
  Both refuse rather than raise, keeping backtracking intact. See
  `docs/adr/0034-strict-option-checking.md`, which narrows ADR 0019's gap 3
  without touching the classification mechanism itself.

  A post-`--` token is exempt because `refusesAsPositional` consults
  `cursor.optsEnd` directly: `classify` short-circuits past all
  option-shape reasoning once end-of-options is crossed, which yields a
  plain `Positional` indistinguishable from an unknown option's, so the
  gate has to know about `optsEnd` itself rather than reading it off the
  result.

`classify` also carries a non-accepting outcome, `starvedOpt`/`starvedName`,
set when a token *is* a declared Optional but no value is available. That is
what lets the leftover complaint say `option --port requires a value` rather
than calling a name it recognizes unrecognized, and it is an error under
both settings.

Four failure paths ask that question — the `mkOption` matcher, the `mkOptions`
catch-all, the `mkArgument` matcher, and `walk`'s tail — so `Report.starved`
(`complaints.nim`) classifies the leading token for itself and returns
whether it complained, letting each caller fall back to its own blunter
wording. Two of
them are why it can't simply be handed a `Classification` computed once:
`mkOptions` rolls back each failed probe's messages, so the question has to be
re-asked *after* the rollback, and `mkArgument` reports its own `missing
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
independent copy and reclassifies independently. `TokenCursor`
(`tokens.nim`) is the same shape one level down — also a plain value
object — so embedding it in `ParseContext` as `cursor` doesn't change this
argument, only where the fields live.

One place still needed decoupling despite that: `walk`'s merge step, which
records the furthest-reaching failed branch's spec/command for the final error
message, used to write into the *same* `ParseContext.cursor.spec`/`.command`
fields a later sibling transition's own `fresh` copy starts from — harmless
before this change (a failed Command descent could never be followed by a
sibling Argument attempt reusing the same leftover token), but reachable now.
`ParseContext.report` (`complaints.Report`, §3b) carries dedicated
`spec`/`command` fields of its own for this, set by `Report.clear` when a branch
matches, carried up when `walk` adopts a sibling's `Report`, and read only when
formatting the final failure message, so `cursor.spec`/`.command` stay reserved
for live walk state. See `docs/adr/0019-lazy-token-classification.md`.
`Report`'s leftovers (§3b) are recorded on the same terms.

A literal `--` is recognized in the same eager shape pass and, the first
time the walk encounters it on a given path, sets `pc.cursor.optsEnd =
true` (dropped, never handed to any matcher as a value) — from then on, on that
path, Option/Options/Command stop resolving shapes/names entirely and
every remaining token is available to Argument only, exactly as before.

A successful walk populates `pc.matches: OrderedTable[Arg, seq[Match]]`,
which is then fed back into each `Arg`'s `parse` method to actually
convert/store values.

## 3b. Failure reporting (`complaints.nim`)

Everything above concerns a walk that fails; this is what the user sees when it
does. A `Report` (embedded in `ParseContext` as `report`) accumulates two
channels during the walk, both subject to the same replace-on-further /
merge-on-tied bookkeeping at the bottom of `walk`'s transition loop (replacing
`pc.report` whole, or `Report.merge`) — neither `walk` (`fsm.nim`) nor `match`/
`push` (`matching.nim`) reach into either channel directly, only through
`Report`'s verbs:

- **messages**, recorded via `missingArgument`/`missingCommand`/
  `missingOption`/`unexpected`/`note`, each building a `Complaint` — `(kind,
  subject, names)`. `kind` groups same-kind complaints onto one `|`-joined
  line at render time and is empty for a conversion/validation failure
  (`note`), which renders as a bare sentence under the same bullet. `names`
  marks a Complaint that points at a token the user actually typed — a
  property of the Complaint, never inferred from its wording, so ADR 0034's
  starved-option complaint participates without being special-cased.
- **leftovers**, recorded via `Report.leftover`/`Report.starved` — each a
  `Leftover` (`= tokens.TokenCursor`): what a failed branch couldn't consume,
  plus the `Spec`/`optsEnd` needed to re-`classify` it — the same cursor
  `pc.cursor` already is, just recorded under a name that reads as "what's
  left" rather than "where we are". Recorded during the walk, worded only
  afterwards (`finalComplaints`), so the wording can draw on the whole
  message rather than one branch's local view. Three recording sites: the
  tail of `walk` (a terminal state whose every transition failed — the
  general case); a failed `mkCommand` matcher (the only place that knows a
  Command was expected *at this exact position*, and which fires whether or
  not the grammar has a terminal state the leftover could reach); and a
  failed `mkOption` matcher holding an unresolved option-shaped token, which
  likewise never reaches `walk`'s tail and is what names the headline
  `unrecognized option: --nope` case.

`Report` also carries the failing `spec`/`command` (what used to be
`ParseContext.errorSpec`/`.errorCommand`) — all four pieces travel as one value,
read together at the one raise site (`Report.raiseFailure`), rather than
four fields kept in lockstep by convention. The level is set by `Report.clear`
on every branch that matches, from the branch's live cursor at that moment, and
`walk` takes a further-reaching sibling's `Report` whole, level and all. A
failure several levels down so keeps its own level as each enclosing `walk`
frame adopts it on the way back up (#192). Resetting the level in `clear`
matters as much: without it a branch kept an earlier sibling's deeper level, and
adopted that as its own. Nothing here writes `pc.cursor.spec`, which a failed
sibling must never retroactively overwrite — see ADR 0019 point 7.

Which branch wins is decided by **Reach** (`CONTEXT.md`), not by how many
matchers it satisfied: where the first token it could not consume sits, whole
input if it consumed everything. That position is an `(idx, subIdx)` pair
compared lexicographically — a peeled Short-Option Cluster remainder keeps its
parent's `idx` (Flag Op composition order depends on that), so `subIdx` counts
letters already peeled to tell "got two letters into `-abc`" apart from "got
none", without ever outweighing a branch that reached the next argument. An
`mkOption` matcher scans ahead, so
counting matchers lets an options-only usage line skip the token the user got
wrong, match something later, and outrank the branch that understood the
leading input — see ADR 0036. A transition scores the greater of its own Reach
and its descendants', since a failed descent leaves this level's token list
untouched; being a global argv index, Reach is comparable across nesting
levels in a way `depth` never was.

`maxReach` only ever rises, including when a lesser branch's complaints
are adopted because nothing has complained yet (`Report.isEmpty`) —
otherwise a branch that got nowhere sets the bar every later sibling ties
against, and gets to name the offending token. The tie merge itself
(`Report.merge`) is deliberate: it is what accumulates same-kind complaints
onto one `|`-joined line.

`finalComplaints` then builds the message: word each leftover (as an
`unrecognized command` when a Command was expected there, otherwise from
`tokens.classify`'s answer), then drop every `missing option` — and `missing
command` too, if the named token stood in a command's position. One further
suppression happens at the complaint site itself, since only it knows the
context: the `mkOptions` catch-all probes each option via `Report.mark`/
`.rollback` (a snapshot-and-restore pair over both channels) and never
complains at all on failure, an option reached that way being optional by
construction.

The `mkArgument` matcher suppresses on the same terms, but has to be *told* its
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

A `Complaint`'s subject is `StyledText`, its roles set by whichever
constructor builds it (ADR 0056), never by `markup`, since it may hold
typed input: the token the user got wrong is `srInvalid`, what argumint
declares keeps its own role (a missing option goes through the same
`styledOption` split as a help row), and the wording is `srPlain`. Two
complaints are the same if their plain text is (`dedupKey`), so dedup and
grouping never depend on a role.

`formatComplaints` lays out the bullets with no leading newline;
`Report.failureMessage` appends the usage block via `usage.usageBlock`,
the same one help shows (so `complaints.nim` doesn't import `help.nim`),
rendered with an optional styler, and `Report.raiseFailure` raises it via
the private `failure`, which builds it with a plain
`msg` and a `styledMsg` rendered with the Spec's styler (the same text if it
has none), so a caught error's `msg` never holds escape codes (ADR 0051,
ADR 0059). `parseOrQuit*` prints its `outcome`: the `srError` label above
`styledMsg`, or `msg` if something outside argumint raised it without one.
`matching.storeValues` gives a conversion or validation failure that same
shape, since its raise site in `arg.parse` has no view of the Spec. It
seeds one `Report` with the live `(spec, command)`, catches each failure
on every tier into it with `Report.store` (a bare line, as `note` makes),
and returns it with `applyFallbacks`' oversupply complaints alongside.
Each complaint remembers which `ParseError` subtype it is a case of: a
walk's are all usage, `Report.store` takes the type of what it caught, and
oversupply counts as usage. `raiseFailure` raises the subtype they all
share, or `ParseError` when they differ, so a failed walk raises
`UsageError`. See `docs/adr/0035-parse-failure-reporting.md`,
`docs/adr/0077-report-every-bad-value.md` and
`docs/adr/0078-parse-error-hierarchy.md`.

## 3c. Value Precedence fallbacks (`precedence.nim`)

After a successful walk, `storeValues` (`matching.nim`) does one more pass
entirely outside the FSM/backtracking machinery, via
`precedence.applyFallbacks`: for every `Arg` declared by any level the walk
entered (see the command chain under "Dispatch order") that no *strictly*
higher-precedence tier has already supplied (`arg.seenBy > byEnv` skips), it
tries the environment-variable tier, then — only if that had nothing — the
Config Source tier, feeding each resolved value straight to `arg.parse(v,
seenBy = some(tier))`, the same conversion/validation path a CLI value
takes. No source label travels with it: when the value turns out to be bad,
`subject` reads `arg.envName` or `arg.configKey` for the claimed tier and
renders `--port (env: PORT)`. There is no per-tier method: `parse` records
the tier as it writes, so provenance can't outrun the value it describes. An
Arg already *at* this tier is appended to rather than skipped, which is what
lets a pre-seed declaring `byEnv` still collect the env var's own values
(see `docs/adr/0041-parse-is-the-write-surface.md`). Doing this after `walk`
rather than folding it into the FSM means an option only reachable via
`[options]` (never explicitly attempted during matching) still picks up a
fallback value; gating on `seenBy` gives an explicit CLI value precedence
for free, while `ValueCursor.applied` is what dedupes an Arg reachable from
two spec levels (see §5 and `docs/adr/0039-per-arg-provenance.md`). See
`docs/adr/0004-required-options-env-fallback.md`,
`docs/adr/0005-env-supplied-multi-value-options-and-flags.md`, and
`docs/adr/0018-config-source.md` for the design decisions behind the two
fallback tiers; CONTEXT.md's Value Precedence / Env Delimiter / Config
Source entries have the user-facing semantics.

### Env var / Config Source mechanics

Value Precedence's environment-variable and Config Source tiers share one
mechanism, `precedence.nim`'s `ValueCursor` type — one per tier, indexed
by `FallbackTier` (`byConfig..byEnv`, consulted in `FallbackOrder`) inside
`Tiers` (embedded on `ParseContext` as `tiers`) — rather than two
independent implementations. `Tiers.probe` is consulted from `match`'s
`mkOption` branch during the walk — CLI token first, then each tier's own
`ValueCursor.probe` in `FallbackOrder` (env, then, only if env had
nothing, Config Source) — lazily resolving and caching an Arg's available
values (via `resolve`, a `case` on `FallbackTier`) and handing out the
next unconsumed value each time that Arg's matcher is visited. `resolve`
runs at most once per Arg per cursor (cached in `ValueCursor.tried`, including a miss) — cheap either way for
env (`existsEnv`), but load-bearing for Config Source, since a
user-supplied `ConfigSource.lookup` may be arbitrarily expensive. Nothing
decides in advance how many times a matcher gets visited — it falls out
entirely from however many times `walk` actually visits it: a `...` repeat
loops back and keeps consuming until the list runs out; the same Arg named
more than once in one Usage Line with no `...` is just two separate matcher
instances, and the cursor is consulted twice either way. The Options
Catch-all is the exception: it repeats without limit, so its matchers (the
ones with an empty `variant`) probe with `catchAll = true`, which marks the
Arg in `ValueCursor.covered` instead of taking a value. A covered Arg gets
every value with no oversupply check, and a nested command's own slots still
find all of them (#188).

The two tiers differ only in how they arrive at that per-Arg `seq[string]`
of candidate values, each asking its own leaf module. Env:
`envvar.lookupEnv` reads the variable and always splits it
(`envvar.splitEnvValue`) — on the Arg's own `EnvSource.delim` if set,
otherwise on `Spec.settings.envDelim` (cascades like `width`, default `:`),
keeping empty segments as literal values rather than dropping them. Config
Source: `arg.configKey` is looked up via
`lookupConfigSources(settings.configSources, key)`, which already returns
an assembled `seq[string]` (the last layered source
with a hit for that key, in full — see CONTEXT.md's Config Source entry
for why there's no delimiter-splitting step here at all).

After a successful walk, `applyFallbacks` (via the per-Arg, per-tier
helper `applyTier`) applies exactly as many values as the walk consumed
for each Arg from whichever tier supplied them (cached on that tier's own
`ValueCursor`), falling through to the Config Source tier only when the
env tier had nothing at all for that Arg; if values are left over (the
tier had more than the grammar had positions for), that's a `UsageError`
— `"unexpected option"`/`"unexpected flag"`, the same wording already
used for a genuinely excess CLI token — rather than a silent truncation to
a prefix of the values. An Arg whose matcher was never consulted at all
this walk (reachable only through a different, unmatched Usage Line of
the same spec) has no walk-derived count to bound it by, so every
available value from whichever tier resolves is applied. Whatever the
count, an Arg that doesn't `accumulate` (an `opt`, not an `opts` or flag)
takes at most one value from a tier, so several are always the same
`UsageError`, naming the source (`--url (env: URL)`) the way conversion
errors do (#189). For `flag`, each
value (from either tier) names one of the Arg's own declared Variants
(matching a Variant in `self.ops` exactly) and is applied via *that* Variant's
own Flag Operation, not forced through `=`. The one-loop-two-tiers shape
(`for arg... for t in FallbackOrder: if arg.seenBy > SeenBy(t): break; if
tiers.applyTier(t, ...): break`) states this fallthrough once, instead of
two hard-coded gates written differently for each tier — equivalent
because `FallbackOrder` descends in strength, so `seenBy > byEnv` already
implies `seenBy > byConfig`.

A pre-existing nuance, not introduced by the Config Source tier: since
`applyFallbacks` gates on provenance per-Arg (not per-position), and a
real CLI match puts the Arg at `byCli` — strictly above both fallback
tiers, so both skip it —
an Arg reachable at more than one position in the matched Usage Line where
*some* positions matched a real CLI token and others were satisfied by a
fallback tier *during the walk* (via `probe`, which never writes to
`pc.matches`) has its walk-time fallback contribution silently dropped —
`applyFallbacks` never even looks at it, since the Arg already has a real
match. See `docs/adr/0018-config-source.md`'s "Consequences" section.

## 4. Value conversion (`argtypes.nim`, `src/argumint.nim`)

An Arg with a value is two classes: an untyped base whose methods dispatch
like any other, and a typed leaf generic over the value's type. Generic
methods don't dispatch, so the leaf has no methods of its own (ADR 0068).

```
Arg                     methods: the custom-Arg contract
├── ValueArgBase        not generic; ordinary methods
│   ├── ValueArg[T]     arg*/opt*: Option[T], a T default, a Validator[T]
│   └── ValuesArg[T]    args*/opts*: Option[seq[T]], a seq[T] default, the same
└── FlagArgBase         not generic; ordinary methods
    └── FlagArg[T]      flag*: a T value and default, a FlagClamp[T]
```

`ValueArgBase` holds what isn't typed -- `env`, `cfgKey`, and whether it's
multi-value -- and answers `accumulates`, `envSource` and `configKey` from
it. The three things that need the value's type are **hooks**,
`{.nimcall.}` procs the leaf's constructor instantiates for its type and
stores on the base; each takes the base and downcasts to the leaf:

- `write` converts, validates and stores a `Contribution`: the base's
  `accept` calls it.
- `reset` empties the storage: the base's `clear` calls it after dropping
  the provenance. `none` *is* the default-applies state (ADR 0008), so there
  is nothing to restore.
- `describe` computes `defaultStr`, `validatorHelp` and `completions`
  together, when help or completion asks; the three base methods each call
  it. Precomputing them was measured and rejected: it costs every run,
  `__complete` included.

**The rule for extending it:** a new base method a `ValueArg` answers is an
ordinary method on `ValueArgBase`, and needs a hook only if it touches typed
storage. A new kind of typed Arg follows the same two-class pattern.
`tests/test_argumint.nim` fails if a constructor leaves a hook unset, which
would otherwise compile and crash at the first call. A custom `Arg` subtype
overrides `Arg`'s methods directly, as before (ADR 0062).

`arg*`/`opt*` build the scalar arity and `args*`/`opts*` the multi-value one
-- see `docs/gotchas.md` for why these are separate procs rather than
overloads. The two leaves are distinct types, so `get`, `put`, `toT` and
`toSeqT` overload on them, and `replace` exists only for `ValuesArg`. They
differ in two small private overloads, `history` (what a Validator checks a
new value against when it extends) and `store` (set, or append in place);
everything else is written once over `AnyValueArg[T]`, a typeclass of the
two. The storage is an `Option` so "not supplied" (`none`) is told apart
from a tier-less write (`put`/`replace` with no `seenBy`, which stores but
leaves `seenBy` at `byNone`) and, for `ValuesArg`, from "supplied empty"
(`some(@[])`).

`initValueArg`/`initValuesArg` refuse to compile for a type that isn't a
Value Type: one that isn't a `BuiltInValue` (any number type, `string`,
`bool` or `char`; range types included, `distinct` ones not), isn't an enum,
and has no converter from string in scope where the generic is
instantiated. The check is the `ValueType` concept, tested with `isnot`
rather than used as a constraint, so the error can name the converter to
write.

Both leaf type names are exported from `argtypes` and re-exported by the
facade, on the same terms as `Spec` — nameable, state private — so an arg
can cross a proc or module boundary
(`docs/adr/0033-value-arg-flag-arg-exported.md`). `ValueArgBase` and
`FlagOp[T]` are not. Tests reaching a leaf's fields need `privateAccess`
*per instantiation*, not once per generic, and `privateAccess(ValueArgBase)`
for the base's.

Because those fields are private and `privateAccess` doesn't survive
instantiation elsewhere, the facade's constructors and accessors reach them
only through bookends `argtypes` exports for that purpose:
`initValueArg[T]`/`initValuesArg[T]` behind `arg*`/`args*`/`opt*`/`opts*`,
a deliberately *fat* `initFlagArg[T]` behind `flag*` (it performs the whole
build — ops, alias groups, duplicate detection, clamp-versus-default
check — rather than exposing mutators that could leave `ops` and `aliases`
disagreeing), and the `rawValue`/`rawDefault` templates behind
`get*`/`toT*`/`toSeqT*`. Reads get accessors; writes go through `init*`.
None of those names is re-exported; `tests/test_public_api.nim` asserts each
is unreachable from a bare `import argumint`, mirrored by a positive in
`tests/test_argumint.nim`.

`acceptImpl` converts the raw string with `fromString[T]`, then hands the
`T` to `storeImpl`, which runs the arg's `Validator[T]` (`validators.nim`)
if present — validation always happens against the scalar element type,
never `seq[T]`, since it runs before the value is stored/appended. `parse`
has already arbitrated the declared Value Precedence tier by then (see
below). `fromString` calls the built-in conversions (`toNumber[T]`,
`toBool`, `toChar`; strings pass through) by name, parses an enum with no
converter of its own with `parseEnum`, and otherwise writes `let x: T = s`,
which finds the user's converter where the generic is instantiated.
`parseFlagOpsString` uses it too. `toNumber` parses into a `BiggestInt`,
`BiggestUInt` or `float` and checks `T`'s `low`/`high`, raising
`OutOfRangeError` (a `ValueError` reading `expected a value in
-128..127`), which `acceptImpl` reports as `for -n, got "300" but expected a
value in -128..127`. A finite value too large for `float32`, whose bounds
are infinite, is out of range too, and so is `nan` for a float range type.

`describe`'s `defaultStr` renders `[default: <value>]` in help text (via
`display.showValue`, which quotes a string or char and `$`s the rest;
suppressed when the scalar default equals `zeroValue[T]()` — `default(T)`,
or the lowest value of a range type that excludes zero — since that's the
fallback `arg*`/`opt*`/`flag*` use when no default was given).
The base `Arg.defaultStr` (commands, flags, message args) returns `""`, so
flags never show a default.

`describe`'s `completions` lists the values of the arg's `describedBy`: its
`Validator`, or for an enum argumint parses, a `choice` of the enum's values
(gaps and all, via `std/enumutils`) -- replaced by the arg's own validator
when that lists values of its own, and filtered by it with `all` otherwise.
A bad enum value's `ConversionError` lists the same values. Its `validatorHelp`
describes the same Validator, except that a validator with no help of its
own leaves just the enum's values.
`Validator[T].styledHelp` returns a short styled description per kind, or
every kind's own `desc` with Help Markup applied instead when one was given
(`Validator[T].desc` is a single field shared by every kind, declared
*before* the `case kind` discriminator rather than inside a specific `of`
branch — a field name can't be redeclared across two separate `of` branches
even with an identical type in each, but a field declared ahead of the
`case` is implicitly shared by all branches). `genHelp` combines
`validatorHelp` and `defaultStr` into one bracket, `;`-separated (e.g.
`[choices: "foo", "bar"; default: "foo"]`). `FlagArgBase` (see "Flags"
below) answers `validatorHelp` too -- reusing the same extension point,
even though a Flag never carries a `Validator` -- through its `describe`
hook, which returns its `FlagClamp[T].styledHelp` if one is attached (see
"Flag Clamp" below). `FlagArg` still has no `defaultStr` override, so a flag's
coded default never appears in help output regardless of whether it has a
clamp.

All of this generic code is instantiated in the user's module, so its
unqualified calls resolve there (`docs/gotchas.md`); `argumint.nim`'s
top-of-file `export` statements are what make that resolve for a caller
that imports nothing else. Both `argtypes` and the facade carry
`{.experimental: "openSym".}`. See
`docs/adr/0017-argumint-reexports-for-custom-arg-types.md`.

The four string-to-scalar conversions stay **private to `argtypes`**, and
are plain procs rather than converters: exporting them as converters would
put `let n: int = "5"` in scope for everyone who imports argumint (ADR 0068
lists what else would compile). A converter for a user's own `T` is
declared in the user's own module and found where `opt` is instantiated,
which is where it needs to be.

### The write side: `parse`, `arbitrated`, `clear`, `action`

`Arg.parse` is the only thing that writes an Arg's value, on every tier and
from application code alike. It is re-exported through the facade
(`export backend.parse, backend.clear`; `action` is in
`argumint/customarg`), so writing a value needs no backend import:

```nim
port.parse("8080", seenBy = some(byCli))  # declares a tier; visible to `get`
port.parse("8080")                        # extends the current tier, whatever it is
port.clear()                              # back to the coded-default state
flag.parse("-v")                          # applies that Variant's Flag Operation
```

The optional `seenBy` is what makes a tier-less write useful rather than
merely legal: ADR 0040's readers originally branched on `seen` alone, so a
write that declared no tier was written but unreadable. ADR 0044 (issue
#29) changed that per Arg kind -- a `ValueArg` or `ValuesArg` now reads
whatever is stored regardless of `seen` (since #213, `some(@[])` is a
`ValuesArg`'s supplied-empty state, so `seen` no longer enters into it); a
`FlagArg` reads
`seen`-or-differs-from-its-coded-default, so a tier-less write is visible
once it actually changes the value and invisible only in the narrow case
where it reproduces the default exactly. See
`docs/adr/0041-parse-is-the-write-surface.md` and
`docs/adr/0044-put-typed-write-accessor.md`.

`parse` is a plain proc, not a method, so no Arg can skip the tier rule.
It writes through `arbitrated` (withheld in `backend.nim`, with the bare
`arbitration` decision private behind it), which decides what a
contribution at the declared tier does, runs the store with that decision
as `how`, and only then records a stronger tier -- so a store that raises
before clearing (as the built-ins do, validating first) leaves the Arg at
its old tier. `parse`'s store packs the value into a
`Contribution` and hands it to `accept`, the one method a value-carrying
Arg overrides:

```nim
proc parse*(self: Arg, value: string, variant = "", seenBy = none(SeenBy)) =
  self.arbitrated(seenBy):             # a weaker tier never runs this
    self.accept(Contribution(value: value, variant: variant, tier: seenBy), how)
```

A tier weaker than the one recorded is refused (`parse` never demotes --
`clear` first if that is what you want); an equal one (or none declared)
extends without clearing, so values from one tier accumulate; a stronger one
replaces: the Arg is cleared and records the new tier. Because the first CLI
match replaces, every later match in the same parse extends with no extra
bookkeeping. `put`'s `putImpl`s write through `arbitrated` too, since a
typed `T` can't go through `accept`'s string.

`accept` is told which of the two outcomes applies and does the rest.
`ValueArg`'s `storeImpl` shows the shape every override follows:

```nim
if validate and not self.validator.isNil:
  case how
  of arExtend: self.validator.validate(value, self.history)  # check against what's there
  of arReplace: self.validator.validate(value)               # those values are going away
if how == arReplace:
  self.clear
self.store(value)
```

Checking *before* clearing is load-bearing: conversion and validation both
happen first, so a `parse` that raises leaves the Arg exactly as it was
rather than cleared and stamped with a tier it never received a value from.
`FlagArg.accept` looks up `c.value` as the Variant whose Flag Operation
applies -- on every tier, since an env or config value for a Flag names a
Variant too -- then clears on `arReplace` and applies the operation.

The Contribution carries no source label. `subject(arg, c)` names the Arg
in an error: `c.variant` if one was typed, or `--port (env: PORT)` /
`--port (configKey: server.port)` for a `byEnv`/`byConfig` tier, read off
`arg.envName`/`arg.configKey`. See
`docs/adr/0062-accept-is-the-override-point.md`.

The base `accept` is a *quiet recorder*: it clears on `arReplace` and does
nothing else, and never raises. That is why `CommandArg` and `MessageArg`
need no override and still get provenance, and it mirrors how `defaultStr`
and `completions` already treat the value-less kinds. `clear` has the same
shape -- exported `{.base.}` no-op, unexported per-type overrides -- and
always clears provenance alongside the value, since an Arg reading as Seen
with an empty value seq would make ADR 0040's scalar accessor index it.

`Arg.action` is separate from `parse` and carries the side-effecting kinds:
it fires for an Arg whose `isMessage` method returns `true`. One signature,
`action(info: HookInfo, variant)`, serves every kind: `MessageArg` raises
`MessageError` and ignores `info`, while `HelpArg` uses `info.here` (the
level's Spec and command) to render help before raising `HelpError`. A
value-holding Message Argument (a `ValueArg[T]` subtype) reads its own
value, parsed already by `storeValues`: `completion()`'s `ShellArg` is
one, rendering `info.root.spec`'s script for `info.root.command` (ADR 0074).
That uniformity is what lets `parseMessageArgs` dispatch once, with no test
for which kind it holds (ADR 0073). Each override lives beside its own type:
`MessageArg`'s in `backend.nim`, `HelpArg`'s in `help.nim` (where it renders
through the `HelpArg`'s own Help Formatter, ADR 0048), and `ShellArg`'s in
`argumint.nim`, which alone imports both `argtypes` and `completion`.
`HelpArg` renders a plain `msg` through a Help Context with no styler and,
only if the Spec has one, a second time for `styledMsg` (ADR 0059).

The method is a dependency inversion, and a deliberate one. `genHelp` now
lives in `help.nim`, *below* `fsm.nim` (issue #50), so the FSM could raise
`HelpError` directly and skip `action` entirely. It doesn't: routing through
one uniform signature is what lets `parseMessageArgs` stay free of the `of
HelpArg` test ADR 0041 removed, and `action` is the extension point a custom
side-effecting Arg plugs into. The alternative has been measured; the
inversion is what's kept.

A custom `Arg` subtype (ADR 0030) therefore owes two things: override
`accept` (clearing on `arReplace` before it stores), and override `clear` if
it carries a value. `accept` comes from `argumint/customarg`, whose
`initArg` sets its kind and Variants (ADR 0076); `clear` from the facade.

To opt into either fallback tier it overrides one method per tier —
`envSource` (returning the whole `Option[EnvSource]`, name and delimiter
override together) and `configKey`. `envName` is *not* one of them: it is a
plain proc derived from `envSource`, so a subtype gets it for free and
cannot make the two disagree. Both methods and the derived proc are
re-exported from `argumint.nim`, so overriding *or reading* either needs no
`backend` import — the read half is what a caller rendering its own help
needs, `genHelp` being opt-in (ADR 0042). Overriding never actually needed
the export: Nim attaches an override to `backend`'s method family because
`Arg` is in scope. See
`docs/adr/0046-arg-value-source-contract.md`.

`get`/`get(otherwise)` and `put` (issue #29, ADR 0044) are plain generic
procs over `ValueArg`/`ValuesArg`/`FlagArg`, not methods on `Arg` -- so
neither is part of the custom-`Arg` contract above, and neither dispatches
through a subtype's `accept` override. `put` writes `self.value` directly
through the same `arbitrated`/`putImpl` path every built-in
`ValueArg`/`FlagArg` uses; a custom `Arg` subtype has no `value` field for
it to reach and so cannot be driven through `put` at all -- `parse`, through
its own `accept` override, remains the only write path into it.

### Flags

`FlagArg[T]` follows the same two-class pattern as the values above:
`FlagArgBase` holds what isn't typed -- `env`, `cfgKey`, and a seq
pairing each Variant with its `BoundOp` -- and two hooks, `reset` (restore
the default) and `describe` (the clamp's help). No flag type is
registered; there's no `flagOps` table and nothing generated per type (ADR
0070).

A **Flag Operation is a closure** on the flag's value, `proc (value: var
T)`, carried by the public `FlagOp[T]` with its spellings and Flag
Operation Description. `initFlagArg` binds each one to the flag:
`bindOp[T]` wraps it in a `proc (self: FlagArgBase)` that downcasts to
`FlagArg[T]`, runs the op on `value`, then the clamp. The bound closure
captures only the op's own closure, never the flag, so there's no
reference cycle. `bindOp` is a proc of its own rather than inline in
`initFlagArg`'s loop, because a closure built in a loop body shares the
loop's variables (`docs/gotchas.md`). Its `BoundOp` also stores the
description and a group number, one per `FlagOp`; the base's methods read
nothing else:

- `accept` looks up the Variant (`c.value`, on every tier), raising
  `ConversionError` for one the flag doesn't have, clears on `arReplace`, and
  runs the bound op.
- `aliases` compares group numbers: the bare spellings in `flag*`'s own
  `variants` are one group, and each `flagOp` another, even if two do the
  same thing (`docs/adr/0027-flag-op-declarations.md`).
- `variantDesc` returns the stored description, or `""` unless the flag's
  descriptions differ (ADR 0063). `genHelp` (via `variantsByDesc`) and
  completion (`describeVariants`) show it as is.
- `accumulates` is always true; `envSource`/`configKey` read the fields.

Where the closures come from:

- **Named ops** (`=`, `+=`, `-=`, `*=`): `namedOp[T](op, value)`. On a
  number, `+=`/`-=`/`*=` go through `stepped`, which does the arithmetic in
  `T`'s base type with `addSat`/`subSat`/`mulSat` -- each checks the bounds
  before the operation, so nothing overflows -- then clamps to
  `low(T)..high(T)`, so a range type stops at its own bounds. On any other
  type, `x op= value` uses `op=` if it compiles and `x = x op value`
  otherwise, which is what makes sets and a `distinct` type with borrowed
  operators work with no special case. `opError[T](op)` says why `T` can't
  do an op, or `""`; the facade's `flagOp` evaluates it at compile time
  (`op` is a `static string`) and turns it into `{.error.}`, and
  `parseFlagOpsString` raises it as `SpecDefect`, so both say the same
  thing. `describeOp` generates the description ("Increase by 5", "Add
  red, ham"), values through `display.showValue`.
- **Procs**: `flagOp(variants, apply, help)` stores the user's closure as
  is; `flagOpIt[T]` is a template building one from an expression in `it`.
  Neither generates a description.
- **Implicit Operations**: `implicitOp[T](default)` gives `bool` "set to
  the opposite of `default`", integers `stepped(+1)` and enums `next`
  (walking `enumutils.items` for an enum with gaps), each stopping at the
  type's last value. Any other `T` returns an op with no `apply`, and
  `initFlagArg` raises `SpecDefect` if `variants` has bare spellings.

The string form of `ops` (`parseFlagOpsString`, ADR 0028) matches each
entry against `FlagOpEntryFormat` (a Flag spelling from `variant.nim`'s
fragments, then an op and a value), which accepts only the four named ops;
an entry it rejects is matched against `UnknownFlagOpFormat` to report the
op it did find. Values go through `fromString[T]`, or for a `set[E]`
through `fromString[E]` into a one-element set.

`flag*` runs `initFlagArg`, which flattens every group (the implicit one,
then each `FlagOp` in order) into `ops`, raising `SpecDefect` on a
duplicate Variant.

### Flag Clamp

`FlagClamp[T]` (`argumint/values/flagclamp.nim`) is a leaf module with no
dependency on `backend`/`argumint`, deliberately structured to mirror
`Validator[T]` (`validators.nim`) without being one -- see
`docs/adr/0016-flag-clamp.md` for why the two are kept separate. It's a
`case`-discriminated `ref object` with two kinds, built via two
constructors: `clamp[T](bounds: Slice[T], desc = none(string))` (requires
`T` to support `<`, checked where `clamp` is called, so a flag of a type
without it still works unclamped) and `adjust[T](proc: proc(v: T): T, desc =
none(string))` (any `T`). Not named `range` -- that collides ambiguously
with `validators.range` the instant both modules are imported into the
same file, which `argumint.nim` does; Nim doesn't disambiguate two identical-signature
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
`FlagArg[T].clamp`. Each bound Flag Operation (`bindOp`, "Flags" above)
calls `self.value = self.clamp.apply(self.value)` right after its own
closure, whatever tier the Variant came from. So the clamp runs once per
Flag Operation actually applied: a tier supplying several Variants calls
`parse` once per value, and each call clamps.
`FlagArgBase.clear` calls the `reset` hook, which restores `value` from
the private `FlagArg[T].default` field the constructor retained -- a Flag has
no empty state to fall back to the way a `ValueArg` does, and its operations
mutate `value` in place, so without that field its construction-time state
would be unrecoverable. Restoring it can never violate the clamp, because
spec construction already rejected a default that did.

`flag*` itself also runs `clamp.apply(default) != default` once, at spec
construction, before returning -- since `FlagArg.value` is seeded directly
from `default` with no separate substitution tier the way `ValueArg`'s
default has (contrast the previous section's `ValueArg`, where the
default is stored separately and never even passed through `Validator`), a
default that doesn't already satisfy its own clamp is a `SpecDefect`, not
something silently corrected at runtime.

### Env values, validators, help layout

`opt*`/`opts*`/`flag*` (not `arg*`/`args*` — env vars map naturally to a
named value, which a Positional Argument doesn't have) take an `env` param
naming an environment variable — see the Runtime Matching section above for
the mechanics and `docs/adr/0004`/`docs/adr/0005` for the design rationale.

A Help Formatter (`help.nim`) renders the whole help message from a
`HelpContext` (ADR 0048, ADR 0057). `genHelp` builds the context from the
Spec's settings (`helpContext`) and calls the formatter with it. Both
built-ins are the exported Help Frame (`frame`, ADR 0075) and a `RowRenderer`
(`columnLines`, `paragraphLines`). The frame joins prolog (`ctx.prose`), the
usage block (`usage.usageBlock`, which `ctx.usage` is without its heading),
one block per `ctx.groups` entry (its heading, then its Rows -- built with
`HelpTextForm`'s help text -- through the renderer), and epilog with
`joinSections`, rendering every line with the context's Styler. The
context holds the Styler, and every piece it hands out (`rows`, `prose`, `markup`) has
Help Markup's ticks already resolved for it, so a formatter never decides
that itself; `ctx.render` renders with the same Styler. `Spec.settings.width` wraps usage lines
(`usageLines`) and every row's text. The getter never returns less than
`MinWidth = 20` (`console.nim`), so help and parse errors share one clamp
and nothing below it re-floors the width. Its default, `0`, is detected
on the getter's first read by `resolvedWidth` (`console.nim`) and kept
(ADR 0058): `detectWidth()` (`COLUMNS`, else the terminal's width, else
`DefaultWidth = 80`), capped at `DefaultMaxWidth = 100` (ADR 0052). All
the `newSpecSettings` defaults can be set with `-d:argumint.*` defines (ADR
0053), `theme` with one per Style Role building `defaultTheme`.
`Spec.settings.maxVariantsWidth` (default `DefaultMaxVariantsWidth = 30`)
caps Column Style's "variants" column (e.g. `-v, --verbose, --quiet`) so
one arg with many aliases can't inflate the shared column width for every
other row. `0` disables the cap.

Each formatter builds an arg's rows via `ctx.rows(arg, help =
arg.help.short): seq[Row]`, which wraps the private `rows` and resolves one
`Row` per
`arg.variantsByDesc()` bucket — `variantsByDesc` (alongside `rows`)
buckets an arg's variants by their `variantDesc` text, one bucket per
distinct behavior. `Arg.help` is a `HelpText` pair (ADR 0049): Column Style
passes the default short form, Paragraph Style passes
`arg.help.longOrShort`, preferring the Long-Form Help Text when declared.
Every bucket's row shows that same text plus the arg-level annotations
(`validatorHelp`/`defaultStr`/`envName`/`configKey`, assembled in that
order by `annotations(arg: Arg, action = ""): seq[StyledText]`), not just the
first-declared variant's — that repetition, not indentation, is what
visually ties divergent rows together as variants of the same value. When
a bucket's own `variantDesc` is non-empty (it only is when the variants
diverge), `rows` passes that desc to `annotations` as `action`, appended last as
`[action: ...]` (deliberately labeled `action:`, not `default:`, so it
can't collide with a hypothetical future `[default: <value>]` for a flag's
own starting value) — but only when the help text is non-empty, since
otherwise there'd be nothing for the bracket to disambiguate from; in that
case `rows` uses the bucket's own `variantDesc` directly as the row's text
instead.

Everything a formatter lays out is `StyledText` (`style.nim`): a sequence
of `Span`s, each a run of text with a `StyleRole`. `Row.variants`, each
of `annotations`' parts, and each of `usageLines`' lines are `StyledText`;
`Row.text` and `HelpContext.prose`'s result are Prose, which `wrap` turns
into `StyledText` lines (below). The rule every built-in follows, and a
custom formatter should too: build `StyledText` (or take Prose), `wrap` it
to a width (one `StyledText` per line, splitting any span that
crosses a break, so no span ever holds a `\n`), pad with `len` or
`alignLeft` (visible width, in graphemes of the plain text), and `render`
once per finished line.
`styled(text)` is shorthand for `styled(srPlain, text)`. `render` takes a
`Styler` (`proc (role, text): string`) applied per span, or nil for plain
text; because every measurement happens before it runs, a styler can add
escape codes without skewing any width. `add`/`&` keep `StyledText`
normalized (no empty spans, adjacent same-role spans merged), so two equal
texts compare equal whatever order they were built in. `style.nim` is a
leaf beneath `help.nim`, which re-exports the formatter-author names
(`complaints.nim` reaches `render` through that re-export). It also holds
the corrected `wrapWords` fork `wrap` is built on (see `docs/gotchas.md`).
`wrap` wraps the plain text with that fork, then walks the result mapping
each byte back to its source span's role. That mapping relies on the fork
only ever dropping separators, turning a newline-only separator into a
space, and inserting line breaks -- never altering a word's bytes.

Roles are assigned where the text is built (ADR 0051). `rows` tags each
variant by its Arg's kind (`styledVariant`, which splits an option's
`=<m>` or `=M` into `srOption`/`srPlain`/`srMetavar` through
`style.styledOption`, shared with complaints), and runs the help text through
`markup` with the Arg's own `metavars`, derived from its variants by
`parseVariant`. `annotations` tags the
bracket, `;` and key labels `srAnnotation`, and its values `srLiteral` or
`srEnv`; the validator part comes from `validatorHelp`, which now returns
`StyledText` built by `Validator.styledHelp`/`FlagClamp.styledHelp` (whose
`.plain` is the string `help()`). `usageLines` tags the command path
`srProgram` and styles each line through `lexer.displayTokens`, which runs
the lexer's own token PEGs over the line without raising, keeping
whitespace and unknown characters as `tkInvalid` pieces. Headers are
`srHeader`.

A prolog/epilog and an Arg's help text share one re-flow rule (ADR 0054),
owned by `prose.nim`, a module above `style.nim` and below `help.nim` and
`completion.nim`. `toProse` dedents the text (`dedentLines`) and joins its
lines into `ProseBlock`s (paragraphs, list items, indented lines, and
blanks), each with `markup` applied after joining (against the Arg's
`metavars`, for help text). The result is an opaque `Prose` (ADR 0060):
`rows` builds one per bucket and hands it to `annotate`, which appends the
`annotations` bracket to one-block text or after a blank line otherwise,
flattening each part to one line (`oneLine`) so it can't span blocks.
`HelpContext.prose` is `toProse` with the ticks resolved (`withoutTicks`
has a `Prose` overload). `wrap` is the only way out: each block starts at
its indent and marker and wraps hanging under its text. `paragraphLines`
and `columnLines` both call it; in Column Style each line starts at the
text column, even while the variants are still wrapping. A blank line in a
row stays empty in both, with no margin. No line `wrap` yields contains a
newline, so no span a styler sees does either. `help.nim` re-exports only
`Prose` and its `wrap`; the rest is withheld.

Help Markup (`markup` in `style.nim`) classifies a backticked span by shape
only, via `OptionShape`/`PlaceholderShape`/`EnvShape` (placeholders in
both the lexer's `<name>` and `NAME` forms). It always keeps a code
span's backticks, as `srTick` spans of their own, so text built far from
help (`validatorHelp`, `annotations`) needn't know whether there's a
styler. The Help Context drops them with `withoutTicks` when it has a
styler, before anything measures or wraps the text, so plain output keeps
them and styled output doesn't (ADR 0057). `plainMarkup` is the plain
form for prose that never reaches a styler: completion descriptions,
`ValidationError` messages, and `help()`.

The styler itself is `spec.settings.style`. Its default, the `autoStyler`
marker, is resolved on the getter's first read by
`resolvedStyler(settings.theme)` (`console.nim`) to `ansiStyler(theme)` or
nil, and kept (ADR 0058, 0067). Its env-var rule is the pure
`wantsColor(env, ttys)`, so tests can drive it without a terminal, behind
the public `wantsColor()` probe; on Windows, `enableVirtualTerminal` sets
`ENABLE_VIRTUAL_TERMINAL_PROCESSING` through `winlean`'s
`getConsoleMode`/`setConsoleMode`.

**Column Style** (`formatColumn`) aligns rows into two columns shared
across every group. `colWidth` comes from `variantsColWidth(spec: Spec):
int`, the widest single bucket's joined names (via `rows`), not the widest
whole-`Arg`'s — and, deliberately unfiltered by `hidden`, a hidden arg's
long variant name still counts toward the column width even though its own
row never renders (existing behavior, preserved as-is rather than
endorsed). `columnLines(rows: seq[Row], width, colWidth: int):
seq[StyledText]` wraps variants at `colWidth` and text at the remaining
width (at least `MinWidth`), zipping them
line-by-line so the help text stays inline with the first variants line.
Each bucket's row starts at the 2-space `Margin` — buckets are peers
(different variants of the same `Arg`), not a wrap continuation of one
another. A variants wrap continuation starts at the deeper 4-space
`ContinuationIndent`, but every text line starts at the text column
itself: a paragraph's wrap continuation, each later block, and a list
item's or indented line's continuation (which `wrap` has already
hung) alike.

**Paragraph Style** (`formatParagraph`) instead puts each row's variants on
their own `Margin`-indented lines, wrapped to the full width, with its text
wrapped below at `ContinuationIndent`; rows are separated by a blank line
(`paragraphLines`). There's no shared column, so `maxVariantsWidth`
doesn't apply.

`width`/`maxVariantsWidth`/`envDelim`/`configSources`/`style` live together on
`Spec.settings: SpecSettings` (`src/argumint/core/settings.nim`), a `ref object`
built once by `newSpec*`'s `settings = newSpecSettings()` param and shared
by reference — not copied — into every nested subcommand's `Spec` via
`cascadeSpecSettings` (`src/argumint/grammar/specbuild.nim`). `settings` is
deliberately not a parameter to `command*` itself: since it's the same
shared instance throughout the tree, it only needs to be set once at the
top-level `newSpec`/`parse*` call regardless of nesting depth. Being a ref
rather than four plain fields also means a later mutation of that same
`SpecSettings` — e.g. from a `before` hook — applies live to every
not-yet-dispatched `Spec` in the tree, including the current level's own
message/help output once `parseMessageArgs` runs after `before` (see
`docs/adr/0013-message-args-fire-after-before.md`). `envDelim` and
`configSources` are the exceptions: both fallback tiers' resolution
(`applyFallbacks`, §3c) runs to completion across the whole tree before
`dispatch`/any hook is ever called, so a hook-time mutation to either has
no effect on that parse's fallback-tier handling, even though both are
cascaded the same way for consistency (see
`docs/adr/0018-config-source.md`'s "Corrected claim" section for the
Config Source case specifically).

Converters `toT*[T](arg: ValueArg[T]): T` and `toSeqT*[T](arg:
ValuesArg[T]): seq[T]` return the field's value transparently at
use-sites — code reads `spec.dest` rather than `spec.dest.value`.

Both are one-line delegations to `get*`, the explicit accessor that reads
the same value where a converter can't fire (generic inference binding `T`
to the Arg itself — `join`, `in`, `some`, a `case` selector). The
`get*(arg, otherwise)` overloads are `template`s rather than `proc`s so
`otherwise` stays unevaluated on the supplied path; each binds `arg` to a
local so the operand is evaluated exactly once. They read `ValueArg`'s
private `value` field (via `rawValue`/`rawDefault`, `argumint/values/argtypes`)
from an expansion in the caller's module, which works because the
accessors are declared beside the type (`docs/gotchas.md`). None of the three
branch on `seen` alone as originally specified by ADR 0040 — ADR 0044 (issue
#29) changed each once a tier-less `put`/`parse` could leave provenance and
the stored value disagreeing on purpose: a `ValueArg` or `ValuesArg` tests
only whether `rawValue` is `some` (a `ValuesArg` holding `some(@[])` was
supplied empty, and reads as itself); a `FlagArg` tests `seen` *or*
`rawValue != rawDefault`, so a tier-less write is visible once it actually
changes the value. The no-arg `get` is the same template called with the
Arg's coded default as `otherwise` (`arg.get(otherwise = arg.rawDefault)`),
so the library holds exactly one substitution rule per Arg kind rather than
a second copy of it; `FlagArg`'s no-arg `get` returns `value` outright, its
coded default being its starting value rather than a substitution tier.
See `docs/adr/0040-explicit-value-accessor.md` and
`docs/adr/0044-put-typed-write-accessor.md`.

## 5. Subcommands

`command*` builds a `CommandArg` wrapping its own nested `Spec` (built via
`newSpec` from a nested arg tuple), optionally binding `before`/`action`/
`after` hook closures onto that nested `Spec` (not onto the `CommandArg`
itself — see below). A subcommand's FSM is spliced into the parent's FSM
as a single `mkCommand`-kind transition (see `atom()`'s `tkCommand` branch in
`parser.nim`), with all of the subcommand's terminal states wired via
shortcut back to a single continuation state in the parent graph.

### Dispatch order

Runtime matching (§3 above) populates one flat `pc.matches:
OrderedTable[Arg, seq[Match]]` across the *entire* spliced FSM, regardless
of depth. Each `Match` additionally carries the `Spec` it was recorded
under (`matching.nim`'s `push`, reading `pc.spec` at the exact moment of the
match — safe because `ParseContext` is a plain `object`, not a `ref
object`, so `walk`'s backtracking clones it per candidate branch and only
commits the winning branch back) — this is what lets dispatch scope a
match to the correct level even when the same `Arg` is reachable at more
than one grammar level. Exactly one consumer relies on it:
`parseMessageArgs`. Value parsing no longer does (see `storeValues`
below), and neither does dispatch, which reads the chain of levels the
walk recorded as it descended — see below.

After a successful walk, `Spec.parse` calls `pc.storeValues`, whose
first phase, before the env/Config Source sweep, parses every match in
`pc.matches` — the whole tree, before any hook fires. Commands and Message
Args are included rather than skipped: they hit the quiet base `accept`, and
`parse` records `byCli` and does nothing else, which is how they get
provenance now that no blanket post-walk sweep writes it. Because
`pc.matches` is already flat across every level, this is a plain loop over
the table: no spec-tree recursion, no `Match.spec` filtering, and no dedupe
pass, since an Arg shared by two levels holds all its matches under one key
and so is parsed exactly once. Every match in the table is sorted by
`Match.idx` together, so failures are reported in the order typed (ADR
0077). Each Arg's own matches keep the relative order they had when they
were sorted one Arg at a time, so a shared Arg composes identically to the
old level-by-level walk, because ADR 0010 makes each level's tokens a
contiguous run in command-line order.

The env and Config Source tiers are likewise parsed up front, by
`storeValues`' second phase, `applyFallbacks`; every tier is converted
before `dispatch`, so a value that fails to convert or validate raises
before any hook can run a side effect, on every tier. Nothing stops at the
first failure: every value that passes is written, every one that fails is
recorded, and `parse` raises them all together once both phases are done.
An Arg whose command-line value failed is closed to the fallback tiers, so
they neither write to it nor complain about it. See
`docs/adr/0032-parse-all-values-before-dispatch.md` and
`docs/adr/0077-report-every-bad-value.md`.

The three supplied tiers run strongest-first, which is Value Precedence
read top-down:

```
walk
storeValues      # both tiers below, before any hook
  CLI matches    #   each match records seenBy = byCli as it writes
  applyFallbacks #   env unless seenBy > byEnv, then config unless > byConfig
dispatch         # hooks only
```

Provenance is written per contribution, by `parse` as the value is
written, so it can never outrun the value it describes.
`storeValues` covers the whole matched tree — commands and Message Args
included, via the quiet base `accept` that stores nothing — so
provenance is complete before the first hook, at any dispatch depth. Each
contribution goes through `arbitrated` against the tier already
recorded: a stronger tier clears first, an equal one appends, a weaker one
applies nothing. The first CLI match therefore clears any pre-seed and
records `byCli`, which moves every later match into the append branch with
no "is this the first value" bookkeeping. Ordering the passes
strongest-first is a separate choice, with one consequence: a bad
command-line value is listed before a bad env or config one. See
`docs/adr/0039-per-arg-provenance.md` and
`docs/adr/0041-parse-is-the-write-surface.md`.

The walk already knows which levels it entered, so it records them rather
than letting the post-walk passes re-derive them. `ParseContext.levels` is a
root-first `seq[Level]`, where `Level` (`backend.nim`, beside the `HookInfo`
that carries two of them) is `(spec: Spec, command: string)`: the `Spec`
owning that grammar level, plus the accumulated command string naming it
(`"app"`, `"app go"`, `"app go stat"`). `initParseContext` seeds it with the
root entry, on both the parse and the completion path; `match`'s `mkCommand`
branch appends one entry right after it reassigns `pc.spec`/`pc.command`.
`storeValues` sweeps the fallback tiers over it on both paths. Backtracking
needs no special handling: `ParseContext` is a plain `object` whose every
field is a value type, so `walk`'s clone-per-candidate/commit-the-winner
discipline discards a losing branch's chain entry along with the branch. At
most one Command can be matched per level anyway — a matched `mkCommand`
transition permanently updates `pc.spec` to the nested spec for the rest of
the walk, so a sibling command word can never be recognized afterward —
which is why the chain is a list, not a tree.

Both post-walk passes read it. `applyFallbacks` (§3c) is a flat loop over
the chain's specs (`fsm.parse*` passes `pc.levels.mapIt(it.spec)` --
`precedence.applyFallbacks` itself has no need of the command string half
of `Level`), needing neither a `Spec` lookup of its own nor the
`MatchTable` to find its next level. `dispatch` recurses over an index
into `pc.levels` directly, since it does need the command string.

`Spec.parse` then builds a `HookInfo` with `matched` from `pc.matches`
-- every Arg with at least one match, across every level, computed once
from the walk already performed (not a second walk) -- and `root` from
`pc.levels[0]`, then descends the recorded chain via
`dispatch(pc.levels, 0, pc.matches, info)`. Each level copies `info` and
sets `here` to its own `Level` on the copy. At each level:
`spec.before(info)` fires, if set, with every matched level's values
already parsed; `parseMessageArgs` then fires (via `Arg.action`, and raises
on) any matched Arg whose `isMessage` is `true` at this level (still
filtered by the `Match`'s `Spec` provenance, so a shared `help()` fires at
the level it was typed at rather than the shallowest one declaring it); if
this is the chain's last entry, `spec.action(info)` fires (this Spec is the
dynamic leaf for this invocation); otherwise `dispatch` recurses on the next
index;
finally `spec.after(info)` fires, wrapped in a `try/finally` around the
message-arg/action-or-recursion step so it's guaranteed to run once
`before` (or its absence) has completed without raising, regardless of
what happens afterward — including a Message Argument match, which is treated
as this level's action-equivalent for firing purposes: it runs after
`before` and inside the same `try/finally`, so `before`-time state changes
are visible to it and `after` still fires as cleanup even though it raises.
Applied recursively, this gives `before` a root-to-leaf firing order,
`action`/a matched Message Argument firing exactly once at whichever level
turns out to be the leaf, and `after` a leaf-to-root order — and, since
each level's `after` is reached via its own `try/finally`, an ancestor
whose `before` already ran still gets a chance to clean up even when
something nested inside it fails, with no explicit bookkeeping. See
`docs/adr/0009-command-before-action-after-hooks.md` and
`docs/adr/0013-message-args-fire-after-before.md`.

Since `info.matched` is computed once and copied unchanged into every
level, it (and its `showsMessage(info)` convenience -- true if any matched
Arg's `isMessage` is `true`) is a flat view
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
  for each one. **Message Arguments** (e.g. `help()`) are still filled in
  per-arg — each missing one gets its own appended line — since they never
  carry the `[options]` prefix to begin with and are independently optional
  to mention. Mentioning one variant of a multi-variant arg counts as
  reachable; it won't be duplicated. A Positional one is the exception: it
  goes in the positional line below, like any other Positional Argument.
- **Positional args** are all-or-nothing: only auto-appended (as one joined
  `<a> <b>` line, in declaration order) when *none* of them are reachable
  yet. A partially-specified sequence is left alone. An `Arg` whose
  `accumulates` method returns `true` (an `args`) is written `<a>...`;
  this is only a hint, so a hand-written `<a>` still matches one value.
  More than one accumulating Positional Argument raises a `SpecDefect`
  instead, since how values split between them is the author's call.
- **Options** (`opt`/`flag`, not Message Arguments) aren't their own usage line;
  `[options]` rides along as a prefix on whatever command/positional line
  gets auto-appended above. If nothing else gets appended but some option is
  still unreachable, a standalone `[options]` line is added as a fallback,
  ahead of the Message Argument lines, so the help and version lines still
  come last.
  Weaving `[options]` into an arbitrary hand-written line that's missing it
  is not attempted.
- **A Bare Call** (`{cmd}`, ADR 0061) is added ahead of the Message Argument
  lines when `spec.usage` is still empty by then, i.e. nothing was
  hand-written and nothing else was filled in. Otherwise a spec holding only
  `help()` would accept nothing but `-h`, so a command like that couldn't
  run its action (#175).

## 6. Shell completion (`completion.nim`)

A compiled binary's `parse*`/`parseOrQuit*` intercepts a magic leading arg,
`mycli __complete <partial words...>`, before any real FSM matching, env
fallback, or dispatch — short-circuiting into `completion.reply*`, which
calls `completion.resolveCompletion*` to re-walk `spec.fsm` and resolve
candidates dynamically rather than via a static generated script. See
`docs/adr/0012-fsm-driven-shell-completion.md` for why. `completion.nim`
owns the wire format whole: the marker (`CompletionMarker`, tested by
`hasCompletionMarker*`, which the facade's `isCompletionRequest*` wraps so
its doc shows on the facade's page), and `reply*`, which renders a
`Completion` as `parse*`'s `CompletionError` message. `parse*` only checks
the one and raises the other.

`completion.collectFrontier` generalizes `walk`'s single-winner backtracking
into "every state simultaneously still reachable after consuming the tokens
typed so far" (a `Frontier`), since several Usage Lines or `choice`
alternatives can all still be live for a command line that isn't finished
yet. It reuses `matching.match` unmodified, so env-var fallback (`docs/adr/
0004`, `docs/adr/0005`) applies to completion exactly as it would to a real
parse — see issue #78 for why this lives beside `resolveCompletion*` in
`completion.nim` rather than in `fsm.nim` alongside `walk`, the module it
originally sketched into. `resolveCompletion*` reads each live frontier state's
own outgoing
transitions for next-word candidates (`candidateWords`) — or, when the last
already-typed word is itself a bare Optional-kind option name still
awaiting its value (`pendingOptionalArgs`), completes that Arg's value
instead. Either way, a value's candidates come from `offerFor` (see
"Completers" below): the Arg's Completer, or by default its own
`completions()` (populated from a `Validator`'s enumerable candidates — see
`validators.completions`/`Arg.completions`). Candidate
words are read from `spec.options` (the canonical bare-spelling → `Arg`
map `match`'s `mkOption`/`mkOptions` branches themselves resolve against), not
`Arg.variants` directly — the latter, for an Optional-kind `ValueArg`
(`opt`/`opts`), still carries any declaration-time `=<placeholder>` suffix
used only for help-text rendering. `candidateWords` skips a `hidden` Arg,
but `pendingOptionalArgs` doesn't, so a hidden option's values still
complete once its name is typed — see
`docs/adr/0065-hidden-args-are-not-completed.md`.

### Options after a positional

An option matcher scans ahead past positionals (§3), so parsing accepts
`[options] <file>` as `in.txt -b`. But the walk that consumes `in.txt`
first ends in the state after `<file>`, which has no option transitions,
so `candidateWords` alone offers nothing there. The graph's shape doesn't
help either: once `fsmgraph` drops the shortcuts, the `[options]` copy
only rejoins the walked path through a consuming `Argument` transition,
and a state further back may lead to a Usage Line the typed words have
already ruled out (`-h` after `deploy staging`).

So `resolveCompletion*` also probes. For each option of every spec level the
frontier reached (`levelOptions`), `accepts` appends it to the typed words
(with `=x` for an Optional-kind option, since the walk never checks a
value) and asks whether `collectFrontier` still finds a live branch; if
so, the option is offered, deduplicated against `candidateWords`'s own.
The pending-value case uses the same probe, so a typed Optional-kind
option still completes its values after a positional. Only the frontier's
own level is probed, so a parent's options aren't offered past a
subcommand (#171). An empty frontier probes nothing: words the parser
already rejects stay rejected whatever is appended. Not covered: an
option given before its place in the line, such as `-v` after `a` under
`<x> <y> [-v]`, since `a -v` has no live branch until `<y>` is typed
(#197).

### Candidates and shell adapters

Each candidate is a `CompletionCandidate = tuple[value, help: string]`
(`completer.nim`, the same type an `Offer`'s values hold), not a bare
string — see `docs/adr/0022-completion-candidate-help-text.md`.
`help` is populated for an Arg's own name (option/flag/command candidates,
via `completion.describeVariants`), and for a value only when a Completer's
`offer` gave it one; an enumerated value from `completions()` always
carries `help == ""`, since there's no per-value description in the data
model to draw from. `describeVariants`
reads a variant the way help's row does: the Arg's short `.help`, then its
Flag Operation Description from `Arg.variantDesc(variant)` (`backend.nim`)
as `[action: ...]` when that is non-empty (e.g. a flag's `-i`/`-d`
incrementing/decrementing differently). With no short help the description
stands alone, and the long help never appears (ADR 0063). Each part goes
through `prose.summary`: its first paragraph, dedented by the same
`dedentLines` help's re-flow uses, joined onto one line, and passed
through `plainMarkup`. `reply*` runs it again on every description, a
Completer's included, so a candidate is always exactly one line. It's a
withheld export of `prose.nim` (not re-exported by `help.nim`), which
`completion.nim` imports without importing `help`.

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
0022 for why. `parseOrQuit*` prints every `MessageError` — `CompletionError`
included — with `echo` rather than `quit(e.msg, QuitSuccess)`: `quit`'s
non-nimscript/js implementation writes to stderr, not stdout, which a shell
adapter's `$(...)` capture can't see (ADR 0050).

Each adapter forwards only the words before the cursor, plus the one being
completed, and hands `__complete` an option and its value as separate
words. fish and zsh keep `--opt=value` as one word, so their scripts split
it by hand; zsh's moves `--opt=` into `IPREFIX` with `compset -P`, so only
the value is replaced. bash splits it itself, on `COMP_WORDBREAKS`, into
`--opt`, `=` and `value`, so its script drops a `=` or `:` word that
follows an option, and completes a bare separator as an empty value, since
readline replaces only the text after it. zsh's `compadd -d` shows each
display string in place of its word, so the script writes
`word  -- help` there, or the bare word (#198).

### Path Completion

Besides its candidates, `resolveCompletion*` returns which paths the shell
should add (`PathCompletion`, `completer.nim`), and `reply*` prints that as
the last line of `__complete`'s output: `:files`, `:dirs`, or `:` for none
(the private `completion.directive`). Every position that takes a value
contributes the paths of its Arg's `Offer` — each non-hidden `mkArgument`
transition out of a frontier state, or each pending option in the
pending-value case.
By default that is `Files`, or `None` if the Arg has enumerable
`completions()`, which a `choice` accepts alone. `widen` ranks `Files`
above `Dirs`, then `None`. Each script strips the last line
unconditionally and adds file names (bash `compgen -f` with
`compopt -o filenames`, fish `__fish_complete_path`, zsh `_files`) or
directories (`compgen -d`, `__fish_complete_directories`, `_files -/`). See
`docs/adr/0066-completion-falls-back-to-paths.md`.

An `Offer` with `Files` may also carry file patterns (`files`, or
`offer`'s `patterns`), which `Completion.patterns` collects and
`directive` appends to `:files`, each after a tab. `widen` ranks
unfiltered `Files` above filtered, and joins two filters' patterns in the
order first seen. Each script then keeps directories, and files whose name
matches a pattern: bash tests `compgen -f`'s output with `[[ == ]]`; zsh
calls `_path_files -g` and `_path_files -/`, since `_files -g` offers every
file when none matches, and writes a space in a pattern as `[[:blank:]]`;
fish turns each glob into a regex, since `string match` has no `[...]`,
and filters `__fish_complete_path`. See
`docs/adr/0072-file-completion-patterns.md`. The bash script stays
runnable on bash 3.2, macOS's `/bin/bash`: no `mapfile`, no `case` inside a
process substitution, and `compopt` only where it exists, so 3.2 completes
paths without escaping them.

### Completers

`completion.offerFor` answers "what does this Arg's value offer this Tab"
with an `Offer`: candidate values, each with an optional
description, a `PathCompletion`, and any file patterns. `Completer`
(`completer.nim`) is a
case object: the default gives the Arg's `completions()`, or files if it
has none; a fixed one, which a `PathCompletion` converts to, gives the
same `Offer` every Tab; and a proc one runs with `CompletionContext.word`
set to the word being completed. A `CatchableError` from the proc is an
empty `Offer` with no paths. `offer`, `files`, `toCompleter` and `$` live in
`argumint.nim`, built on withheld `initOffer`/`initCompleter`.
A `Tab` object caches each Arg's `Offer` for the request, so a Completer
reached from several frontier branches, or from both the candidate and
the path loops, runs once. Values are prefix-filtered by `addUnseen` like
any other candidate, and `reply*` puts descriptions through
`prose.summary`. See
`docs/adr/0071-runtime-completers.md`.

A proc Completer (`Completer.fills`) is first given the earlier values,
through `Tab.fill`. The walk never converts a value: `matches` holds raw
strings. So `fill` calls the branch's `pc.storeValues`, the same
store step `parse` runs: the matches in `Match.idx` order at `byCli`, then
`applyFallbacks` with the branch's own `pc.tiers` over every level in
`pc.levels`, root-first, as `initParseContext` seeds it on both paths.
Reusing the walk's tiers keeps `parse`'s limit on how many values a tier
supplies to an Arg the branch walked, and resolves no source twice (#260).
A value that fails is skipped and the rest still store, as in `parse`, but
`fill` drops the returned `Report` where `parse` raises it. A command-line
value that fails still closes the fallback tiers to its Arg (ADR 0077).
`dispatch` never runs, so no hook does. The walk's own probes still read
env vars and Config Sources, to judge whether an option is satisfied, but
only the fill writes.

The fill runs once per Tab, from the first branch that needs it, and clears
nothing. Filling per branch would have run each Completer once per live
branch (twice for an optional `-h`), and clearing between branches would
have destroyed pre-seeded values (ADR 0041). `collectFrontier` tries
transitions in `walk`'s order, so an ambiguous `(<user> | <org>) <repo>`
binds `acme` to `user`, as `parse` does. A fixed Completer fills nothing,
so a CLI using only `PathCompletion`s sees no writes.
