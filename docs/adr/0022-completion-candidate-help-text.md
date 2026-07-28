# Shell completion candidates carry help text; fish and zsh render it, bash doesn't

`docs/adr/0012-fsm-driven-shell-completion.md` shipped dynamic completion
with bare-word candidates only, even though every `Arg` already carries a
`.help` string used elsewhere for `genHelp()`. Requested: surface that same
text inline when TAB-completing, the way many other CLIs' completions do.

## Decision: `CompletionCandidate = tuple[value, help: string]`, rendered by fish and zsh, not bash

`fsm.completeArgs*` now returns `seq[CompletionCandidate]` instead of
`seq[string]`. `value` is the literal word offered; `help` is a short
description, attached only where the candidate *is* an Arg's own name
(option/flag/command), never for an enumerated *value* of one -- see
"Value candidates stay description-less" below.

Only fish and zsh render `help` in their own completion menu. Bash's stock
`complete`/`COMPREPLY`/`compgen` mechanism has no per-candidate description
slot at all -- unlike zsh's `compadd -d`/`_describe` or fish's native
`value\tdescription` line convention, there's no equivalent bash primitive
to target. This isn't a rejected alternative so much as a capability bash
genuinely doesn't have; its generated adapter script keeps completing bare
words, unchanged from ADR 0012.

## Wire format: one `"value\thelp"` line per candidate

The `__complete` interception in `fsm.parse*` joins candidates into
`CompletionError.msg` as one line per candidate, each formatted
`"{value}\t{help}"`. `help` may be empty, but the tab is always present, so
every adapter script can split each line on the *first* tab
unconditionally rather than branching on whether a tab exists at all.

Accepted limitation, consistent with this codebase's existing style of
documenting rather than defending against unlikely author input (see e.g.
ADR 0012's own accepted tradeoffs): help text containing a literal tab or
newline would corrupt the wire format. Not validated against.

## Resolved implementation questions

- **Per-variant vs. whole-arg description**: a flag can have genuinely
  divergent per-variant behavior (`variantHelp` passed to `flag*`, e.g.
  `-i`/`-d` meaning "Increase by 5"/"Decrease by 2") on top of its own
  shared `.help`. `Arg.variantDesc(variant)` (`backend.nim`) already exists
  for exactly this distinction, used by `genHelp`'s `variantGroups`
  grouping. Naively preferring `variantDesc` whenever it's non-empty is
  wrong, though: every `FlagArg`'s `variantDesc` base case returns a
  non-empty auto-generated description even for an *ordinary*, non-
  divergent flag (e.g. a bare bool flag's blank-op variant returns "Toggle
  the value") -- which would silently shadow that flag's own `help` for
  every completion candidate, never showing what the author actually wrote.
  `fsm.describeVariants` fixes this by mirroring `variantGroups`'s own
  "collapse to one group whenever every variant agrees" rule: it computes
  `variantDesc` for every one of an Arg's variants first, and only trusts a
  per-variant `variantDesc` when at least two of them genuinely differ;
  otherwise every variant falls back to the Arg's shared `.help`. This
  keeps completion's notion of "does this variant need its own
  description" in agreement with what `genHelp` would actually print.
- **Value candidates stay description-less**: a Choice validator's own
  values (`--log-level=<TAB>` -> `debug info warn error`) have no per-value
  description in the data model -- only the parent option's whole-arg
  `.help` ("Logging verbosity") exists. Considered and rejected: repeating
  that same option-level text on every value candidate. It doesn't
  distinguish `debug` from `info` and reads as noise in the completion
  menu, so an `Argument`-kind or pending-option-value candidate's `help` is
  always `""`.
- **Dedup keys on `.value` only**: `candidateWords`'s and the pending-value
  loop's existing first-seen-wins dedup (ADR 0012) switched from scanning
  `seq[string]` membership to a `HashSet[string]` of seen values, since a
  `CompletionCandidate` tuple can no longer be compared for "already
  offered" via plain equality against the accumulated result the way a bare
  string could.
- **bash strips descriptions before `compgen`**: the generated bash script
  now pipes `__complete`'s output through `cut -f1` before building the
  `compgen -W` word list, rather than passing tab-containing lines straight
  through (which would corrupt `compgen`'s whitespace-split word list).
  Output/UX is otherwise unchanged from ADR 0012.
- **zsh splits into parallel arrays**: the generated zsh script splits each
  output line into `candidates`/`descriptions` arrays via zsh parameter
  expansion (`${line%%$'\t'*}` / `${line#*$'\t'}`) and calls `compadd -d
  descriptions -a candidates` instead of the old bare `compadd -a
  candidates`. `_describe`'s colon-joined `"word:description"` array
  convention was considered and rejected in favor of parallel arrays, since
  a description string containing a literal colon would otherwise need
  escaping that `compadd -d`/`-a`'s separate-array form avoids entirely.
- **fish needed almost no adapter change**: fish's own `complete -c foo -a
  '(...)'` already treats a `value\tdescription` line from the function's
  stdout as candidate+description natively, and `__complete`'s output is
  already in exactly that shape -- the ordinary "what word comes next"
  branch passes it straight through, unchanged. Only the pre-existing
  `=`/`:`-split branch (mid-option-value completion, e.g. `--opt=<TAB>`,
  needed because fish never splits an `=`/`:`-joined option+value into two
  words on its own) needed updating: it used to re-prepend `$prefix` to the
  *whole* candidate line, which would have corrupted the tab-separated
  format the moment a value candidate ever gained a non-empty `help` (it
  doesn't today, per the value-candidate decision above, but the fix is
  correct either way). It now splits each line on the first tab, prepends
  `$prefix` to the value half only, and re-appends `\t<desc>` only if
  non-empty.
