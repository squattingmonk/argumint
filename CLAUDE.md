# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

`argumint` is a Nim command-line argument parsing library (Nim >= 2.2.4). Its
distinguishing feature is that a spec is declared as a tuple of `arg`/`opt`/
`flag`/`command`/`help` values, and a **docopt-style usage string** is
compiled into a finite state machine (FSM) that drives actual parsing. This
lets usage patterns express things like optional/repeated/mutually-exclusive
args (`[-r] <src>... <dest>`) declaratively instead of via imperative flag
registration.

## Commands

- Compile/run the full canonical Naval Fate demo at `examples/naval_fate.nim`
  (`examples/config.nims` adds `src` to the path):

  ```
  nim c -r examples/naval_fate.nim -- ship move Titanic 1 2
  ```

  Note: `nim c -r file -- args` may pass a spurious leading `--` through to
  the compiled binary depending on Nim version -- if a run fails with
  unexpected "missing option"/"unexpected arg" errors, compile first (`nim c
  file`) then run the binary directly with the same args to rule this out.
- Run the full test suite with `nimble test`, which compiles and runs
  `src/argumint/validators.nim`'s, `src/argumint/flagclamp.nim`'s, and
  `src/argumint/argtypes.nim`'s own embedded `std/unittest` blocks (plus a
  bare compile of `src/argumint/fsm.nim` and `src/argumint.nim`, neither of
  which has one of their own) and every `tests/test_*.nim` file (each is
  its own standalone `std/unittest` suite; `tests/config.nims` adds `src`
  to the path for anything placed there). Add new tests as new
  `tests/test_*.nim` files -- no per-file wiring needed beyond that naming
  convention.
- Dependencies are managed via Atlas (`atlas.workspace`, `deps/atlas.config`),
  not classic nimble/nimble.lock.
- `config.nims` sets `-d:nimPreviewHashRef` globally — required for the code
  to compile under Nim 2.2's ref-hashing preview.

## Where things live

- **Domain vocabulary** (Spec, Arg, Variant, Validator, Value Precedence,
  etc.) is defined in `CONTEXT.md` — read it before naming a concept in an
  issue, commit, or design discussion.
- **Design decisions** live in `docs/adr/` — check for an existing ADR before
  revisiting a decision (e.g. why catch-all options repeat by default, why
  validators skip coded defaults).
- **Implementation-level architecture** (how spec construction, FSM
  compilation, runtime matching, value conversion, and subcommands actually
  work, file by file) is in `docs/architecture.md`. Read that when you need
  to trace a bug through the pipeline or extend one of these phases.
- **Nim/compiler gotchas** hit while building this (template hygiene
  collisions, `fmt` failing inside generated methods, ORC seq-append
  corruption, overload-resolution ambiguities) are in `docs/gotchas.md`.
  Check it before fighting a confusing compile error in `defineArg`/
  `defineFlag`/`defineFlagArg` or the validator combinators.

Parsing happens in two distinct phases at a high level, detailed fully in
`docs/architecture.md`:

1. **Spec construction** (`specbuild.nim`, `src/argumint.nim`): user calls
   `arg`, `opt`, `flag`, `command`, `help` (`argumint.nim`) to build a tuple
   of `Arg` objects; `newSpec` (`specbuild.nim`) assembles them into a `Spec`
   (`backend.nim`), auto-generating a usage string from the declared args if
   none was given.
2. **Usage-string compilation → FSM** (`lexer.nim` → `parser.nim` →
   `backend.nim`/`fsmgraph.nim`): the usage string is tokenized and
   recursively-descent parsed into a graph of `State`/`Transition` objects
   (data model in `backend.nim`, graph construction/simplification in
   `fsmgraph.nim`), one `Matcher` per token kind (`Argument`, `Option`,
   `Options`, `Command`, `OptsEnd`, `Shortcut`).
3. **Runtime matching** (`fsm.nim`, token classification in `tokens.nim`,
   failure reporting in `complaints.nim`, Value Precedence fallback tiers in
   `precedence.nim`): command-line args are tokenized and classified against
   the live `Spec` lazily via a `TokenCursor` (`tokens.nim`), walked against
   the FSM with backtracking -- recording any failure into a `Report`
   (`complaints.nim`) along the way -- then a post-walk sweep
   (`precedence.applyFallbacks`) applies any configured environment-variable
   or Config Source fallbacks.
4. **Value conversion** (`argtypes.nim`, `src/argumint.nim`): `ValueArg`/
   `FlagArg` convert, validate, and store matched values; flags apply Flag
   Operations instead of a plain converter. Every public name lives in
   `argumint.nim`; everything that touches a private field lives in
   `argtypes.nim`, exported for the facade and withheld from users.
5. **Subcommands**: `command*` splices a nested `Spec`'s FSM into the
   parent's as a single `Command` transition.

## Key invariants / gotchas

- Nothing in the type system or FSM prevents mixing any combination of
  positional args, options, and commands in one usage line — the `usage`
  string alone determines what's syntactically valid at each grammar
  position (verified: `<name> [-v] doit` with `doit` a command works fine).
  Convention, not enforcement, tends to keep positional args and commands in
  separate spec levels (e.g. Naval Fate's top-level spec has commands only,
  each subcommand's nested spec has positional args only) — but options
  routinely appear alongside either.
- `arg`/`opt`/`flag`/`command` variant strings are validated with the PEG
  patterns in `src/argumint/backend.nim` (`PositionalVariantFormat`,
  `OptionalVariantFormat`, `FlagVariantFormat`) — errors here raise
  `SpecDefect`, not `ParseError` (spec-construction-time vs. parse-time
  failures are deliberately different exception types).
- `SpecDefect` is a `Defect` (raised on malformed developer-authored specs;
  not meant to be caught), while `ParseError`/`ValidationError`/`MessageError`
  are `CatchableError`s raised at user-input parse time. All of them live in
  `errors.nim`, a leaf module with no local imports, so any module can name
  an exception without depending on whichever one raises it. `parse*`
  (`argumint.nim`, both the `Spec` and `tuple` overloads) lets all of these
  propagate to the caller; `parseOrQuit*` catches them and `quit()`s with a
  formatted message instead. `parse*` is the recommended entry point for
  embedding argumint in a larger program; `parseOrQuit*` is for a bare CLI
  `main()`.
- `Arg.hash` is keyed on `self.variants[0]` (the arg's first declared name),
  but there is no custom `==` for `Arg` — equality falls back to Nim's
  identity-based `EqRef`. A hash collision between two distinct `Arg`s that
  happen to share a first variant is harmless: the FSM/backend dedup logic
  disambiguates by identity, not by name.
- An `opt`/`opts`/`flag`'s `env` var is consulted regardless of whether that
  Arg is required or optional in the usage grammar (see
  `docs/adr/0004-required-options-env-fallback.md`, superseding
  `docs/adr/0001`), and can supply more than one value (see
  `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`). Full
  mechanics in `docs/architecture.md`.

## Agent skills

### Issue tracker

Issues live in GitHub Issues for squattingmonk/argumint, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (CONTEXT.md + docs/adr/ at repo root). See `docs/agents/domain.md`.
