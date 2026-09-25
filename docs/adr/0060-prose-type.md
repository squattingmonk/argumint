# Re-flowed help text is a `Prose` type, laid out only by `wrap`

ADR 0055 kept `Row.text` a `StyledText` and encoded its blocks inside it: a
newline was a block break, and a leading `srPlain` span was an indent and
list marker. So `rows` built typed blocks, flattened them, and `wrapProse`
parsed them back. The rule's halves lived in `help.nim` and `style.nim`,
and completion ran a third pipeline of its own. A formatter that called
`row.text.wrap(w)` or `ctx.render(row.text)` compiled, and got the blocks
flattened or unwrapped.

Now the text is its own type (#133):

- `prose.nim` owns Prose: the re-flow rule (`toProse`), where an Arg's
  `[...]` bracket goes (`annotate`), the layout (`wrap`), and completion's
  one-line `summary`. It sits above `style.nim`, so `completion` can use it
  without importing `help`.
- `Prose` is opaque, and `wrap(p, width)` is its only public operation:
  `seq[StyledText]` lines, each block hung as ADR 0055 describes.
- `Row.text` is `Prose`, and `HelpContext.prose` returns `Prose`, ticks
  resolved but unwrapped, so a formatter lays out a prolog the same way as
  a row. The built-ins wrap prolog and epilog at `max(width, 20)`, as
  `prose` used to.
- `wrapProse` is gone. `help` re-exports only `Prose` and its `wrap`.

There's no `render`, `plain`, `len` or `&` for `Prose`. Every one would
print the text one block per line, unwrapped, which is never what a help
message wants, and code that treated `Row.text` as finished `StyledText`
now fails to compile instead. Any of them can be added later without
breaking anything; removing one after 1.0 would.

Help Markup (`markup`, `plainMarkup`, `withoutTicks`) stays in `style.nim`.
It styles spans inside a line, not blocks, and `validators`, `flagclamp`
and `complaints` use it without any block structure.

## Considered options

- **Keep `StyledText` (ADR 0055).** No break, but it keeps the round trip,
  and the wrong call still compiles.
- **Public blocks** (`kind`, `indent`, `marker`, `text`). A formatter could
  walk them, for Markdown or a man page, but the rule's output shape
  becomes API, and every formatter re-implements the hang. Nobody has
  asked for it.
- **A `hang` parameter on `wrap`** for Column Style's extra indent on a
  paragraph's continuations. That indent was an accident and is gone
  (#132), so there's nothing left to parameterize.
- **Move `markup` into `prose.nim` too.** One file for all help text, but
  three modules that never touch blocks would import it.
