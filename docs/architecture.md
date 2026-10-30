# Architecture

How argumint works inside, phase by phase and module by module. It assumes
the vocabulary in `GLOSSARY.md` (Spec, Arg, Variant, Usage Line, Value
Precedence, Reach, ...). Each design decision has an ADR in `docs/adr/`,
which this file points to rather than repeating. Nim compiler traps are in
`docs/gotchas.md`.

## Overview

A program declares its interface as a tuple of Args and hands it to
`newSpec` or `parse*`. From there:

```
spec tuple
  │ newSpec (specbuild)
  │   register each Arg in the Spec's tables
  │   compile the usage string into an FSM (lexer → parser → fsmgraph)
  │   auto-fill usage for anything unreachable
  ▼
Spec ──── parse (fsm) ──────────────────────────────────────────────
  │   `__complete` request?  → resolveCompletion, raise CompletionError
  │   walk          backtrack the FSM over the tokens; a failure is a Report
  │   storeValues   CLI matches, then env and Config Source fallbacks
  │   dispatch      before / Message Args / action / after, root to leaf
  ▼
values read with get / toT / toSeqT
```

Every user-input failure becomes a `ParseError` raised from one `Report`.
`parseOrQuit*` turns it, or a message such as `--help`, into printed text
and an exit code.

## Module layout

### Layers

Only public import paths sit at the top of `src/`:

- `argumint.nim`: the facade. Every public name a CLI needs.
- `argumint/help.nim`: `genHelp` and the Help Formatter API (opt-in, ADR
  0042).
- `argumint/customarg.nim`: what only a Custom Arg needs (ADR 0076).
- `argumint/configsource.nim`, with the `configsource/ini` and
  `configsource/json` adapters.

Every withheld module lives in a subdirectory for its layer:

| Layer      | Modules                                                      | Job                                    |
|------------|--------------------------------------------------------------|----------------------------------------|
| `text/`    | `style`, `console`, `prose`, `suggest`                       | Styled text, terminal detection, wrapping, suggestions |
| `core/`    | `errors`, `variant`, `completer`, `envvar`, `settings`, `backend`, `outcome` | The data model and what it points at |
| `grammar/` | `lexer`, `parser`, `usage`, `fsmgraph`, `specbuild`, `dot`   | Spec tuple and usage string to FSM     |
| `values/`  | `argtypes`, `validators`, `flagclamp`, `display`             | Converting, validating, storing values |
| `walk/`    | `tokens`, `matching`, `complaints`, `precedence`, `completion`, `fsm` | Matching a command line against the FSM |

The layers stack `text` → `core` → `grammar` and `values` → `walk`. A module
imports only from its own layer, a lower one, or `configsource`; `grammar`
and `values` never import each other. Tests inside `when isMainModule` may
reach further.

The leaves, with no local imports, are `errors`, `variant`, `completer`,
`envvar`, `style`, `display` and `configsource`. `backend` sits in the
middle of the graph; `fsm` is the highest module below the facade.

### The facade/machinery seam

`argumint.nim` holds every public name and its documentation. Code that
touches a private field lives beside the type it touches, in a withheld
module, and the facade delegates to it (ADR 0043). The split is forced:
`std/importutils.privateAccess` does not survive generic or template
instantiation in another module, and the facade's constructors are generic
(`docs/gotchas.md`).

So:

- `Spec`'s fields are private (ADR 0030). `backend` gives read-only
  accessors (`args`, `arguments`, `options`, `commands`, `groups`,
  `usage`, `fsm`, `prolog`, `epilog`). Only `specbuild` writes them, under
  `privateAccess(Spec)` in non-generic code: generic `newSpec` calls the
  non-generic bookends `beginSpec` and `finishSpec` around the generic
  `addArgs`.
- `Arg.kind`, `variants` and `seenBy`, and `CommandArg.spec`, are private
  too, since the Spec is built from them. Each has a public getter. The
  library writes them through withheld `backend` procs (`initBase`,
  `setSeenBy`, `setSpec`), which work wherever a template expands them. A
  Custom Arg calls `customarg.initArg`, which calls `initBase` once.
- `ValueArg`/`ValuesArg`/`FlagArg` state is private to `argtypes`, which
  exports the constructors (`initValueArg`, `initValuesArg`,
  `initFlagArg`) and readers (`rawValue`, `rawDefault`) the facade wraps.
  `tests/api/test_argumint.nim` checks that the state isn't reachable from
  `import argumint`; the facade's by-name exports keep the rest out.
- The facade carries `{.experimental: "openSym".}`, as do `argtypes` and
  `validators`.
  Generic code instantiated in the user's module resolves unqualified
  calls there, so the facade re-exports what that code calls (ADR 0017).

### Leaves and small modules

- `errors`: every exception (`SpecDefect`, `ParseError` and its subtypes
  `UsageError`/`ConversionError`/`ValidationError`, `MessageError` and its
  subtypes `HelpError`/`CompletionError`). A leaf, so any module can name
  one without importing whatever raises it. `lexer` re-exports
  `SpecDefect` and `validators` re-exports `ValidationError`, so each
  module alone names what it raises. `newPlainError` (withheld) builds one
  whose `styledMsg` is its `msg`.
