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
   ahead of options. `dot.nim` renders any FSM to Graphviz dot for
   debugging/visualization — genFsm currently `echo`s a before/after dot
   graph unconditionally (see commented-out `result.prepare()` call in
   `parser.nim`; simplification is not currently wired in).

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

4. **Value conversion** (`src/argumint.nim`, top): `ValueArg[T]` /
   `ValuesArg[T]` / `FlagArg[T]` are generic ref objects holding a parsed
   `Option[T]`/`Option[seq[T]]`/`T`. `defineArg[T]` is a template that
   generates a `method parse` for a given `T` by calling `parseImpl`, which
   converts the raw string via an implicit `converter` (`toInt`, `toFloat`,
   `toBool`, `toChar`; strings pass through) and then runs the arg's
   `Validator[T]` (`validators.nim`) if present. Flags are special: they
   don't take user converters — instead `defineArg[T](typeName, flagHandler)`
   registers per-type flag operations (e.g. `=`, `+=`, `-=` for `int`) via the
   `defineFlagOps` macro, stored in the `flagOps` `CacheTable` and looked up by
   `getFlagOps` at spec-construction time to validate that a flag variant's
   requested op (parsed out of the variant string itself, e.g.
   `--verbose+=2`) is actually supported for that type.
   Converters for `ValueArg`/`ValuesArg` return the field's value as `T`/
   `seq[T]` transparently at use-sites via the `toT`/`toSeqT` converters —
   code reads `spec.dest` rather than `spec.dest.value`.

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
