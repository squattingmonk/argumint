# Help and parse-error output is styled by role, auto-detected

Help and parse-error output are now drawn in colour and bold by what each
piece of text *is*: a closed set of **Style Roles** (`srHeader`,
`srProgram`, `srCommand`, `srOption`, `srPositional`, `srMetavar`, `srEnv`,
`srLiteral`, `srUrl`, `srAnnotation`, `srError`, and `srPlain` for
everything else). ADR 0056 adds `srInvalid`.
A **Styler** (`proc (role: StyleRole, text: string): string`, nil for
plain) turns each span into what's printed. It lives in
`SpecSettings.style` and cascades into subcommands like `width`. The
default is `autoStyler()`, resolved once when the settings are built (the
same precedent as `width = terminalWidth()`). (**Update:** ADR 0058 makes
`autoStyler` a marker that the `style` getter resolves on first read.)

`autoStyler` returns `ansiStyler(defaultTheme)` when stdout and stderr are
both terminals, and nil otherwise. `NO_COLOR` (non-empty) and `TERM=dumb`
turn it off. `FORCE_COLOR` (non-empty) or `CLICOLOR_FORCE` (anything but
`0`) turn it on regardless, following <https://no-color.org>,
<https://force-color.org> and the `CLICOLOR` convention. On Windows it
also enables `ENABLE_VIRTUAL_TERMINAL_PROCESSING` on both handles, and is
nil if that fails and colour wasn't forced. Every misdetection lands on
plain text, never on escape codes in a pipe. Checking both streams, not
just the one being written, is what lets a single setting serve both help
(stdout) and errors (stderr, ADR 0050).

On top of the seam sits a data layer for the common case: `TextStyle`
(a `std/terminal` `ForegroundColor` plus a `set[Style]`; no background),
`Theme = array[StyleRole, TextStyle]`, `defaultTheme`, and
`ansiStyler(theme)`. True colour, backgrounds, and hyperlinks are reachable
only by writing a `Styler`.

Styling rides on the span model of #91 (ADR 0048's consequences): every
measurement happens on plain span text before `render` applies the styler,
so a styler can emit anything without skewing a width.

## Where roles come from

- **Usage lines** are split with the lexer's own token patterns
  (`lexer.displayTokens`), so a usage token's role matches how it parses:
  options and `[options]` are `srOption`, commands `srCommand`, arguments
  `srPositional`, the `<kn>` of `--speed=<kn>` `srMetavar`, and punctuation
  `srPlain`. #88 proposed treating a `<x>` right after an option as a
  metavar too, but argumint's grammar parses `-o <file>` as an option then a
  *positional* `<file>` (it must be a declared argument), so it's styled as
  one.
- **Rows**: variants by the Arg's kind, splitting an option's `=<m>` into
  `srOption`, `srPlain`, `srMetavar`. Annotation brackets, `;` separators,
  and key labels (`default:`, `env:`, `choices:`, ...) are `srAnnotation`.
  Values are `srLiteral`, except an env var name (`srEnv`) and an `action:`
  description (prose, so it gets Help Markup).
- **Errors**: only the `Parsing error:`/`Validation error:` label
  (`srError`) and the usage block are styled. The complaint text stays
  plain; styling tokens inside it would mean converting `complaints.nim` to
  spans, left for later. **Update:** ADR 0056 styles the complaint text.

## Help Markup

