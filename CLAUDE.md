# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`argumint` is a Nim command-line argument parsing library (Nim >= 2.2.4). Its
distinguishing feature is that a spec is declared as a tuple of `arg`/`opt`/
`flag`/`command`/`help` values, and a **docopt-style usage string** is
compiled into a finite state machine (FSM) that drives actual parsing. This
lets usage patterns express things like optional/repeated/mutually-exclusive
args (`[-r] <src>... <dest>`) declaratively instead of via imperative flag
registration.

## Commands

- Compile/run the Naval Fate demo in `src/argumint.nim` (has a
  `when isMainModule` block with a working example spec):
  ```
  nim c -r src/argumint.nim -- ship move Titanic 1 2
  ```
  Note: `nim c -r file -- args` may pass a spurious leading `--` through to
  the compiled binary depending on Nim version -- if a run fails with
  unexpected "missing option"/"unexpected arg" errors, compile first (`nim c
  file`) then run the binary directly with the same args to rule this out.
- Run the full test suite with `nimble test`, which compiles and runs
  `src/argumint/validators.nim`'s embedded `std/unittest` block plus every
  `tests/test_*.nim` file (each is its own standalone `std/unittest` suite;
  `tests/config.nims` adds `src` to the path for anything placed there). Add
  new tests as new `tests/test_*.nim` files -- no per-file wiring needed
  beyond that naming convention.
- Dependencies are managed via Atlas (`atlas.workspace`, `deps/atlas.config`),
  not classic nimble/nimble.lock.
- `config.nims` sets `-d:nimPreviewHashRef` globally — required for the code
  to compile under Nim 2.2's ref-hashing preview.

## Architecture

Parsing happens in two distinct phases, and understanding the split is key to
navigating the code:

1. **Spec construction** (`src/argumint.nim`): user calls `arg`, `opt`,
   `flag`, `command`, `help` to build a tuple of `Arg` objects, then
   `newSpec`/`parse` assembles them into a `Spec` (`backend.nim`). Each arg is
   indexed into `spec.arguments` (positional, keyed by `<name>`),
   `spec.options` (optional/flag, keyed by `-o`/`--option`), or
   `spec.commands` (subcommands, keyed by the command word). If no `usage`
   string is given, one is auto-generated from the declared args.

2. **Usage-string compilation → FSM** (`lexer.nim` → `parser.nim` →
   `backend.nim`): the usage string (e.g. `[-r] <src>... <dest>`) is
   tokenized by `SpecLexer` and recursively-descent parsed
   (`atom`/`sequence`/`choice` in `parser.nim`) into a graph of `State`/
   `Transition` objects. Each token becomes a `Matcher` (`Argument`,
   `Option`, `Options`, `Command`, or `Shortcut` for optional/repeated
   branches). `backend.prepare` (`simplify` + `sortTransitions`) collapses
   shortcut chains and orders transitions by matcher priority
   (`ord(MatcherKind)`) so, e.g., positional args aren't greedily consumed
   ahead of options. `genFsm` calls `result.prepare()` directly after
   building the FSM from the usage string. `dot.nim` renders any FSM to
   Graphviz dot for debugging/visualization but is not called anywhere by
   default — wire up `spec.fsm.dot` (or `cmd.spec.fsm.dot` for a
   subcommand) manually when debugging FSM construction. `genFsm` also
   pre-scans every line of `spec.usage` (`parser.collectExplicitOptions`)
   for options mentioned by name, so the `[options]` catch-all
   (`tkAnyOption`) excludes them from its own `Options` matcher — e.g. in
   `[options] --verbose`, `--verbose` can only be matched once (via its own
   explicit atom), not once via `[options]` and again via the explicit
   mention. Without `...` on either side, no option can be repeated
   regardless of whether it's reached through `[options]` or written out
   explicitly — repetition always requires an explicit `...`.

