# Every outcome has a plain `msg` and a `styledMsg`

ADR 0051 kept `ParseError.msg` and `ValidationError.msg` plain and put the
styled form in a separate `styledMsg`, so a caller who logs a caught error
never logs escape codes. It missed `HelpError`. `HelpArg.action` raised it
with `genHelp`, which renders with the Spec's Styler, so a program using
`parse` got escape codes in `HelpError.msg` whenever it ran in a terminal.
The test that `genHelp` matches `--help` ran only with `style = nil`, so
nothing caught it. `styledMsg` was also empty when the Spec had no Styler,
so every consumer needed a fallback to `msg`.

Now every outcome has the same shape (#127):

- `MessageError` gains `styledMsg`, and `HelpError` and `CompletionError`
  inherit it.
- `msg` is always plain. `HelpArg.action` renders `msg` through a Help
  Context with no Styler, and `styledMsg` through `genHelp`, calling the
  formatter a second time only when there is a Styler. That context comes
  from a private `helpContext` overload, so a formatter still can't pair
  resolved text with a different Styler (ADR 0057).
- `styledMsg` is filled on everything argumint raises, and is `msg` again
  when there's no Styler. So "print `styledMsg`, log `msg`" holds with no
  fallback. That includes the write side (`put`, `replace`, an Arg's string
  `parse`) and a `Validator` called directly, which raise through a withheld
  `newPlainError` since they have no Styler. It is empty only on an
  exception raised outside argumint, by a custom Arg's `action` or a hook.

A plain help `msg` is exactly what `style = nil` renders, so Help Markup's
backticks stay in it and `styledMsg` drops them, as for errors.

## Considered options

- **A common base type carrying `styledMsg`**, e.g. `ArgumintError` over
  `ParseError`, `ValidationError` and `MessageError`. Rejected: a
  `MessageError` isn't a failure (`parseOrQuit` exits `0`), and one base
  would invite catching `--help` as an error. Repeating the field costs one
  doc line per type.
- **Keep `styledMsg` empty when there's no Styler.** Rejected: every
  consumer, inside argumint or not, needs the same fallback, and nothing
  needs to tell "styled" from "plain" by an empty string.
- **A `styledMsg` getter that falls back to `msg`.** Always filled from the
  reader's side, even for exceptions raised elsewhere, but code outside
  argumint could no longer set it, and `errors.nim` would need withheld
  setters on types that freeze at 1.0.
- **`HelpFormatter` returns `StyledText`**, rendered twice by `genHelp`. One
  formatter call, but it breaks every custom formatter again, one ADR after
  0057.

## Consequences

- `HelpError.msg` no longer carries escape codes, and `styledMsg` is no
  longer empty without a Styler.
- A Help Formatter may be called twice per `--help`, so it should have no
  side effects.
- `parseOrQuit*` now picks what to print for each exception in one place,
  `outcome.nim` (#128), and its `Error constructing spec:` label is styled
  `srError` like the other failure labels.
