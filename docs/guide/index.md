# argumint User Guide

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

argumint parses a command line against a docopt-style usage string, which it
compiles into a finite state machine. For installation and a quickstart, see
the [README](https://github.com/squattingmonk/argumint#readme). For every
public proc and type, see the
[API reference](https://squattingmonk.github.io/argumint/argumint.html).

## Contents

- [Tutorial](tutorial.md) — build a small notebook CLI step by step. Start
  here if you're new to argumint.
- [Specs and Values](specs.md) — declaring a spec, reading parsed values,
  setting values yourself, and parsing more than once.
- [Usage Strings](usage-strings.md) — the usage-string grammar and the FSM
  it compiles to.
- [Arguments and Options](args-and-options.md) — declaring positional
  arguments and options, and validating their values.
- [Flags](flags.md) — flag operations, composition order, custom flag types,
  and clamping.
- [Value Precedence](precedence.md) — falling back to env vars and Config
  Sources.
- [Commands](commands.md) — nested subcommands and their hooks.
- [Help and Messages](help.md) — generated help, Paragraph Style, styling,
  and custom messages like `--version`.
- [Shell Completion](completion.md) — `bash`/`zsh`/`fish` completion.
- [Error Handling](errors.md) — parse errors and strict option checking.
