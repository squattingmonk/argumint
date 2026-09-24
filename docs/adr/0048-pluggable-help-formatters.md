# Help rendering goes through a pluggable `HelpFormatter`

`genHelp` grows a `formatter: HelpFormatter = formatColumn` parameter
(`HelpFormatter* = proc (spec: Spec, command: string): string`, defined in
`help.nim`), so a caller -- and a third party -- can choose how a Spec's
Help renders instead of only ever getting the existing two-column table.
A formatter renders the **whole** Help message: prolog, usage block, arg
groups, and epilog, and the order and labels of each. `genHelp` itself is
just `formatter(spec, command)`, kept as the stable entry point, so existing
two-arg `genHelp(spec, command)` calls keep compiling and produce
byte-identical output.

`formatColumn` (today's layout) and `formatParagraph` (variant name on its
own line, description wrapped as an indented paragraph below it) ship as
the two built-ins. `HelpArg` moves from `backend.nim` into `help.nim`
(nothing outside `help.nim`/`argumint.nim` ever checked `of HelpArg`
specifically -- only its parent `MessageArg` is load-bearing in the
FSM/parsing pipeline) and gains its own `formatter: HelpFormatter` field,
so a Spec can register more than one Help Message Argument, each rendering
differently.

`help.nim` exports the pieces both built-ins are assembled from, so a
third-party formatter is built the same way:

- `helpGroups(spec)` yields each Help Group's `(name, args)` in canonical
  order (`Commands`, `Arguments`, `Options`, then user-defined groups),
  dropping hidden Args and groups left with none. It yields `Arg`s rather
  than rendered rows so the formatter keeps the short/long help choice
  (ADR 0049) and anything else it needs from the Arg.
- `rows(arg, help)`, `Row`, `variantsByDesc`, and `annotations` resolve
  an Arg into renderable line-items, and `longOrShort` picks an Arg's
  Long-Form Help Text when declared (ADR 0049). `Row` is an object rather
  than a tuple so fields can be added later without breaking custom
  formatters.
- `prolog`, `epilog`, and `usage` are read-only accessors for `Spec`'s
  private fields (ADR 0030 keeps the fields themselves private; `usage` in
  particular can't become a public field, since assigning it would desync
  it from the compiled FSM). They're defined in `backend.nim` and
  re-exported by `help.nim`.
- `formatUsage(usage, command, width)` renders the wrapped, indented usage
  lines with **no** `Usage:` label: every caller writes its own, just as
  formatters write their own group headers.
- `joinSections(sections)` joins a message's non-empty parts with one blank
  line between each, so no part pads itself and every formatter spaces its
  sections like the built-ins.

`argumint.nim` re-exports `HelpArg`, `HelpFormatter`, `formatColumn`, and
`formatParagraph` (so choosing a built-in formatter needs no second import)
but none of the pieces above, which stay reachable only via
`import argumint/help` (ADR 0042's existing opt-in shape) for anyone
building a custom formatter.

The two layouts are named **Column Style** and **Paragraph Style**, not
"docopt style"/"man-page style" -- the existing layout isn't uniquely
docopt's (plenty of CLI tools use two columns), and Paragraph Style doesn't
render real `man`-page section headers, so both borrowed names would
overclaim. This also matches `therapist`, the library argumint originally
forked from, which already draws this same distinction under these names.
See `CONTEXT.md`'s Help/Help Formatter entries.

## Considered options

- **A formatter that renders only the arg groups**, with `genHelp`
  hard-coding the prolog, `Usage:` block, and epilog around it -- this
  design's original shape. Rejected: it can't express anything beyond row
  and group layout (a `USAGE:` or `SYNOPSIS` label, reordered sections, a
  template for the whole message), its `command`
  parameter went unused by both built-ins, and the formatter still had to
  emit the blank lines separating it from the usage block. Worse, widening
  it later would keep the same signature while changing its meaning, so
  existing custom formatters would silently drop their usage/prolog/epilog
  with no compile error.
- **A closed `HelpFormatterKind` enum + `case kind` dispatch inside
  `genHelp`**, mirroring `Matcher`/`MatcherKind` in `backend.nim`. Rejected:
  a closed set can't be extended by a third party without a PR to argumint
  itself, and the point of this seam is to let other formatters (e.g. a
  future styling or templating layer) hang off it later without one.
- **Method-dispatch on a `Formatter` object hierarchy**, mirroring `Arg`'s
  own `method` overrides. Rejected: `Arg` needs inheritance because it
  carries genuine per-instance state and identity (hash, equality-by-identity);
  a formatter is logic over already-resolved data, so a plain proc type is
  enough. A formatter that needs configuration (a template, a style) is a
  factory returning a closure, which the proc type already accepts.
- **A shared `formatGroups(spec, render)` helper** that writes group
  headers and calls back per group's rows. Rejected: it would fix the
  header format inside the helper (the thing styling and custom formatters
  most want to control) and hide the `Arg`s behind `Row`s, while saving only
  a few lines over looping `helpGroups` directly.
- **`genHelp` builds a richer intermediate model** (unjoined variant names,
  a per-row group name, structured rather than pre-joined annotations) and
  hands that to the formatter, instead of `Row`'s existing two plain
  strings. Rejected for now: nothing the Paragraph Style formatter needs is
  missing from `Row`, so a richer model is speculative generality for
  formatters that don't exist yet -- revisit if a real second consumer
  (e.g. a future styling formatter) actually needs more structure than
  `Row` carries.

## Consequences

A parse error's usage block doesn't go through any formatter:
`complaints.failureMessage` calls `formatUsage` directly and writes its own
fixed `Usage:` label. A formatter belongs to a `HelpArg`, not a `Spec`, so
there is no single formatter an error could ask. A custom formatter that
relabels the usage block (e.g. `SYNOPSIS`) will therefore look different
from error output; a Spec-level usage renderer both could share can be
added later without breaking anything.
