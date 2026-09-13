# Long-form arg descriptions via a `(short, long)` help pair

`arg`/`opt`/`flag`/`command`'s `help` parameter changes type from `string`
to a new `HelpText = tuple[short, long: string]`, with
`converter toHelpText*(s: string): HelpText = (short: s, long: "")` (in
`backend.nim`, alongside the existing `toEnvSource` converter) so every
existing call site passing a bare string keeps compiling unchanged. `Arg`
gains a `longHelp*: string` field (empty means "not given", the same
convention as `help` itself) populated from `HelpText.long`.
`rows(arg, preferLong = false)` (see docs/adr/0048-pluggable-help-formatters.md)
gains that parameter: when true and `arg.longHelp` is non-empty, it becomes
the row's Help Text source instead of `arg.help`. `formatParagraph` calls
`rows(arg, preferLong = true)`; `formatColumn` keeps calling `rows(arg)` --
a fixed-width column makes a longer description actively worse, so Column
Style never looks at `longHelp` at all. A caller who wants a longer,
prose-form description available only to Paragraph Style writes
`help = ("Speed in knots", "Speed in knots. Must be between 1 and 100...")`
instead of a plain string; nothing else about
`arg`/`opt`/`flag`/`command`'s signatures changes. See `CONTEXT.md`'s Help
Text/Long-Form Help Text entries.

## Considered options

- **`Option[string]` for `longHelp`** instead of a plain string defaulting
  to empty. Rejected for consistency: `help` itself is a plain `string`
  with `""` meaning absent, and there's no case here where "explicitly set
  to empty" needs distinguishing from "never given" the way `Option` would
  buy.
- **A second, explicit `longHelp` parameter** on every `arg`/`opt`/`flag`/
  `command` overload, instead of overloading `help`'s own type. Rejected:
  `help` is a parameter shared across roughly a dozen overloaded (several
  of them generic) constructor procs; adding a new parameter to all of
  them is far more invasive than reusing the already-proven
  `converter`-on-a-single-parameter pattern `toEnvSource` established for
  `env`.

## Consequences

Implicit converters have a documented gotcha in this codebase
(`docs/gotchas.md`): they only fire when visible in the calling scope, and
can behave unexpectedly through generic inference. Every
`arg*[T: not seq]`/`opt*[T]`/`flag*[T]` overload needs to be verified against
this directly during implementation, not assumed to work by analogy to
`toEnvSource`.
