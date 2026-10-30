# Coding standards

The judgement calls a reviewer checks a diff against. Each rule names what to
look for, then why. Mechanical rules are automated checks instead, so a review
can skip them: doc-comment width and field doc-comment placement
(`tests/test_doc_comments.nim`), Markdown line width (markdownlint, configured
in `.markdownlint-cli2.yaml`), what md2html renders differently in the guide
(`tools/guidelint.nim`, run by `nimble docscheck`), and Conventional Commits PR
titles (`.github/workflows/pr-title.yml`).

Use the domain vocabulary in `GLOSSARY.md` when naming a finding, and check
`docs/adr/` before flagging a design choice: a deliberate decision there is
not a violation.

## Comments

- **One line, then a pointer.** An inline comment states the one non-obvious
  fact and points to where the reasoning lives: `docs/gotchas.md` for a Nim
  or compiler quirk, `docs/adr/NNNN-*.md` or a `docs/architecture.md`
  heading for a design decision. Flag a comment block of more than about two
  lines that re-explains a quirk or decision documented elsewhere. Rationale
  copied to each call site drifts out of sync.
- **Missing home.** When a long comment explains something no doc covers
  yet, the fix is a new `gotchas.md` entry or ADR plus the one-line pointer,
  not a shorter comment that drops the reasoning.
- **Cut narration.** A comment that restates the code below it in prose goes,
  with no pointer.
- **Banners stay.** `# ----` section dividers are deliberate visual
  structure. Leave them alone.

## Public surface

- **Facade and machinery** (ADR 0043). Every public name and its doc comment
  live in `src/argumint.nim`, or in the opt-in public module that owns it
  (`argumint/customarg`, `argumint/help`, `argumint/configsource`; ADRs
  0042, 0076). Code that touches a private field lives in a submodule,
  exported so the public module can reach it and withheld from its re-export
  list. Flag a public name defined in an internal module, or private-field
  code in a public one.
- **Reads through accessors, writes through `init*`.** An exported mutator on
  an Arg is a finding; the asymmetry with readers is deliberate.
- **Deep imports stay undocumented.** User-facing docs never show
  `import argumint/<internal>`. The promised modules are the ones ADR 0080
  lists.
- **1.x is frozen** (ADR 0080). Flag as needing a major release any change
  to: a name exported by a public module, the signature of a method a Custom
  Arg or Config Source overrides, `HelpFormatter`/`HelpContext`, what a
  usage string accepts (bug fixes excepted), or `requires "nim >= 2.2.4"`.
  Adding a method with a default, and changing help or error text, styling
  or completion-script contents, are fine in a minor release.

## Tests

- **Literal expectations.** Expected strings and seqs are typed out, not built
  from the helpers the code under test uses. `x == x` computed two ways
  proves nothing.
- **`not compiles` pins a designed constraint**: a generic bound, an overload
  rule, a private field. Flag one that only proves a name isn't exported, or
  that a parameter the signature never declared is rejected; nothing a test
  lists can catch the next name that leaks, and the compiler already
  guarantees the second.
- **Uncoloured output.** A test that renders help or a parse error through
  default settings passes `newSpecSettings(style = nil)`; otherwise it
  colours its output when run in a terminal. `FORCE_COLOR=1 nimble test`
  finds any that don't.
- **Weak assertions.** Flag `contains`/`notin` where the full value is known
  and a gap or reordering bug could hide behind the partial check.
- **No shadowing.** A local named like the proc under test (a `let
  annotations = ...` inside an `annotations()` test) reads as if the code
  computed its own expectation. Rename it.

## Change scope

- **Pin, don't fix.** A refactor that finds a pre-existing quirk pins the
  actual behaviour in a test with a comment saying it isn't endorsed, and
  files an issue. Flag a behaviour change hidden inside a change described
  as a refactor or as byte-identical.
- **Rename first.** When a feature needs an existing name or type changed,
  the rename lands as its own no-behaviour-change commit before the feature.
  Flag a feature commit that also renames public API it depends on.
- **ADRs for lasting decisions.** A user-facing, hard-to-reverse or
  trade-off-bearing decision gets an ADR and any new `GLOSSARY.md` terms in
  the same change. A mechanical internal change doesn't need one.

## User docs (`docs/guide/`, `README.md`)

- **Tutorial style.** Match `docs/guide/tutorial.md`: short plain sentences
  in second person and present tense; a code block, then a sentence or two
  on what's new, then its real output; things named by what the reader sees
  (`args`, `[options]`, "help").
- **Real output.** Console blocks come from compiling and running the
  snippet. Flag output that looks hand-edited or no longer matches the code
  above it.
- **No contributor detail.** No ADR numbers, `GLOSSARY.md` references or
  internal module names. Link to the topic page for depth instead of a long
  aside.

## Help output

- **Empty help stays empty.** An Arg with no `help` string gets a bare line,
  not placeholder text like "(no description)".
