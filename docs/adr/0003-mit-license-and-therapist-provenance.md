# License the project MIT; rewrite the one fsm.nim block that traced to LGPL-era therapist

argumint began as a fork of `maxgrenderjones/therapist`, which was MIT-licensed
when forked in 2020 but relicensed to LGPL in June 2022. Comparing argumint's
source against both therapist snapshots turned up one block that was actually
copied from the *post-relicense* (LGPL) therapist source: the short-option-
cluster tokenizer in `fsm.nim` (the `-abc`/`-abo=value` folding logic), which
shared a verbatim comment and PEG guard clause not present anywhere in the
2020 MIT snapshot. That block was rewritten from scratch (different guard,
loop shape, naming) to remove the LGPL provenance, verified against the
existing `tests/test_cli_syntax.nim` cases for identical behavior. With that
resolved, the project is licensed plain MIT (`LICENSE`, copyright Michael A.
Sinclair, 2026) with no LGPL encumbrance.

## Considered options

- **Dual-license/comply with LGPL for just that block** -- rejected as messy
  and out of step with wanting a single, simple MIT license for the whole
  project.
- **Ask upstream (Max Grender-Jones) for an MIT grant on that snippet** --
  not pursued; rewriting was faster and didn't depend on a third party.

## Other design similarities checked

Also checked whether bigger design choices shared with therapist -- the
tuple-based spec construction, the `Spec`/`Specification` object shape
(prolog/epilog plus options/arguments/commands tables), and `CommandArg`
wrapping its own nested spec -- were LGPL-era additions. They aren't: all
three are present in therapist's 2020 (MIT) initial commit, predating the
fork itself, so there's no timing issue there.

One related thing *did* turn out to be LGPL-era only: `CommandArg`'s
`handler: proc ()` dispatch field (absent from the 2020 snapshot, added to
therapist later) matches argumint's `handler` field closely -- same name,
signature, `isNil` guard, and closure-adaptation idiom. Judged too thin
(a largely-boilerplate, near-only-natural-expression pattern, unlike the
`fsm.nim` block's distinctive comment/regex) to be worth a rewrite, and left
as-is. May become moot anyway if `CommandArg` moves from a single `handler`
to separate before/after hooks.

**Update:** this did become moot. `docs/adr/0009-command-before-action-
after-hooks.md` removed `CommandArg.handler` outright, replacing it with
`before`/`action`/`after` hooks living on `Spec` -- the LGPL-adjacent field
this note was tracking no longer exists.
