# `--help` and other Message Argument output goes to stdout

`parseOrQuit*` now prints every `MessageError` -- a `help()`'s message, a
`message()`/`version()`'s text, and completion candidates -- to **stdout**
with `QuitSuccess`, through one `echo e.msg; quit(QuitSuccess)` branch.
`ParseError` and `ValidationError` stay on **stderr** with `QuitFailure`.

Before this, only `CompletionError` reached stdout (see
`docs/adr/0012-fsm-driven-shell-completion.md`); help and messages went out
through `quit(e.msg, QuitSuccess)`, which on compiled targets writes to
stderr (`docs/gotchas.md`). That was never a decision -- it was `quit`'s
documented-but-untrue "shorthand for `echo`" -- and it broke the ordinary
things people do with help: `prog --help | less` and `prog --help | grep
port` both see an empty pipe.

The split follows what users already expect from GNU coding standards,
argparse, click, clap, and cobra: output the user *asked for* goes to
stdout and exits 0; diagnostics go to stderr and exit non-zero. Requested
help is output, not a diagnostic, even though it's delivered by raising.
The usage summary appended to a parse error stays on stderr, since there it
*is* part of the diagnostic.

## Considered options

- **Keep everything on stderr.** Rejected: it's the status quo only by
  accident (`quit`'s misleading doc comment, not a decision), and it breaks
  piping help into a pager or `grep` for no benefit.
- **Move only `HelpError` to stdout**, leaving `message()`/`version()` on
  stderr. Rejected: a version string is requested output just as help is --
  `prog --version | cut ...` is common in scripts -- and splitting them
  would keep three branches where one suffices.
- **Let callers choose the stream** via a `SpecSettings` field. Rejected as
  speculative: no caller has asked, and `parse*` already gives an embedding
  program full control.

## Consequences

- A behaviour change for any caller that captured help from stderr (e.g. a
  script doing `prog --help 2>&1 >/dev/null`). No test could have pinned
  the old stream, since `quit()` never runs inside a test process.
- `parse*` is unaffected: it raises, and the embedding program chooses the
  stream.
- The later help-styling work (#92) relies on this: it can judge help
  against stdout and errors against stderr when deciding whether a stream is
  a terminal.
