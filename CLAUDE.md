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

- Compile/run the demo in `src/argumint.nim` (has a `when isMainModule` block
  with a working example spec):
  ```
  nim c -r src/argumint.nim -- [-r] <src> <dest>
  ```
- Compile the standalone unit tests in `src/argumint/validators.nim` (its
  `when isMainModule` block uses `std/unittest`):
  ```
  nim c -r src/argumint/validators.nim
  ```
- There is no `tests/` test suite yet (only `tests/config.nims`, which adds
  `src` to the path for anything placed there) and no `nimble test` task
  defined in `argumint.nimble`.
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
   subcommand) manually when debugging FSM construction.

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
   stored/appended. Flags are special: they don't take user converters —
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
  are `CatchableError`s raised at user-input parse time and handled by
  `argumint.parse`'s outer `try/except` (which `quit()`s with a formatted
  message).
- `Arg.hash`/`==` are keyed on `self.variants[0]` (the arg's first declared
  name) — two distinct `Arg`s must not share a first variant, or the
  `MatchTable`/state dedup logic in `fsm.nim`/`backend.nim` will conflate
  them.
- A `help()`/`MessageArg` is only reachable if the `usage` string mentions
  it explicitly (e.g. as its own `\n--help` alternative line), even though
  it's always registered in `spec.options` so it tokenizes fine. `[options]`
  (`tkAnyOption` in `parser.nim`'s `atom()`) does *not* pull it in either —
  it explicitly filters out `MessageArg`s. This only matters when you pass
  an explicit `usage` to `arg`/`command`; the auto-generated usage built by
  `newSpec` (when `usage` is left blank) already appends a `(-h | --help)`
  line for you.