3. **Runtime matching** (`fsm.nim`): actual `os.commandLineParams()` (or
   passed-in `args`) are first tokenized into `CmdLineToken`s
   (`tokenizeArgs`, order-independent w.r.t. options vs. positionals, with
   `--` ending option parsing and short-option clusters like `-abc` expanded).
   `walk` then recursively tries the FSM's transitions against the token
   stream, backtracking via a copied `ParseContext` (`fresh = pc`) on each
   branch attempt, accumulating the best-effort error `messages` from the
   deepest failed path so error messages point at the most specific match
   attempt, not just "invalid arguments". A successful walk populates
   `pc.matches: OrderedTable[Arg, seq[Match]]`, which is then fed back into
   each `Arg`'s `parse` method (see below) to actually convert/store values.

4. **Value conversion** (`src/argumint.nim`, top): `ValueArg[T: not seq,
   multi: static bool]` / `FlagArg[T]` are generic ref objects holding a
   parsed `Option[seq[T]]`/`T`. A single `ValueArg` type backs both scalar
   args (instantiated as `ValueArg[T, false]`, storing its value as a
   1-element seq) and multi-value args (instantiated as `ValueArg[T, true]`,
   appending on each match). Both `arg*` and `opt*` are overloaded on the
   `default` parameter's type to pick the arity: `default: T` (with a `= ""`
   fallback) selects the scalar overload, `default: seq[T]` (no fallback, so
   a seq default must always be given explicitly) selects the multi-value
   one — there's no separate `args*` proc. Because `multi` is a `static
   bool`, `ValueArg[T, false]` and `ValueArg[T, true]` are distinct
   concrete types to the compiler, so `toT`/`toSeqT` (see below) can be
   overloaded per-arity without ambiguity — you still can't accidentally use
   a scalar arg in a seq context or vice versa.
   `defineArg[T]` is a template that generates a `method parse` for a given
   `T` (both arities) by calling `parseImpl`, which converts the raw string
   via an implicit `converter` (`toInt`, `toFloat`, `toBool`, `toChar`;
   strings pass through) and then runs the arg's `Validator[T]`
   (`validators.nim`) if present — validation always happens against the
   scalar element type, never `seq[T]`, since it runs before the value is
   stored/appended. `defineArg[T]` also generates a `method defaultStr` per
   arity, used by `genHelp` to render `[default: <value>]` in help text
   (stringified via `$`; suppressed when the scalar default equals `T`'s
   zero value, i.e. `default(T)` — `""` for string, `0`/`0.0` for numeric
   types, `false` for bool — since that's the fallback used when no default
   was given (see `arg*`/`opt*`); an empty seq is the equivalent sentinel
   for the multi-value arity). The base `Arg.defaultStr` (commands, flags,
   message args) returns `""`, so flags never show a default. `defineArg[T]`
   likewise generates a per-arity `method validatorHelp`, which calls
   `self.validator.help()` (`validators.nim`) when a validator is present —
   `Validator[T].help` returns a short description per kind (`"choices: a,
   b, c"`, `"range: a..b"`, or a `check`/`checkIt` validator's own `desc`
   verbatim), also requiring `$` on `T`. `genHelp` combines `validatorHelp`
   and `defaultStr` into one bracket, `;`-separated (e.g. `[choices: foo,
   bar; default: foo]`), rather than showing them as two separate brackets.
   Flags are special: they don't take user converters —
   instead `defineArg[T](typeName, flagHandler)` registers per-type flag
   operations (e.g. `=`, `+=`, `-=` for `int`) via the `defineFlagOps` macro,
   stored in the `flagOps` `CacheTable` and looked up by `getFlagOps` at
   spec-construction time to validate that a flag variant's requested op
   (parsed out of the variant string itself, e.g. `--verbose+=2`) is actually
   supported for that type.
   Converters `toT*[T](arg: ValueArg[T, false]): T` and
   `toSeqT*[T](arg: ValueArg[T, true]): seq[T]` return the field's value
   transparently at use-sites — code reads `spec.dest` rather than
   `spec.dest.value`.
   **Gotcha**: appending to `self.value` (a `ValueArg[T, true]`'s
   `Option[seq[T]]`) via `self.value = some(self.value.get & @[tmp])` silently
   corrupts earlier elements under ORC — this only manifests once the object
   type carries an extra `static bool` param alongside `T`. `parseImpl` works
   around it by copying `self.value.get` into a local `var` and calling
   `.add` before reassigning; don't revert to the inline `get(...) & @[...]`
   form.