Prose (help text short and long, `prolog`, `epilog`, and a validator's or
clamp's `desc`) can mark a span with backticks, and it gets a role by
**shape alone**. `-x`/`--xx` is `srOption`, and `--xx=<m>` adds `srMetavar`.
`<name>` is `srMetavar` if it's one of the Arg's own `metavars()` (derived
from its variants via `OptionalVariantFormat`) and `srPositional`
otherwise; in `prolog`/`epilog` there's no Arg, so it's always
`srPositional`. All-caps `NAME` is a placeholder too, matching the lexer's
second argument form, except that it must start with a letter so a number
stays a literal. That makes a backticked acronym like `JSON` a positional;
an author wanting a literal writes it another way. `$NAME` and Windows'
`%NAME%` are both `srEnv` on every platform, `scheme://...` is `srUrl`, and
anything else is `srLiteral`. There
is no spec lookup and nothing to fail on: a backticked `--flag` that names
no real variant isn't an error, since help may mention another program's
flags. A doubled backtick is a literal one, and so is an unclosed one.

Backticks are dropped when a styler is active and kept when plain, so
plain output is unchanged apart from doubled backticks collapsing. Prose
shown outside help (completion descriptions, a validator `desc` in a
`ValidationError`, a clamp's `help()`) goes through `plainMarkup`, so it
reads the same everywhere.

## Two things #88 left open

- **`validatorHelp` returns Styled Text.** It was a public base method
  returning a flat string, which loses where `choices:` ends and its
  values begin. It now takes `keepTicks` and returns `StyledText`, built by
  the new `Validator.styledHelp`/`FlagClamp.styledHelp`, whose `.plain` is
  the unchanged string `help()`. A custom Arg subtype overriding
  `validatorHelp` has to change its signature: a breaking change, accepted
  pre-1.0 over adding a parallel method that would have to stay in sync.
  **Update:** ADR 0057 drops `keepTicks` again: the ticks are `srTick`
  spans, dropped later.
- **`ParseError.msg` stays plain.** Rendering the usage block into `msg`
  would put escape codes into every caught error whenever the program runs
  in a terminal, including errors a caller logs. Instead `ParseError` and
  `ValidationError` carry a separate `styledMsg`, empty when the Spec has no
  styler, and only `parseOrQuit*` prints it.

## Considered options

- **Off by default.** Rejected: users expect colour from a modern CLI
  (clap's help, for one, is coloured by default), detection is
  conservative, and `style = nil` opts out in one argument.
- **A theme-only API with no `Styler` proc.** Rejected: it caps what's
  expressible at 8 colours and a few attributes; the proc costs nothing and
  the theme sits on top of it.
- **Validate backticked references against the spec.** Rejected for now:
  help legitimately names things that aren't in the spec. An opt-in lint
  could be added later.
- **A path role.** Rejected: only a conservative shape (`/`, `./`, `~/`, a
  drive letter) avoids mistaking literals like `config.json` for paths, and
  that misses how paths are usually written. It would also look the same as
  a literal, and unlike `srUrl` it gives a Styler nothing new to do.
  `srUrl` earns its place because a custom Styler can turn it into an OSC 8
  hyperlink, which it can't do if URLs are only ever `srLiteral`.
- **Put textual knobs (header wording, bracket format) beside `style`.**
  Rejected: a custom Help Formatter already owns the whole message.

## Consequences

- `import argumint` exports the configuration names (`StyleRole`, `Styler`,
  `TextStyle`, `Theme`, `defaultTheme`, `ansiStyler`, `autoStyler`, and
  `std/terminal`'s `ForegroundColor`/`Style`). `import argumint/help` adds
  the formatter-author names, now including `markup`. `metavars` and the
  `styledHelp` procs stay withheld; `validators`/`flagclamp` are
  re-exported `except styledHelp`. **Update:** ADR 0057
  withdraws `markup` from `help` in favour of `HelpContext.markup`.
- `rows` and `annotations` take `keepTicks`. A custom formatter that renders
  with `spec.settings.style` should pass `keepTicks = style.isNil`; one that
  ignores the setting renders plain, as before. **Update:** ADR 0057
  replaces this with a Help Context that makes the choice, and makes
  `rows` and `annotations` private.
- A test that renders help through default settings sees colour when run
  from a terminal, so such tests pass `style = nil`. Running the suite with
  `FORCE_COLOR=1` finds any that don't.
- `flagclamp.nim` now imports `style.nim` and is no longer a leaf module.
