# `{cmd}` starts a Usage Line, and a line of only `{cmd}` is a Bare Call

A Usage Line leaves out the command's name, since the name isn't a
declared Arg. So a Usage String had no way to say "the command alone" as
one of its alternatives, which docopt writes as the program name on its own
line:

```
prog
prog <foo> [<bar>]
```

The only way was to make a whole line optional (`[<foo> [<bar>]]`), which
reads worse in help. A Command whose own usage is empty accepts a bare
call, but only because it has no Usage Lines at all.

Now a Usage Line may start with `{cmd}`, which stands for the command path
(`prog`, or `prog ship` in a subcommand's usage), and a line of only
`{cmd}` is a Bare Call (#139):

```
{cmd}
{cmd} <foo> [<bar>]
```

- `usage.splitUsage` strips a leading `{cmd}` after joining indented lines,
  so every consumer gets lines without it: the parser, which already
  accepts an empty line as a Bare Call, and help, which puts the command in
  front of every line as before. `spec.usage` is kept as written.
- `{cmd}` is optional on each line, so it mixes with lines that leave it
  out, and every existing usage string is unchanged. `autoFillUsage`
  appends its lines without it.
- `{cmd}` must be followed by whitespace or the line's end. Anywhere else
  (`<foo> {cmd}`, `{cmd}<foo>`, or an indented line continuing another) is
  a `SpecDefect` naming the Usage Line. `{` was never valid usage syntax,
  so nothing that built before changes.
- `{cmd}` on a line of its own continued by an indented line is that line,
  not a Bare Call.

A usage string built with `fmt` needs `{{cmd}}`. Usage strings are rarely
built that way.

## Considered options

- **A blank line is a Bare Call.** It's what help showed before #137 (#68's
  reading), with no new syntax. But a `"""` string ends in a newline when
  its closing quotes sit on their own line, so the common style would add
  a Bare Call silently, and a reader can't tell one from spacing. Blank
  lines are ignored instead (#137).
- **A blank line is a Bare Call, trimming leading and trailing ones.** Safe
  from the `"""` newline, but a Bare Call could then never come first or
  last, and first is where it reads most naturally.
- **`{cmd}` all-or-nothing.** Uniform to read, but `autoFillUsage` appends
  lines without `{cmd}`, so it would have to match the user's style, for no
  gain in what a usage string can say.
- **Keep `{cmd}` in the normalized lines.** The parser would strip it and
  help would substitute it. The same output, with two places that know the
  token instead of one.
- **`{prog}`.** In a subcommand it stands for the whole command path, not
  just the program.
- **An empty group, `[]`, as a Bare Call.** Also free today, but it reads
  as nothing rather than as the command.