- `variant`: the Variant grammar as PEG fragments (`ShortName`, `LongName`,
  `Angled`, ...). The lexer, the runtime token shapes in `tokens` and
  `parseVariant` all build from these, so they can't disagree. Each caller
  of `parseVariant` raises its own `SpecDefect`.
- `completer`: the Completer model (`Completer`, `Offer`,
  `CompletionCandidate`, `PathCompletion`, `CompletionContext`). Below
  `backend` because `Arg.complete` is one.
- `envvar`: `EnvSource`, the env split rule (`splitEnvValue`) and
  `lookupEnv`. Named so because `envsource` collides (`docs/gotchas.md`).
- `configsource`: `ConfigSource` (subclass it and override `lookup`),
  `ConfigKey`, and `lookupConfigSources`, which returns the last source's
  hit in full.
- `settings`: `SpecSettings` and `newSpecSettings`, with the compile-time
  defaults (ADR 0053). Its `width` and `style` getters detect on first read
  through `console` (ADR 0058). It is the only part of the data model that
  imports `console`.
- `outcome`: what `parseOrQuit*`, `parsedOrQuit*` and `dot*(tuple)` print
  for a caught exception, as data: text, stream, exit code. Messages go to
  stdout with `QuitSuccess` (ADR 0050); failures go to stderr, labelled,
  with `QuitFailure`. The facade's `quitWith` prints it.
- `display`: how a value appears in help and errors (a string or char
  quoted, anything else `$`).
- `dot`: renders an FSM as Graphviz dot, through the facade's `dot*`.
  `scripts/dot2png.sh` turns that into a PNG.

## Data model (`core/backend.nim`)

**Spec** holds the usage string, prolog and epilog; `args` in declaration
order; four lookup tables (`arguments`, `options` and `commands`, keyed by
bare Variant name, and `groups`, keyed by Help Group); the FSM's root
`State`; a shared `SpecSettings`; and the `before`/`action`/`after` hooks.
Only `settings` and the hooks are public fields.

**Arg** is a `ref object` with a `kind` (`ArgKind`: `Command`,
`Positional`, `Optional`, `Flag`), its Variants, help text (a `HelpText`
short/long pair, ADR 0049), Help Group, `hidden`, a `Completer`, and
`seenBy`. `ArgKind` classifies by token shape (does a value follow?), not
by domain role, so a Message Argument may be of any kind. `hash` uses the
first Variant; `==` is identity.

`Arg`'s `{.base.}` methods are the contract every kind fills in:

| Method                                  | Used by                                   |
|-----------------------------------------|-------------------------------------------|
| `accept`, `clear`                       | the write side                            |
| `accumulates`                           | fallback counts, auto-filled `...`        |
| `envSource`, `configKey`                | the fallback tiers                        |
| `isMessage`, `action`                   | dispatch                                  |
| `defaultStr`, `validatorHelp`, `clampHelp`, `variantDesc` | help                    |
| `completions`, `aliases`                | completion, FlagOp Aliases                |

The subtypes are `CommandArg` (holds its nested Spec), `MessageArg` (raises
`MessageError` with fixed text), `HelpArg` (`help.nim`), the value Args in
`argtypes`, and the facade's private `ShellArg` (`completion()`'s
`<shell>`).

**SeenBy** (`byNone < byConfig < byEnv < byCli`) is Value Precedence as an
ordered enum. Comparing members is part of the public contract (ADR 0039).

**The FSM** is `State` (`terminal`, `transitions`) and `Transition`
(`matcher`, `next`). A `Matcher` is a `ref` case object, one kind per token
type, declared in priority order: `mkOption`, `mkOptions` (the Options
Catch-all), `mkCommand`, `mkArgument`, `mkOptsEnd`, `mkShortcut`.

**Level** (`GLOSSARY.md`) is `(spec, command)`: one entered Spec and the
command path that names it (`"app go"`). **HookInfo** carries `matched` (every
Arg matched anywhere), `root` and `here` (two Levels).

**SpecSettings** is a `ref`, shared by every Spec in a tree:
`width`, `maxVariantsWidth`, `envDelim`, `configSources`, `strictOptions`,
`style` and `theme`.

## Spec construction (`grammar/specbuild.nim`)

`newSpec` runs three steps:

1. **`beginSpec`** creates an empty Spec.
2. **`addArgs`** gathers every Arg from the tuple with the public
   `eachArg` macro, so registration and `eachArg` agree (ADR 0087): it
   goes into nested tuples, takes an Arg reached twice once, and makes any
   other member a compile error. `registerArgs` sizes each
   table for its keys first (`docs/gotchas.md`, table default capacity),
   then `addArg` checks each Variant with `parseVariant`, files the Arg
   into its table, and fills an empty `group` with its kind's
   `defaultGroup`. A duplicate name is a `SpecDefect`.
3. **`finishSpec`** compiles the FSM (`genFsm`), auto-fills usage
   (`autoFillUsage`), and shares the settings down the tree
   (`cascadeSpecSettings`).

Construction sits in `grammar/`, above `parser` and `fsmgraph`, rather
than beside the data model in `backend`: building a Spec means compiling
its usage string, and both of those import `backend`, so putting it there
would be an import cycle. What never touches a usage string stays lower:
`newSpecSettings` in `settings`, and `subject`, which both the value Args
and failure reporting use, in `backend`.

