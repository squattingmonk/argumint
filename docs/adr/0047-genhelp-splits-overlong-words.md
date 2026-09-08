# `genHelp` splits an overlong variant name or help word instead of overflowing it

A variant name (`--extraordinarily-long-option-name`) or a help-text word
too long to fit its column now splits at the character level across
multiple lines, the same way a terminal hard-wraps an overlong URL. This
applies uniformly to the variants column and help text in `render()`, and
to usage-line wrapping in `formatUsage()` (`src/argumint/help.nim`).

The prior behavior -- leaving such a word whole and letting it overflow --
was not a deliberate design choice. It was an artifact preserved during
the byte-identical-output refactor in commit 4eb3999, pinned by two tests
titled "...is not split mid-word" that predate any actual decision to
avoid splitting. Once that was clear, keeping it was no longer defensible
on its own terms: an unbreakable overlong word forced `render()`'s
zip-by-index pairing to desync -- the wrap call returned a blank leading
line for the word, which then got paired with the *wrong* row's content
(issue #70). That's not a cosmetic rough edge; it produces genuinely
misleading output (a variant's help text appearing to belong to a
different row, or an option name silently detached from its own
description).

Splitting trades that correctness bug for a readability cost: an overlong
identifier gets torn into fragments (`--extr` / `aordinaril` / `y-long-` /
`option-name`) that no longer read as one flag at a glance. That cost is
accepted because the escape hatch already exists and is cheap to use --
`SpecSettings.width`/`maxVariantsWidth` (`newSpecSettings`, cascading to
every nested command's `Spec` by reference) control the wrap width
directly, and `maxVariantsWidth = 0` disables the variants-column cap
outright. A spec with unusually long option names can raise either at
construction time, or have a subcommand's own `before` hook mutate
`Spec.settings` right before that subcommand's own help renders. See the
README's "Displaying Help" section.

Implementing this exposed a real bug in `std/wordwrap.wrapWords(
splitLongWords = true)`: it drops the separator immediately before a word
that needs splitting (`"-x, --longflag"` at width 10 comes back as
`"-x,--longf"`, eating the space) instead of flushing it first the way its
own "word fits" branch does. `help.nim` forks a corrected local `wrapWords`
with that one fix rather than depending on the buggy stdlib version -- see
`docs/gotchas.md`.

## Considered options

- **Restructure `render()`'s pairing instead of allowing splits.** Explored
  first: give an overlong variant its own dedicated line, with help text
  entirely below it rather than sharing a row. This does fix the
  mispairing, but only for the "nothing precedes the overlong word" case --
  it doesn't generalize cleanly to a variant list where the overlong name
  is the *second* alias (`-x, --extraordinarily-long-option-name`), where
  the existing per-line wrap-and-zip behavior is already correct and needs
  no restructuring at all. Splitting needed no restructuring in either
  case, and `render()`'s pairing logic ended up completely unchanged.
- **Detect the blank leading line and special-case it.** A narrower version
  of the above, scoped to just the `variantLines[0] == ""` trigger. Same
  problem: it's a patch for one symptom of a wrap call that shouldn't
  produce a blank line in the first place, not a fix for the underlying
  cause.
- **Leave it as-is; document as a known rare-edge-case limitation.**
  Rejected -- this is a correctness bug (wrong text visually attached to
  the wrong variant), not just an aesthetic one, so it doesn't meet the bar
  for "acceptable edge case."
