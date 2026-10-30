# CLAUDE.md

`argumint` is a Nim command-line argument parsing library (Nim >= 2.2.4). A
spec is a tuple of `arg`/`opt`/`flag`/`command`/`help` values, and a
docopt-style usage string (`[-r] <src>... <dest>`) is compiled into a finite
state machine that drives parsing.

## Commands

- `nimble test` runs every `.nim` file under `src/` (its `when isMainModule`
  suite, or a bare compile-check) plus every `.nim` file under `tests/`,
  subdirectories included. Add a test as a `when isMainModule` block in the
  module under test, or as a new `tests/test_*.nim` for cross-module or
  fixture-heavy cases; neither needs wiring. A helper module a test imports
  goes in `tests/fixtures/`, which the runner skips. `tests/config.nims` and
  `examples/config.nims` put `src` on the path, and the tests' config keeps
  an installed argumint out. See `tools/runtests.nim`.
- `nimble docscheck` lints the guide's Markdown and compiles its examples;
  `nimble docs` builds the API docs and fails on any doc-comment error.
- `markdownlint-cli2 "**/*.md"` checks every Markdown file's line width (an
  80-column wrap; code blocks, tables and headings exempt). It is installed
  separately (e.g. `npm i -g markdownlint-cli2`) and runs in the Docs
  workflow.
- `nimble cleanbins` deletes the stray binaries a lone `nim c` leaves beside
  its source.
- Run the Naval Fate demo with
  `nim c -r examples/naval_fate.nim -- ship move Titanic 1 2`. Some Nim
  versions pass the `--` through to the binary; if a run fails with
  "missing option"/"unexpected arg", compile first and run the binary
  directly.

## Branches

- `main` is the 1.x line. Features and fixes branch from it and squash-merge
  back into it; release-please releases from it.
- `next` collects breaking changes for 2.0 and is never released from. A
  breaking change (a `!` in its PR title) branches from `next` and
  squash-merges back into it. Keep `next` current by merging `main` into it
  with a merge commit, never a squash or rebase; nothing flows from `next`
  to `main` until the 2.0 cut.
- At the 2.0 cut, a `1.x` branch is made from the last 1.x tag for
  backports, and `next` merges into `main`.
- Every ADR lands on `main`, a 2.0 one included, so `main` alone hands out
  ADR numbers and `next` gets each one through the `main` merge. Never add
  an ADR on `next`: the next 1.x ADR would reuse its number. A 2.0 ADR
  says in its opening paragraph that it ships in 2.0; its feature then
  branches from `next` once `main` has been merged in. Pick the number
  against the latest `main` just before shipping, since a parallel PR may
  have taken it.

## Where things live

- **Coding standards** a reviewer checks a diff against are in
  `CODING_STANDARDS.md` — read it before writing or reviewing code; it also
  names which rules are automated checks instead.
- **Domain vocabulary** (Spec, Arg, Variant, Validator, Value Precedence, ...)
  is in `GLOSSARY.md` — use its terms in issues, commits and designs.
- **Design decisions** are in `docs/adr/` — check for an existing ADR before
  revisiting a decision.
- **How the pipeline works**, module by module (spec construction,
  usage-string compilation, the walk, failure reporting, value conversion,
  dispatch, help, completion), is in `docs/architecture.md`. Read it before
  tracing a bug or extending a phase.
- **Nim/compiler gotchas** (generics resolving names in the caller's module,
  `privateAccess` across modules, nested closures capturing `result`,
  overload ambiguities) are in `docs/gotchas.md`. Check it before fighting a
  confusing compile error.
- **Architecture reviews** are in `docs/reviews/`, one file per review, each
  a lettered list of candidates. Link an issue to its candidate's heading,
  and mark the candidate shipped (issue, PR, squash hash) when it lands.
- **Rejected requests** are in `.out-of-scope/`, one file per concept: a
  `wontfix` enhancement and why it was turned down (not one closed as
  already implemented). Read it before triaging a request, so one turned
  down before comes back with its reasoning; delete a concept's file if
  it's reconsidered.
- **Errors**: a malformed developer-written spec raises `SpecDefect`; every
  user-input failure is a `ParseError` subtype. See
  `src/argumint/core/errors.nim` and ADR 0078.

## Agent skills

### Issue tracker

Issues live in GitHub Issues for squattingmonk/argumint, via the `gh` CLI.
See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (needs-triage, needs-info, ready-for-agent,
ready-for-human, wontfix). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (GLOSSARY.md + docs/adr/ at repo root). See
`docs/agents/domain.md`.