`command*` builds its nested Spec with `newSpec` when it is called, so a
tree is built leaf first, and binds its hooks onto that nested Spec. The
root's `newSpec` then cascades one `SpecSettings` into every level. A
change to it, even from a `before` hook, is seen everywhere not yet
dispatched (ADR 0014), except by the fallback tiers, which have already
run by then.

The tuple entry points in the facade (`parse*`, `parseOrQuit*`, `parsed*`,
`parsedOrQuit*`) share `buildAndBind`, which binds the root's hooks to the
same tuple the caller gets back. A Spec is single-use, since Args keep
what they were given; `parsed*` takes a builder proc and builds a fresh
tuple per parse (ADR 0031).

### Auto-filled usage

`autoFillUsage` finds every Arg the FSM references
(`fsmgraph.referencedArgs`) and appends Usage Lines for the rest, whether
or not a usage string was given. A Command named in the usage string counts
as referenced, but the Args inside its own Spec don't: the walk stops at
the Command instead of following the parser's splice into its FSM, so an
Arg shared with that Command (as `specTuple(global)` gives every Level)
still gets its line here (#349).

- **Commands** not reachable go on one `(a | b)` line.
- **Positional Arguments** are appended as one line in declaration order,
  only if none is reachable; a partly written sequence is left alone. An
  accumulating one is written `<a>...`. More than one accumulating
  Positional Argument is a `SpecDefect`, since how values split is the
  author's choice.
- **Options**: `[options]` prefixes whichever line was appended above, or
  gets its own line if none was. Message Arguments don't count.
- **A Bare Call** (`{cmd}`, ADR 0061) is added when the usage is still
  empty and a Message Argument is about to get its line, so a Spec with
  only `help()` can still run its action.
- **Message Arguments** each get their own line, last.

The new lines go through the same `addUsageLines` as the first build,
spliced onto the existing root, and the graph is prepared again.

## Usage-string compilation (`grammar/`)

### Usage Lines

`usage.splitUsage` is the one rule for what a Usage Line is, shared by the
parser and help: a blank line is dropped, an indented line continues the one
before (even across a blank line, #137), and a leading `{cmd}` is stripped
(anywhere else it is a `SpecDefect`). A line left empty is a Bare Call.

One Usage Line may mix positional args, options and commands in any
combination: the line alone decides what is valid at each position, and
nothing in the types or the graph limits it (`<name> [-v] doit`, with `doit`
a command, works). Keeping positional args and commands at separate
Spec levels, as Naval Fate does, is convention only.

### Lexing and parsing

`lexer.SpecLexer` tokenizes a line using the `variant` fragments. The
parser is recursive descent: `sequence` → `choice` → `atom`. Each atom
returns a start and end State, and `sequence` joins them by copying
transitions. `addUsageLines` parses each line, splices it onto the root
with a Shortcut, and marks its end terminal.

What each atom builds:

| Syntax           | Builds                                                    |
|------------------|-----------------------------------------------------------|
| `<arg>`, `ARG`   | one `mkArgument`                                          |
| `-o`, `--opt`    | one `mkOption`, remembering the Variant as written        |
| `-abc`           | one `mkOption` per letter, in sequence (ADR 0025)         |
| `[options]`      | one `mkOptions`, the Options Catch-all (ADR 0002)         |
| `cmd`            | one `mkCommand` into the nested Spec's FSM                |
| `--`             | one `mkOptsEnd`, the End-of-Options Marker (ADR 0020)     |
| `[...]`, `...`   | a Shortcut skipping the group, or looping back            |
| `a \| b`         | Shortcuts into each branch, then out to a shared end      |

`choice` drops an alternative that repeats an earlier one's Arg and
FlagOp Alias, so `(-v | --verbose)` doesn't build two paths for one Flag.

A **Command** atom adds a `mkCommand` transition to the nested Spec's own
root, and Shortcuts from that Spec's terminal States to the atom's end.
Nothing may follow a Command on its line (ADR 0010), and only Positional
Arguments may follow an End-of-Options Marker; breaking either rule is a
`SpecDefect`, as is repeating either with `...`.

**The Options Catch-all** must exclude the Options and Flags its own line
names explicitly, but a later atom on the line may name one. So the atom's
`Matcher` is built unfiltered and recorded in `pendingOptions`; when the line
is done, `excludeOptions` removes everything in `explicitOptions`. This works
because `Matcher` is a `ref`: `sequence` copies transitions, but they all
share the one Matcher.

### Preparing the graph (`grammar/fsmgraph.nim`)

`prepare` runs after every build:

- **`simplify`** removes every Shortcut. Each State takes the non-Shortcut
  transitions of its Shortcut closure, and is terminal if anything in the
  closure is. The closure is a visited set, so Shortcut cycles terminate
  (`docs/gotchas.md`). After this, an optional `[X]` survives only as a
  terminal flag on the State before it.
- **`sortTransitions`** orders each State's transitions by Matcher kind, so
  an Option gets a token before a Positional Argument does.

`addUsageLines` recomputes the root's `terminal` flag after splicing, so
an empty usage or a fully optional first line keeps the root accepting
(`docs/gotchas.md`, "terminal flag").

## The walk (`walk/fsm.nim`, `walk/matching.nim`, `walk/tokens.nim`)

### Tokens

`tokens.initCursor` splits argv into `RawToken`s by shape alone, with no
Spec: the raw text, whether it is option-shaped, and its argv index `idx`.
What a token *is* depends on which Spec governs its position, which is
known only once the walk gets there (ADR 0019). A `TokenCursor` holds the
remaining tokens, that Spec, and whether a literal `--` (or an
End-of-Options Marker) has been crossed.

`classify(cursor, pos)` answers against `cursor.spec`'s tables. The result
is an `ArgKind`: `Command`, `Optional` (an Option, with its value:
attached, folded into a Short-Option Cluster, or the next token), `Flag`,
or `Positional`. For a Short-Option Cluster `-abc`, only `-a` resolves;
`consume` puts `-bc` back as a new token with the same `idx`, a higher
`subIdx`, and the typed original in `cluster`. `classify` never raises. A
declared Option with no usable value comes back as `Positional` with
`starvedOpt` set: a starved Option.

**Strict Option Checking** (`strictOptions`, on by default, ADR 0034)
refuses an option-shaped token that resolves to nothing, in both a
Positional Argument's slot (`refusesAsPositional`) and an Option's value
slot. A Non-Option Short (`-5`, `-0x1F`) typed by the user is exempt, and
so is anything after a literal `--`. `classify` returns a plain
`Positional` past `--`, which looks just like an unknown option's, so
`refusesAsPositional` reads `cursor.optsEnd` itself. A refused token stays
unconsumed, to be named as the error.

### Matching (`matching.match`)

`ParseContext` is the live walk state: the cursor, the command path, the
`levels` entered, the `matches` so far (`Arg` → `seq[Match]`, each Match
recording its Variant, raw value, Spec and argv `idx`), the `Report`, and
the fallback `Tiers`. `match` applies one Matcher to it:

- **`mkCommand`** looks only at the first token. On a match it switches
  `cursor.spec` to the nested Spec, extends `command`, and appends a
  Level.
- **`mkOption`** scans forward for a token that classifies as its own
  Arg, so Options and Flags can be given in any order. A Flag also has to
  be a FlagOp Alias of the Variant the line names, unless the Options
  Catch-all reached it. The scan stops at a token that is one of this
  level's Commands, unless that token is an Option's separate value
  (`tokens.isSeparateValue`); anything typed after a Command word belongs
  to that Command's own Spec (ADR 0010). If no token matches, the fallback
  tiers may stand in (see "Value Precedence fallbacks").

  The scan steps one token at a time, never over a whole Option and its
  value (`c.consumed`) the way `mkArgument` does. Strict Option Checking
  depends on this: a declared `-1` has to be able to claim the token that
  another Option would otherwise take as its value, which starves that
  Option (ADR 0034, #171).
- **`mkOptions`** tries a `mkOption` for each candidate, rolling back any
  failed attempt's complaints (`Report.mark`/`rollback`).
- **`mkArgument`** scans past Option and Flag tokens (and their separate
  values) and takes the first token that is plain text or a Command
  word. It doesn't skip a Command word to look further, which would take
  a repeated `<file>...` out of typed order.
- **`mkOptsEnd`** marks the cursor past the end of options, consuming a
  literal `--` if present.
- **`mkShortcut`** never survives `prepare`.

A literal `--` anywhere on the command line is dropped the first time a
scan reaches it on a path; after it, every token is a Positional
Argument's value.

### Backtracking (`fsm.walk`)

`walk` tries each transition of a State in order on a copy of the context
(`var fresh = pc`) and recurses into the next State on a match. The first
path to reach a terminal State with no tokens left wins, and its copy
replaces `pc`. `ParseContext` and `TokenCursor` are plain value objects, so
a failed attempt's classifications, matches and Levels are discarded with
its copy. This is why lazy classification needs no cache, and why a word
that is a Command at one position can be a plain value at another.

Shell completion drives the same `match` from its own walk
(`collectFrontier`), which is why `match` and `ParseContext` sit in
`matching.nim`, below both.

## Failure reporting (`walk/complaints.nim`)

### The Report

A `Report` holds two channels and the Level they render against:

- **complaints**, each a kind, a styled subject, and whether it names a
  token the user typed. Recorded by verbs: `missingArgument`,
  `missingCommand`, `missingOption`, `unexpected`, `starved`, `note`,
  `store`.
- **leftovers**: the cursor where a branch stopped, to be worded later.
  Recorded at `walk`'s tail (a terminal State whose every transition
  failed), by a failed `mkCommand`, and by a failed `mkOption` holding an
  unresolved option-shaped token.

Nothing is worded during the walk. `walk` and `match` touch the Report only
through its verbs.

### Choosing the branch to blame

Each branch's **Reach** is where the first token it could not consume
sits, as `(idx, subIdx)` (ADR 0036). In `walk`, a branch that reaches
further replaces `pc.report`; one that ties merges into it, so same-kind
complaints from sibling lines group onto one line. A transition's Reach is
the greater of its own and its descendants'. `maxReach` never goes down,
even when a lesser branch's complaints are adopted because nothing had
complained yet.

The leftover `walk`'s tail records at a terminal State is ranked the same
way. Its Reach is the State's own first token, so it is recorded only when
no transition got further. Otherwise a Command that matched and then failed
deeper in its own Spec would have the Command word itself blamed beside the
real complaint (#309).

When a transition matches, `Report.clear` empties the Report and points it
at the live Level, so a failure carried up from a deeper level keeps that
level's usage block (#192). `cursor.spec` itself is never written by a
failed branch.

### Suppression

- `mkArgument` reports nothing missing when its State was terminal (the
  grammar could have stopped there), passed down as `atTerminal` (ADR
  0037).
- `mkCommand` at a terminal State still records `missing command`, since
  wording the leftover needs it, but marks it not `owed`, so it is never
  shown. A merge keeps it owed if either copy was (ADR 0081).
- `mkOptions` never complains: anything the Options Catch-all reaches is
  optional.
- A starved Option is always reported, even beside other complaints.
- When Reach-tied branches merge, a Message Argument's "missing option"
  is dropped if any other complaint is there (ADR 0036).

### Wording and raising

`finalComplaints` builds the message. If no complaint names a typed token
yet, it words each leftover by classifying it again (an `unrecognized
command` where a Command was expected, an `unrecognized option`, an
`unexpected ...`). Once some complaint names a token, it drops every
`missing option` and every `missing command` that was not `owed`, and the
rest of `missing command` too if the named token sat where a Command was
expected. With nothing named and no leftovers, every complaint stays.

- **Did-You-Mean Suggestions**: `didYouMean` (`text/suggest`, below
  `values` so a Flag's `accept` can share it) suggests Options and Commands
  within an edit distance (optimal string alignment over runes,
  `osaDistance`) scaled to the candidate's length. It never suggests a
  short option. `unknownCommand` first drops every Command whose subtree
  doesn't declare an option typed after the mistyped word, read from the
  Report's tokenized command line (`argv`), since the leftover may have
  lost options the walk consumed (ADR 0036's last addendum).
- **Short-Option Clusters**: an unknown one is named by its first two
  characters, with the typed token added (`-x (in -1x)`, ADR 0038).
- **Styling**: subjects are `StyledText` with roles set where they are
  built, never by Help Markup, since they may hold typed input (ADR 0056).
  Two complaints are the same if their plain text is (`dedupKey`), so
  dedup and grouping never depend on a role.

`failureMessage` adds the usage block for the Report's Level.
`raiseFailure` raises it with a plain `msg` and a `styledMsg` rendered by
the Spec's styler (ADR 0059). Each complaint records which `ParseError`
subtype it is a case of. A walk's complaints are all `UsageError`, while
`store` records the type it caught. The raise uses the subtype they share,
or `ParseError` when they differ (ADR 0078).

## Storing values

`parse` calls `storeValues` (`matching.nim`) once the walk succeeds. It
writes every match in the tree at `byCli`, sorted by argv `idx` so Flag
Operations apply in typed order, then runs `applyFallbacks` over every
Level entered. It doesn't stop at the first failure: each value goes
through `Report.store`, which catches a `ParseError` into the Report, and
`parse` raises the whole Report before any hook runs (ADR 0032, ADR
0077). An Arg whose command-line value failed is closed to the fallback
tiers.

Commands and Message Arguments are stored too, through the base `accept`,
which records `byCli` and nothing else, so provenance is complete before
the first hook.

### The write side (`core/backend.nim`)

`Arg.parse(value, variant, seenBy)` is the only way a value gets in, from
the library or from application code (ADR 0041). It is a plain proc, so no
subtype can skip the tier rule, which is `arbitrated`:

- a weaker tier than the one recorded is refused, so a write never
  demotes;
- the same tier (or none given) extends: `arExtend`;
- a stronger tier replaces: `arReplace`, and the new tier is recorded once
  the store returns.

`parse` hands a `Contribution` (raw value, typed Variant, tier) to
`accept` with that decision. An override validates first and only then
clears on `arReplace` and stores, so one that raises leaves the Arg as it
was (ADR 0062). `subject(arg, c)` names the Arg in an error, adding the
source for a fallback tier (`--port (env: PORT)`).

`clear` resets provenance and value together. The typed writers `put` and
`replace` (ADR 0044, 0045) go through `arbitrated` too, but reach the
storage directly, so a Custom Arg can only be written through `parse`.

### Value Precedence fallbacks (`walk/precedence.nim`)

The env tier and the Config Source tier share one mechanism. `Tiers` holds
one `ValueCursor` per tier, indexed by `FallbackTier`
(`byConfig..byEnv`), and they are consulted in `FallbackOrder`, strongest
first. Each tier finds its values through its own leaf: `lookupEnv`
splits the variable on the Arg's own delimiter or `settings.envDelim`
(ADR 0015); `lookupConfigSources` returns a `seq` already.

**During the walk**, when an `mkOption` finds no token, `Tiers.probe` asks
each tier for the Arg. A tier resolves an Arg at most once per parse
(cached in `tried`, misses included, since a `ConfigSource.lookup` may be
expensive) and hands out one value per visit, counting them in
`consumed`. So a fallback satisfies exactly as many positions as the walk
visits: a `...` loop keeps taking values, and an Option named twice takes
two. The Options Catch-all repeats without limit, so it marks the Arg
`covered` instead of taking one value at a time (#188). The walk only
counts; nothing is written yet.

**After the walk**, `applyFallbacks` visits every Arg declared at each
Level entered. It skips an Arg already supplied by a stronger tier
(`seenBy > SeenBy(t)`) and asks each remaining tier in order, stopping at
the first that has anything (`applyTier`):

- If the walk consumed values from the tier, or covered the Arg, it
  applies them all. More values than the walk had room for is an
  `unexpected option`/`unexpected flag` complaint, not a truncation.
- If the walk never visited the Arg (it sits on another, unmatched Usage
  Line), it resolves now and applies everything.
- An Arg that doesn't accumulate takes at most one value from a tier
  (#189).
- `applied` stops an Arg declared at two Levels from being applied twice.

An Arg already at the tier's own level is extended, not skipped, so a
pre-seeded `byEnv` value still collects the variable's values. Running
after the walk is also what gives an Option reachable only through the
Options Catch-all its fallback. A Flag's fallback value names the Variant
whose Flag Operation applies. See ADR 0004, 0005 and 0018.

One consequence of gating per Arg: if an Arg matched a real token at one
position and a fallback filled another during the walk, the fallback's
share is dropped, since the Arg is already at `byCli` (ADR 0018,
"Consequences").

## Value Args and Flags (`values/argtypes.nim`)

### Two classes per kind

Generic methods don't dispatch, so each value-carrying kind is an untyped
base with ordinary methods, and a typed leaf that has no methods (ADR
0068):

```
Arg
├── ValueArgBase        env, configKey, multi; hooks
│   ├── ValueArg[T]     arg*/opt*:   Option[T],      default T,      Validator[T]
│   └── ValuesArg[T]    args*/opts*: Option[seq[T]], default seq[T], Validator[T]
└── FlagArgBase         env, configKey, bound ops; hooks
    └── FlagArg[T]      flag*:       T,              default T,      FlagClamp[T], Validator[T]
```

The base's methods that need `T` call **hooks**: `{.nimcall.}` procs the
leaf's constructor instantiates for its own type and stores on the base.
`ValueArgBase` has three: `write` (convert, validate, store), `reset`
(back to `none`), and `describe` (`defaultStr`, `validatorHelp` and
`completions` together, computed on demand). `FlagArgBase` has `reset`
(restore the default), `describe` (the clamp's and `validator`'s help), and
`assign` (convert, validate and assign a value no op names; nil without a
`validator`). A new base method
needs a hook only if it touches typed storage; `tests/test_argumint.nim`
fails if a constructor leaves one unset.

`ValueArg` and `ValuesArg` share most code through the `AnyValueArg[T]`
typeclass, and differ in `history` (what a validator sees when extending)
and `store` (set, or append). `Option` storage keeps "not supplied"
(`none`) apart from "supplied empty" (`some(@[])`), and makes the default
apply at read time without ever being stored or validated (ADR 0008).

### Conversion and validation

`acceptImpl` converts with `fromString[T]`, then `storeImpl` validates and
stores. `fromString` calls the built-in conversions by name (`toNumber`,
`toBool`, `toChar`), parses an enum with no converter by name, and
otherwise writes `let x: T = s`, which finds the user's converter where the
generic is instantiated. The built-in conversions are private procs, not
converters, so `import argumint` doesn't make `let n: int = "5"` compile.
`toNumber` range-checks against `T`'s bounds, including range types.

A type that is none of these fails to compile at the constructor, through
the `ValueType` concept, with an error naming the converter to write (ADR
0068, 0069).

Validators (`values/validators.nim`) are `ref` case objects with combinators
(`choice`, `range`, `check`, `unique`, `all`, `any`, `checkSeen`, ADR 0006,
0007). A validator describes itself for help (`styledHelp`) and lists its
values for completion (`completions`). For an enum argumint parses itself,
the enum's own values stand in (`describedBy`).

### Flags

A **Flag Operation** is a closure on the value, `proc (value: var T)`,
carried by a public `FlagOp[T]` with its spellings and description (ADR
0070). It comes from one of three places:

- a named op (`=`, `+=`, `-=`, `*=`) through `namedOp`, with saturating
  arithmetic for numbers and `op=` or `op` for anything else;
- the user's own proc (`flagOp`, `flagOpIt`);
- the type's Implicit Operation for bare Variants (`implicitOp`): toggle a
  bool, step an integer, advance an enum.

`flagOp` rejects an op `T` can't do at compile time (`opError`), and the
string form of `ops` (`parseFlagOpsString`, ADR 0028) raises the same
message as a `SpecDefect`.

`initFlagArg` builds the whole flag in one call: it binds each op to the
flag (`bindOp`, which runs the op and then the clamp), assigns each
`FlagOp` its own alias group (ADR 0027), and rejects a duplicate Variant or a
default its own clamp would change. It also lists, in `valueOps`, each op that
sets one value an env or config value can name: an `=` op, and a `bool`'s
Implicit Operation, with one more entry that resets a `bool` to its default (ADR
0085). `accept` looks up the contributed Variant, then that value, and runs its
op. Failing both, a flag with a `validator` calls `assign`, which converts like
`acceptImpl` (the shared `converted`), then validates, assigns and clamps (ADR
0086). `initFlagArg` checks each `=` op's value against that `validator` up
front, so neither lookup needs it. `aliases` compares groups. `variantDesc`
returns an op's description only when the flag's descriptions differ (ADR 0063).

A `FlagClamp[T]` (`values/flagclamp.nim`, ADR 0016) is `clamp(slice)` or
`adjust(proc)`, applied silently after every Flag Operation. It is
separate from `Validator` because it corrects rather than rejects.

### Reading values

The facade's `get`, `toT` and `toSeqT` read through `rawValue` and
`rawDefault` (ADR 0040, 0044). A `ValueArg` or `ValuesArg` returns what is
stored if anything is, else the coded default. `get(otherwise)` is a
template, so `otherwise` is evaluated only when needed. A `FlagArg`'s `get`
returns its value, which starts at the default; its `get(otherwise)`
returns `otherwise` unless the flag was seen or its value differs from the
default.

## Dispatch (`walk/fsm.nim`)

`parse` builds one `HookInfo` (`matched` from the match table, `root` from
`levels[0]`) and calls `dispatch` on the recorded Levels. At each Level, on
a copy of the `HookInfo` with `here` set to that Level:

```
before(info)
try:
  fire this level's matched Message Arguments
  if last level: action(info)  else: dispatch(next level)
finally:
  after(info)
```

So `before` runs root to leaf, `action` once at the leaf, and `after` leaf
to root, including when something deeper raises (ADR 0009). Every value
in the tree is already stored, so a hook at any depth sees all of them.

`parseMessageArgs` fires `action` for each Arg whose `isMessage` is true
and whose Match was recorded under this Level's Spec, so a `help()` shared
by two levels fires at the one it was typed at. It runs after `before`, so
a `before` hook can change settings the message renders with (ADR 0013).
`action` raises: `MessageArg` raises `MessageError` with its text,
`HelpArg` raises `HelpError` with the level's help, and `ShellArg` raises
`MessageError` with the completion script for `info.root`. One
signature for all of them is what lets a Custom Arg plug in (ADR 0073).

`info.matched` covers the whole invocation, so `showsMessage(info)` lets an
ancestor's `before` skip expensive setup for `--help` (ADR 0021).

## Help rendering (`help.nim`, `text/`)

### Help Context and Help Frame

`genHelp` builds a `HelpContext` (Spec, command path, width, Styler) and
calls the Help Formatter with it (ADR 0048, 0057). The context hands out
pieces ready to lay out:

- `groups`: Help Groups in display order (ADR 0079), with hidden Args and
  Args a `filter` drops removed (ADR 0082);
- `rows`: one `Row` per set of an Arg's Variants that share a description,
  less the Help Annotations a `filterAnnotations` drops (ADR 0088);
- `prose`, `markup`, `usage`;
- `render`.

Help Markup's backticks are already dropped when there is a Styler, so a
formatter never decides that.

Both built-in formatters are the Help Frame (`frame`, ADR 0075) with a
`RowRenderer`. The frame joins prolog, the usage block, each group's
heading and rows, and epilog with `joinSections`.

- **Column Style** (`formatColumn`) aligns rows into two columns shared by
  every group. The variants column is the widest Row's among the Args
  `groups` shows, capped at `maxVariantsWidth`. A Row starts at the
  2-space `Margin`, a variants continuation at 4 spaces, and every text
  line at the text column.
- **Paragraph Style** (`formatParagraph`) puts the variants on their own
  line and the help text, long form if declared, indented below it.

A Row's text is the Arg's help (or its divergent Flag Operation
Description), followed by an annotation bracket from `annotations`:
a Flag Clamp's help, validator help, default, env var, config key, and
`action:` for a divergent Variant (`[choices: "a", "b"; default: "a"]`).
Each entry is a `HelpAnnotation` with its kind, so `filterAnnotations` can
drop it before `annotate` joins the rest. A Flag's clamp and `env/config
values:` help come from the separate `clampHelp` and `validatorHelp`
methods.

`HelpArg.action` renders twice: plain for `msg`, then styled for
`styledMsg` if the Spec has a Styler (ADR 0059).

### Styled text (`text/style.nim`)

Everything laid out is `StyledText`: a run of `Span`s, each with a
`StyleRole`. The rule for built-ins and custom formatters alike is:

1. build `StyledText`;
2. `wrap` it to a width;
3. pad with `len`/`alignLeft`, which measure graphemes of the plain text;
4. `render` each finished line with a `Styler`.

Measurement happens before rendering, so escape codes never skew widths.
`wrap` runs a corrected fork of `wrapWords` (`docs/gotchas.md`) on the
plain text and maps each byte back to its span. Roles are assigned where
text is built (ADR 0051): `rows` tags Variants by kind, and `usageLines`
tags usage tokens through `lexer.displayTokens`.

Help Markup (`markup`) gives a backticked span a role by its shape alone
(option, placeholder, env var), and keeps the backticks as `srTick` spans
for the Help Context to drop. `plainMarkup` is for text that never meets a
Styler: completion descriptions, `ValidationError` messages, and a
validator's `help()`.

### Prose (`text/prose.nim`)

Prologs, epilogs and Arg help share one re-flow rule (ADR 0054, 0055).
`toProse` dedents the text and joins lines into blocks (paragraphs, list
items, indented lines, blanks), applying Help Markup to each block. The
result is an opaque `Prose`, laid out only through `wrap`. `annotate` adds
the annotation bracket after a space when the text is one block, or as its
own block after a blank line when it is several. `summary` gives
completion a one-line form.

### Terminal (`text/console.nim`)

`settings.width` and `settings.style` resolve on first read (ADR 0058).
Width is `COLUMNS`, else the terminal's, else `DefaultWidth`, capped at
`DefaultMaxWidth` (ADR 0052) and never below `MinWidth`. The style's
`autoStyler` marker becomes `ansiStyler(theme)` or nil by the pure
`wantsColor(env, ttys)` rule: `FORCE_COLOR` or `CLICOLOR_FORCE` forces
colour on, `NO_COLOR` or `TERM=dumb` turns it off, and otherwise it follows
whether stdout and stderr are terminals. Each rule
is a pure function beside a thin probe of the real process, so tests can
drive it. On Windows, `enableVirtualTerminal` turns on ANSI processing.

## Shell completion (`walk/completion.nim`)

### Protocol

A shell's completion script runs `prog __complete <words...>`. `parse`
checks for the marker before anything else, and raises `CompletionError`
holding `reply`'s output, so no fallback or hook runs (ADR 0012). The
output is one `value\thelp` line per candidate (the tab always present,
ADR 0022), then a directive line: `:files`, `:dirs` or `:`, and for
`:files` any patterns, tab-separated (ADR 0066, 0072).

The scripts from `genCompletionScript` know nothing about the Spec. Each
one sends the words before the cursor and the word being completed,
handing `__complete` an option and its value as separate words, and
passes each candidate to the shell. fish and zsh show `help`; bash drops
it. The `completion()` command and `completionScript` both produce these
scripts (ADR 0074).

Each shell splits `--opt=value` its own way:

- **fish and zsh** keep it as one word, so their scripts split it by hand.
  zsh's moves `--opt=` into `IPREFIX` with `compset -P`, so only the value
  is replaced.
- **bash** splits it itself, on `COMP_WORDBREAKS`, into `--opt`, `=` and
  `value`. Its script drops a `=` or `:` word that follows an option, and
  completes a bare separator as an empty value, since readline replaces
  only the text after it.

zsh's `compadd -d` shows each display string in place of its word, so the
script writes `word  -- help` there, or the bare word (#198). The bash
script runs on bash 3.2 (macOS's `/bin/bash`): no `mapfile`, and `compopt`
only where it exists.

### Resolving candidates

`collectFrontier` is `walk` without a winner. It collects every State
still reachable once the typed words are consumed, each with its own
`ParseContext`. It drives `matching.match` unchanged, so the fallback tiers
can satisfy options during completion just as they do in a parse. A
visited set bounds steps that consume no token.

`resolveCompletion` then takes one of two cases:

- **A value is pending**: the last complete word is an Option's bare
  name. It offers that Option's values (`pendingOptionalArgs`).
- **Otherwise**: it offers what can come next. `candidateWords` reads each
  frontier State's transitions: the bare spellings from `spec.options`
  (never the declared `=<metavar>` form), Command names, and each
  Positional Argument's values.

Hidden Args aren't offered, but a hidden Option's values still complete
once its name is typed (ADR 0065).

**Options after a Positional Argument.** Parsing accepts `in.txt -b` for
`[options] <file>`, but the State after `<file>` has no Option or Flag
transitions. So for each Option and Flag of every Level the frontier
reached, `accepts` appends it (with `=x` if it takes a value) and asks
whether the frontier is still non-empty. The same probe covers a pending
value after a Positional Argument. It doesn't cover one typed before its
place on the line (#197).

A candidate's description (`describeVariants`) is the Arg's short help,
plus its Flag Operation Description as `[action: ...]` when that differs
between Variants, reduced to one line by `prose.summary` (ADR 0063).

### Completers and paths

`offerFor` asks the Arg's `Completer` (ADR 0071):

- by default, the Arg's `completions()`, or files if it has none;
- a fixed `Offer` (a `PathCompletion` converts to one);
- a proc, called with the word being completed. One that raises offers
  nothing.

A `Tab` caches each Arg's `Offer` for the request. The paths of every Offer
reached are widened into one directive: unfiltered `Files` beats filtered
`Files`, which beats `Dirs`, which beats `None`.

A proc Completer may read earlier values, so before it runs, `Tab.fill`
calls `storeValues` on the branch's context: the same store `parse` runs,
with the walk's own fallback counts. Failures are dropped, no hook runs,
and it happens once per request, clearing nothing, so pre-seeded values
survive. A fixed Completer fills nothing.

## Extension points

What a program can plug in without touching the library:

| Extension         | How                                                        | ADR       |
|-------------------|------------------------------------------------------------|-----------|
| Value Type        | a converter from `string` in scope where the Arg is built  | 0068      |
| Validator         | `check`/`checkIt`/`checkSeen`, composed with `all`/`any`   | 0006      |
| Flag Operation    | `flagOp(variants, proc)` or `flagOpIt`                     | 0070      |
| Custom Arg        | subtype `Arg`, `initArg`, override `accept` and `clear`    | 0076      |
| Message Argument  | override `isMessage` and `action`                          | 0073      |
| Config Source     | subtype `ConfigSource`, override `lookup`                  | 0018      |
| Help Formatter    | a `HelpFormatter` proc, usually `frame` plus a `RowRenderer` | 0048, 0075 |
| Completer         | a proc returning an `Offer`, or a fixed one                | 0071      |
| Theme / Styler    | `newSpecSettings(theme = ...)` or any `Styler`             | 0051, 0067 |

A Custom Arg joins the fallback tiers by overriding `envSource` and
`configKey`; `envName` is derived from `envSource`, so the two can't
disagree (ADR 0046).
