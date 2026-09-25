# Help Formatters receive a Help Context

Whether Help Markup's backticks survive depends on whether there's a
Styler, and only help knows that. Because the ticks take up width, the
choice had to be made where text is built, so `keepTicks` was threaded
through about ten signatures, from `markup` up through `Validator`/
`FlagClamp.styledHelp`, `annotations`, `rows`, `proseLines`, and the
exported `Arg.validatorHelp` base method. Every custom `Arg` carried a
presentation parameter it had no use for, and every custom Help Formatter
had to know to pass `keepTicks = styler.isNil` to both `rows` and
`proseLines`. ADR 0048's toolkit was about ten procs, and a formatter that
forgot the rule got backticks in styled output with nothing to warn it.

Two changes move the decision to one place.

**Ticks are spans of their own** (#117). `markup` always keeps a code
span's two backticks, as spans with a new `srTick` Style Role, and
`withoutTicks` drops them. Text can be built anywhere without knowing about
the Styler, and the choice is made later, before anything measures or
wraps it. `keepTicks` is gone from `markup`, both `styledHelp`s,
`annotations`, and `Arg.validatorHelp`, which keeps returning `StyledText`,
so its `choices:`/`range:`/`clamp:` labels keep their `srAnnotation` role.
`defaultTheme` gives `srTick` no style; it only shows if a formatter styles
text without dropping the ticks.

**A formatter receives a Help Context** (#118).
`HelpFormatter = proc (ctx: HelpContext): string`. `genHelp` builds the
context once from the Spec's settings (`helpContext(spec, command)`), and
it hands out everything the built-ins are made from, with the ticks
already resolved: `groups`, `rows(arg, help)`, `prose(text)`, `usage`,
`heading(name)`, and `markup(prose)`, plus `render` with the Spec's
Styler. Its fields are private and it has no `styler` accessor, so a
formatter can't pair resolved text with a different Styler. `rows`,
`proseLines` (now folded into `prose`), `annotations`, `variantsByDesc`,
and `helpGroups` are private, and `help` no longer re-exports `markup`, so
the builders that skip the tick decision are out of reach. `usageLines`
stays public, because a parse error's usage block calls it. `import
argumint` exports the `HelpContext` type, as it does `HelpFormatter`.

ADR 0048 stands: the formatter still renders the whole message and is
still a plain proc. Only what it's given changes.

## Considered options

- **`validatorHelp`/`styledHelp` return Help Markup source, and `markup`
  runs once in help.** Help Markup can't express `srAnnotation`, so the
  `choices:`/`range:`/`clamp:` labels would lose their role while
  `default:`/`env:` kept theirs, and choice values would need backticking
  and escaping.
- **A `ticked` flag on `Span`** instead of a role. `StyledText`'s
  normalization would have to respect it, and a Styler couldn't see it.
- **Keep `proc (spec, command)`, with an optional `spec.helpContext`.**
  Building by hand stays possible, and so does forgetting the tick rule.
- **Pass `styler` to `rows`/`proseLines` in place of `keepTicks`.** The
  smallest change, but the toolkit stays about ten procs, the built-ins'
  private frame stays duplicated, and nothing ties `render` to the same
  Styler.
- **Other names.** `HelpPage` and `HelpMessage` read as the formatter's
  output. `HelpRenderer` collides with the Help Formatter, which the
  glossary calls the renderer. `HelpView` reads as the renderer to anyone
  who knows MVC. `HelpBuilder` suggests an object you add to and then call
  `build()` on.
- **Cache rows in the context**, since `variantsColWidth` builds every row
  once to measure it. Not worth the state for a cost that only shows in
  very large specs.

## Consequences

- A custom `HelpFormatter` changes signature. The README's example shows
  the new shape.
- A custom `Arg`'s `validatorHelp` override drops `keepTicks`.
- A `Theme` written as a full array literal needs an `srTick` entry. One
  copied from `defaultTheme`, as the README shows, doesn't.
- A formatter that renders with a bare `render` instead of `ctx.render`
  gets uncoloured text, with the ticks already dropped if the Spec has a
  Styler: neither plain nor styled output, so use `ctx.render`.
- Tests call `spec.genHelp("prog", formatColumn)` rather than a built-in
  directly.
