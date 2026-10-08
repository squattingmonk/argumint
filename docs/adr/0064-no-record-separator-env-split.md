# An env value is no longer split on `\x1e`

Partly supersedes ADRs 0005 and 0015.

ADRs 0005 and 0015 split an env value on `\x1e` (ASCII Record Separator)
whenever it held one, ahead of any configured delimiter, because that's
how fish joined a list variable's items when exporting it. fish stopped
doing that in 3.0. It now joins a list with spaces (`set -x TAGS a b c`
exports `TAGS=a b c`), except for a variable whose name ends in `PATH`,
which it joins with `:`. So the `\x1e` step no longer helped fish users, and
it could still split a value that happened to contain the byte.

## Decision

Drop the step and the public `EnvListSep` constant. An env value splits on
the Arg's own `EnvSource.delim` if it has one, otherwise on
`Spec.settings.envDelim`. An empty delimiter still means "don't split".

fish users who want a list variable read as several values split on a
space, using whichever of the existing settings fits:

- `env("TAGS", " ")` for one Option/Flag;
- `newSpecSettings(envDelim = " ")` for a whole Spec;
- `-d:argumint.envDelim=" "` at build time (ADR 0053).

## Considered options

- **Keep `\x1e` for fish 2.x and correct the docs**: rejected. fish 3.0
  shipped in 2018, and a byte no current shell writes is only a way for a
  value to split by surprise.
- **Split on a space by default**: rejected. `:` matches the `PATH`
  convention bash and zsh users expect, and a space is common inside a
  single value.

## Consequences

Breaking: `EnvListSep` is gone, and a value containing `\x1e` now splits
on the configured delimiter like any other value.
