# Arg help text is re-flowed, and `Row.text`'s lines are blocks

An Arg's help text now follows the prolog and epilog's re-flow rule (ADR
0054), in both built-in formatters. It used to go through Help Markup and
then `wrap`, which turns every newline into a space: a `"""` long form
leaked its source indentation as runs of spaces, and its paragraphs and
lists ran together. Long-form help, which Paragraph Style shows, is where
multi-paragraph text belongs, so this was most visible exactly where it
mattered.

## `Row.text` keeps its type

`Row.text` is still one `StyledText`, but its newlines now mean something.
Each line is one block (a paragraph, a list item, an indented line, or a
blank line), with its indent and marker written out as leading `srPlain`
text. The new public `wrapProse` lays such text out: it reads each line's
indent and marker back, and hangs its continuation lines under its text.
The built-in renderers call it in place of `wrap`, and `proseLines` is now
built on it too.

Nothing is lost by encoding blocks this way. A paragraph can't start with
a list marker, since that line would have become a list item, and an
indented line's indent is exactly its leading spaces. The one ambiguity is
markup: with `keepTicks = false`, a backticked `` `- x` `` renders as
`- x`. Only a marker in an `srPlain` span counts, and a backticked span
never starts with one.

A custom formatter that still calls `row.text.wrap(w)` keeps compiling and
gets today's flattened output; one that calls `render` gets the blocks one
per line.

## The annotation bracket

When the text is one block, the `[...]` bracket is appended to it after a
space, as before. When there
are several blocks, the bracket follows them after a blank line, as its
own block. Appended to the last block, it would read as part of a final
list item (`- safe: checks every block [default: fast]`).

The bracket's parts (a validator's or clamp's `desc`, the default, the
env var, the config key, a divergent variant's `action:`) are flattened to
one line: any whitespace containing a newline collapses to a space. A
bracket spanning blocks can't be laid out sensibly. A divergent variant's
`variantDesc` used as the row's main text, when `help` is empty, is main
text and gets the full rule.

## Column Style follows the rule too

A short help is normally one line, but a `"""` short help leaked its
indentation in Column Style exactly as a long form did in Paragraph Style.
So `renderColumn` uses `wrapProse`'s layout too, giving a multi-block
cell. Each block starts at the text column, even beside a variants line
that is still wrapping, and only a paragraph's wrap continuations get
Column Style's usual extra indent: a list item or indented line is already
hung by `wrapProse`.

## Width

Text with no indent or marker wraps at exactly the renderer's width. Hung
text gets at least 20 columns, or the whole width if that's narrower.
`proseLines` still never wraps below 20, as before.

So single-line help renders byte-identically, at any width, unless it
starts with a list marker or is indented. Help like `- deprecated` or
`1. first` is now a list item and wraps hanging under its text, which a
test pins. An indent in a one-line string is dedented away.

## Considered options

- **Change `Row.text` to a sequence of blocks with a public block type.**
  Explicit, but it breaks every custom formatter and adds a type to
  maintain, for information the text itself can carry.
- **Add a `blocks` field beside `text`.** Not breaking, but the same
  content twice, which can drift.
- **Append the bracket to the last block.** Simplest, but it attaches the
  bracket to a final list item.
- **Keep Column Style flattening.** It needs `rows` to build two kinds of
  text, and keeps the leaked-indentation bug in the default formatter.
- **Re-flow the bracket's parts too.** Paragraphs or lists nested inside
  `[...]` have no sensible layout, and nobody has asked for them.
