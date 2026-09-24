# Long-form arg descriptions via a `(short, long)` help pair

`arg`/`opt`/`flag`/`command`'s `help` parameter changes type from `string`
to a new `HelpText = tuple[short, long: string]`, with
`converter toHelpText*(s: string): HelpText = (short: s, long: "")` (in
`backend.nim`, alongside the existing `toEnvSource` converter) so every
existing call site passing a bare string keeps compiling unchanged. `Arg.help`
itself is retyped from `string` to `HelpText` directly, rather than gaining a
separate `longHelp*: string` field alongside an unchanged `help`. The
fallback rule lives on `HelpText` itself: `longOrShort*(help: HelpText)`
(`help.nim`) returns the long form if declared, else the short one.
`rows(arg, help = arg.help.short)` (see
docs/adr/0048-pluggable-help-formatters.md) takes the Help Text to show as
a plain string rather than choosing a form itself, so `formatParagraph`
calls `rows(arg, arg.help.longOrShort)` while `formatColumn` keeps calling
`rows(arg)` -- a fixed-width column makes a longer description actively
worse, so Column Style never looks at the long form at all. A caller who
wants a longer, prose-form description available only to Paragraph Style
writes
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

- **A `preferLong: bool` parameter on `rows`**, which is what first
  shipped. Rejected in review as a flag argument: `rows` had to know about
  the short/long pair to pick one, and a formatter wanting some other text
  (e.g. a future styled description) would need yet another parameter.
  Passing the text in keeps `rows` ignorant of `HelpText` and puts the
  fallback rule on the type it's about.

## Consequences

Implicit converters have a documented gotcha in this codebase
(`docs/gotchas.md`): they only fire when visible in the calling scope, and
can behave unexpectedly through generic inference. Every
`arg*[T: not seq]`/`opt*[T]`/`flag*[T]` overload needs to be verified against
this directly during implementation, not assumed to work by analogy to
`toEnvSource`.

Retyping `Arg.help` directly (rather than leaving it a `string` and adding a
separate `longHelp` field) is a breaking change for anything outside
`help.nim` that read `arg.help` as a plain string -- it must become
`arg.help.short` instead. This wasn't anticipated by this ADR's original
Decision (which kept `help` untouched); it only surfaced once implementation
found no second consumer to justify a standalone field or accessor.

The retype also turned out cheaper to thread through than the original
two-field design would have been: every `Arg`-constructing proc
(`initValueArg`/`initFlagArg`/`HelpArg`/`MessageArg`/`CommandArg`'s
constructors) only needed its `help` parameter's *type* to change from
`string` to `HelpText` -- the value still flows through as a single field
with no extra plumbing. A separate `longHelp` field would have meant adding
a second parameter and a second object-construction key
(`help: help.short, longHelp: help.long`) at every one of those call sites
instead of just one type annotation. It also means anything that builds an
`Arg`-derived type by embedding or forwarding an existing `help` field --
none does yet, since nothing external depends on this library, but a custom
`Arg` subtype eventually could -- gets `HelpText` for free rather than
needing its own signature updated to add `longHelp` alongside `help`.
