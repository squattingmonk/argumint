# Prolog and epilog are re-flowed, not wrapped line by line

The built-in Help Formatters used to print the prolog and epilog as given:
Help Markup was applied and the text split at its newlines, but a line
longer than `settings.width` overflowed. They now go through `proseLines`,
which re-flows the text and wraps it at the width.

A long prolog is usually written as a `"""` string for convenience, so its
line breaks are where the author's editor happened to break, not where the
help should. Re-flowing is the only rule that works for that text at every
width. The rule is small and Markdown-like:

1. **Remove source indentation** with `strutils.dedent`: the indent every
   non-blank line shares is removed, and leading and trailing blank lines
   are dropped. Leading tabs are first expanded to 8-column tab stops, since
   `dedent` only counts spaces.
2. **Build paragraphs.** Consecutive lines join with a space. A blank line
   is kept, and separates paragraphs. An indented line is kept as its own
   line. A line starting with `- `, `* `, or digits and `. ` starts a list
   item, and a following line indented to exactly that item's text column
   (2 for `- `, 4 for `10. `) continues it, at any nesting depth.
3. **Apply Help Markup** to each block, after joining, so a backticked span
   broken across source lines still works.
4. **Wrap** each block at the width. A list item's continuation lines hang
   under its text, not its marker, and an indented line's keep its indent.
   The text always gets at least 20 columns, the floor row help text
   already has, so a very deep indent overflows the width rather than
   leaving no room at all.

To break a line without starting a new paragraph (`Copyright 2026` then
`MIT License`), leave a blank line or indent it.

Nim drops the newline right after an opening `"""`, so text started on the
next line has no unindented first line, and `dedent` removes its source
indentation. Text started right after the quotes (`"""Naval Fate.` with the
rest indented below) keeps the indentation of its later lines, which then
read as indented lines. That's the author's choice: shared indentation is
for text written below the quotes. A `cleandoc`-style rule, which ignores
the first line when measuring, would handle both forms, but it also strips
the indent from a plain string like `"Run:\n  prog --fast"`, joining a
line its author meant to keep separate.

## Considered options

- **Keep the line breaks, and wrap each line.** Simple and predictable, but
  a `"""` prolog wrapped at the author's editor width would come out ragged
  on a narrower terminal, with a short line after every source break, and
  its source indentation would still show.
- **Re-flow everything, with a setting for raw output** (argparse's
  `RawDescriptionHelpFormatter`). Full re-flow destroys lists and examples,
  and a mode switch makes the author choose between wrapping and
  structure. Indentation already marks text that shouldn't be joined, so
  no switch is needed.
- **Dedent like Python's `inspect.cleandoc`.** It supports text right
  after the opening quotes, at the cost of the surprise above.
- **Require list items to be indented.** It avoids a marker rule, but
  unindented `- item` lines are how most people write a list, and they'd
  have been silently joined into one paragraph.
