# Revealing hidden Args in help

argumint has no way to list a hidden Arg in a help message. A Help
Context always drops an Arg with `hidden = true`, and neither `filter`
nor anything else brings it back. A program that wants a short `--help`
beside a fuller `--help-all` puts the extra Args in a Help Group and
filters that group out of `--help`.

## Why this is out of scope

`hidden` means "not advertised anywhere" (ADR 0065): not in help and not
in completion, though it still parses. Programs use it for Args that only
someone who already knows the name should use: an old name kept so
existing scripts still work, such as the guide's `--warp`, or an internal
command, such as a hidden `completion("gen-completion")`.

The request was really about a second kind of Arg: one that is fine to
use but would clutter a short help message. Leaving that out of `--help`
is a help-only choice, and a Help Context filter already makes it (ADR
0082):

```nim
import std/sugar
import argumint, argumint/help

proc formatBasic(ctx: HelpContext): string =
  formatColumn(ctx.filter((arg) => arg.group != "Advanced"))

let spec = (
  ballast: opt("--ballast=<t>", default = 0, help = "Extra ballast in tonnes",
    group = "Advanced"),
  help: help(formatter = formatBasic),
  helpAll: help("--help-all", help = "Display every option"),
)
```

The guide's "Your Own Help Layout" section walks through this pattern.
The `Advanced` group's Args still complete, which the request counted as
a drawback. It isn't: an Arg that `--help-all` tells the user about is
one the shell should complete.

Both designs proposed would have made `hidden` do both jobs:

- **A context that reveals hidden Args** (`ctx.withHidden`) can't tell the
  two kinds apart. A `--help-all` built on it would also list the old
  names and internal commands the program hid so that no one would learn
  them.
- **Help levels**, as in therapist (an Arg's `helpLevel` against a help
  message's `showLevel`), can tell them apart. Replacing `hidden` with a
  level would remove a parameter from `arg`, `opt` and `flag`, which
  breaks 1.x (ADR 0080). Adding levels beside `hidden` wouldn't break
  anything, but the only thing they add over Help Groups and `filter` is
  an Arg that is left out of completion yet listed in some help message,
  and no known program needs that.

clap draws the same line: `hide` keeps an Arg out of everything, and
`hide_short_help` keeps it out of the short help only. In argumint the
second is a Help Group plus `filter`.

## Prior requests

- #324: "Let a help message reveal hidden Args"
