# Help rendering goes through a pluggable `HelpFormatter`

`genHelp` grows a `formatter: HelpFormatter = formatColumn` parameter
(`HelpFormatter* = proc (spec: Spec, command: string): string`, defined in
`help.nim`), so a caller -- and a third party -- can choose how a Spec's
Help renders instead of only ever getting the existing two-column table.
`formatColumn` (today's unchanged layout) and `formatParagraph` (variant
name on its own line, description wrapped as an indented paragraph below
it) ship as the two built-ins; existing two-arg `genHelp(spec, command)`
calls keep compiling and behaving identically. `HelpArg` moves from
`backend.nim` into `help.nim` (nothing outside `help.nim`/`argumint.nim`
ever checked `of HelpArg` specifically -- only its parent `MessageArg` is
load-bearing in the FSM/parsing pipeline) and gains its own
`formatter: HelpFormatter` field, so a Spec can register more than one Help
Message Argument, each rendering differently. `help.nim`'s previously-private
`groupOrder`, `rows`, `variantGroups`, `annotations`, and `Row` all become
exported: both built-in formatters, and any third-party one, need the same
"resolve a Spec's Args into renderable rows, filtering hidden ones, in
canonical group order" logic, and exporting the existing correct
implementation avoids every formatter re-deriving it. `argumint.nim`
re-exports `HelpFormatter`, `formatColumn`, and `formatParagraph` (so
choosing a built-in formatter needs no second import) but not the
lower-level `Row`/`rows`/`groupOrder`/etc., which stay reachable only via
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

- **A closed `HelpFormatterKind` enum + `case kind` dispatch inside
  `genHelp`**, mirroring `Matcher`/`MatcherKind` in `backend.nim`. Rejected:
  a closed set can't be extended by a third party without a PR to argumint
  itself, and the point of this seam is to let other formatters (e.g. a
  future styling or templating layer) hang off it later without one.
- **Method-dispatch on a `Formatter` object hierarchy**, mirroring `Arg`'s
  own `method` overrides. Rejected: `Arg` needs inheritance because it
  carries genuine per-instance state and identity (hash, equality-by-identity);
  a formatter is stateless logic over already-resolved data, so a plain
  proc type is enough and avoids inventing a base type with no state to
  justify it.
- **`genHelp` builds a richer intermediate model** (unjoined variant names,
  a per-row group name, structured rather than pre-joined annotations) and
  hands that to the formatter, instead of `Row`'s existing two plain
  strings. Rejected for now: nothing the Paragraph Style formatter needs is
  missing from `Row`, so a richer model is speculative generality for
  formatters that don't exist yet -- revisit if a real second consumer
  (e.g. a future styling formatter) actually needs more structure than
  `Row` carries.