5. **Subcommands**: `command*` builds a `CommandArg` wrapping its own nested
   `Spec` (built via `newSpec` from a nested arg tuple), optionally binding a
   `handler` closure. A subcommand's FSM is spliced into the parent's FSM as
   a single `Command`-kind transition (see `atom()`'s `tkCommand` branch in
   `parser.nim`), with all of the subcommand's terminal states wired via
   shortcut back to a single continuation state in the parent graph.

## Key invariants / gotchas

- Only one of positional args, options, or commands is expected per spec
  level in typical usage, but nothing enforces this — the `usage` string
  alone determines what's syntactically valid at each grammar position.
- `arg`/`opt`/`flag`/`command` variant strings are validated with the PEG
  patterns near the top of `src/argumint.nim` (`PositionalVariantFormat`,
  `OptionalVariantFormat`, `FlagVariantFormat`) — errors here raise
  `SpecDefect`, not `ParseError` (spec-construction-time vs. parse-time
  failures are deliberately different exception types).
- `SpecDefect` is a `Defect` (raised on malformed developer-authored specs;
  not meant to be caught), while `ParseError`/`ValidationError`/`MessageError`
  are `CatchableError`s raised at user-input parse time. These are caught
  across two separate `try/except` blocks, one per `parse*` overload: the
  `tuple`-overload's block only catches `SpecDefect` from `newSpec`, while
  the `Spec`-overload's block catches `ParseError`/`ValidationError`/
  `HelpError`/`MessageError` (each `quit()`s with a formatted message).
- `Arg.hash` is keyed on `self.variants[0]` (the arg's first declared name,
  via `name()`), but there is no custom `==` for `Arg` — equality falls back
  to Nim's identity-based `EqRef` for ref types. A hash collision between
  two distinct `Arg`s that happen to share a first variant is harmless: the
  `MatchTable`/state dedup logic in `fsm.nim`/`backend.nim` still
  disambiguates them by identity, not by name.
- `newSpec` builds the FSM first, then calls `autoFillUsage` to patch any
  gaps: it uses `backend.referencedArgs` to collect every `Arg` actually
  referenced by a matcher, then appends usage lines for whatever isn't
  reachable and rebuilds the FSM once more if anything changed. This runs
  regardless of whether `usage` was left blank or passed in explicitly, and
  the fill-in rule differs by category:
  - **Commands** that are unreachable are joined into a single `(cmd1 |
    cmd2)` alternation line (all their variants flattened into one `|`-list)
    rather than one line per command, so a shared `[options]` prefix isn't
    repeated for each one. **`MessageArg`s** (e.g. `help()`) are still filled
    in per-arg — each missing one gets its own appended line — since they
    never carry the `[options]` prefix to begin with (see below) and are
    independently optional to mention. Mentioning one variant of a
    multi-variant arg counts as reachable; it won't be duplicated.
  - **Positional args** are all-or-nothing: only auto-appended (as one
    joined `<a> <b>` line, in declaration order) when *none* of them are
    reachable yet. A partially-specified sequence (some mentioned, some
    not) is left alone — there's no safe way to guess where the missing
    one belongs.
  - **Options** (`opt`/`flag`, non-`MessageArg`) aren't their own usage
    line; `[options]` (`tkAnyOption` in `parser.nim`'s `atom()`) — which
    itself never pulls in a `MessageArg`, by design — rides along as a
    prefix on whatever command/positional line gets auto-appended above.
    If nothing else gets appended (e.g. a spec with only options, no
    commands or positional args) but some option is still unreachable, a
    standalone `[options]` line is added as a fallback. Weaving `[options]`
    into an arbitrary hand-written line that's missing it is not attempted.
- `ValueArg[T, false].defaultStr` (used for `[default: <value>]` in help
  text) compares `self.default[0]` against `default(T)` to decide whether
  a default is "meaningfully set" or just T's zero value. This means `T`
  must support both `default(T)` and `==`. Nearly every type does, but a
  `{.requiresInit.}` object (which disallows default-construction) would
  fail to compile here if used as an `arg`/`opt` value type — not
  considered worth guarding against, since a user reaching for such a type
  here is unlikely, but worth knowing if `defineArg` ever fails to compile
  for a custom `T` with an unhelpful-looking error.
