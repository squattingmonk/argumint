# A failed branch is ranked by how much input it understood, not by how many matchers it satisfied

Supersedes the "The named token comes from the deepest failed branch" section
of [ADR 0035](0035-parse-failure-reporting.md). Everything else in that ADR —
the suppression rules, the wording rules, did-you-mean, the single message
shape — still stands as written.

ADR 0035 made a failed parse name the token the user got wrong, and picked
*which* branch got to do the naming by comparing `ParseContext.depth`: the
number of matchers that branch satisfied. That is the wrong quantity. An
`Option` matcher scans the whole remaining token list rather than looking only
at position 0 (deliberate — option/positional order independence, ADR 0019), so
a usage line consisting only of options can skip *over* the token the user got
wrong, match something much later, and score a depth the branch that actually
understood the leading input cannot reach.

That branch then wins or ties the ranking while contributing no useful
complaint and a leftover full of correctly typed tokens. Every example below
was reproduced against the tree before this change (issue #40):

```console
$ naval_fate shp
  - unrecognized command: shp; did you mean ship?   # correct

$ naval_fate shp --help
  - unexpected argument: shp                        # the suggestion is gone

$ naval_fate ship mve -v
  - unexpected command: ship                        # ship is correct and matched
  - unrecognized command: mve; did you mean move?

$ naval_fate ship move a 1 2 --help
  - unexpected command: (ship | move)               # both correct
  - unexpected argument: a                          # correct
  - unexpected flag: --help                         # the only real complaint
```

The last is the clearest statement of it: the sole thing wrong with that
command line is that `--help` cannot follow `<name> <x> <y>`, and that
complaint is buried under two lines of tokens the user got right. The first is
the same defect wearing different clothes — `shp --help` loses its did-you-mean
because the surviving `missing command` complaint is what `finalComplaints`
consults to word a leftover as a mistyped *command* rather than a bare
positional, and the help line's depth discarded it.

## Decision

**Failed branches rank by Reach** (`CONTEXT.md`): the argv index of the first
token the branch could not consume, with a fully consumed token list ranking
highest. `depth`/`maxDepth` are deleted rather than kept alongside; they drove
nothing else.

A branch that skipped `ship mve` to grab `-v` satisfied one matcher but
understood none of the leading input, while the branch that consumed `ship`
and then failed on `mve` understood strictly more. Reach scores that
correctly and `depth` scores it backwards.

Note what Reach is **not**: it is not the furthest token the branch matched.
Because an `Option` matcher scans ahead, a branch can match a token at index 5
while its Reach stays 0 — it never accounted for index 0. Measuring the highest
index *touched* instead of the first index *missed* reproduces the bug it is
meant to fix, and was measured doing so: ranking by tokens consumed (the same
error in another guise) fixes exactly one of the cases above and regresses
seven, because inside the `ship` branch `ship (-h | --help)` consumes two
tokens where `ship (new | move | shoot)` consumes one, so the help line wins
the *inner* ranking and `missing command` dies before the top level ever
compares.

**Reach propagates across a nesting boundary.** A failed descent leaves the
parent's own token list where that transition's matcher left it, so a branch
whose child got five tokens further still measures as one token of progress
locally. Each transition's score is therefore the greater of its own Reach and
the best its descendants managed. Unlike `depth`, this is meaningful across
levels — Reach is a global argv index, so two branches at different nesting
depths are directly comparable. Without it, `<a> <b> zzz` / `<a> qqq` given
`1 2 3` ties both lines and reports `unrecognized command: (3 | 2)`, naming a
perfectly good `<b>`; with it, the deeper branch wins outright and reports
`unrecognized command: 3`.

**The running maximum still only ever rises**, for the reason ADR 0035 gives:
adopting a weaker branch's complaints because nothing has complained yet must
not lower the bar later siblings tie against.

### The tied-branch merge stays, on a new rationale

ADR 0035 justified the merge solely by FlagOp Alias exclusivity. **That
justification is void** (see below), but the mechanism is independently
load-bearing: it is what accumulates same-kind complaints onto one grouped
line. Removing it fails `an [options]-only flag is never reported missing` and
`same-kind alternatives are grouped onto one line joined by |` — a spec with
`--list` and `(-h | --help)` on separate usage lines stops reporting
`missing option: (--list | -h)`.

### A deliberate behavior change: FlagOp Alias exclusivity wording

`[--moored | --drifting]` given both used to report `unexpected flag:
(--drifting | --moored)`. It now reports **only the later token typed** —
`--moored --drifting` → `--drifting`, and `--drifting --moored` → `--moored`.

This is a fix, not a regression, and the old wording was never designed. Two
mutually-exclusive variants happened to satisfy one matcher each, so they
happened to tie on `depth`, so the merge happened to fire. Naming both means
naming a token the user typed correctly whenever the conflict is genuinely
"the first one is fine, the second one isn't" — which is half the cases:

| usage / args | old | new |
| --- | --- | --- |
| `[--moored \| --drifting]` + `--drifting 1 2 --moored` | `(--drifting \| --moored)` ← names the token typed **first** | `--moored` |
| `(--up \| --down) (--left \| --right)` + `--up --down --left` | `(--down \| --up)` ← names a correct token | `--down` |
| `[--aa \| --bb \| --cc]` + `--cc --bb --aa` | `(--cc \| --bb)` ← names the token typed **first** | `--bb` |

That is this issue's own symptom class occurring *inside* the exclusivity
feature. The first variant typed is consumed; the later one is the offender.

Naming only the **first** offender where several later tokens conflict is
intended: `[--aa | --bb | --cc]` given all three reports `--bb` alone. The user
fixes one thing and re-runs.

**[ADR 0026](0026-flag-op-alias-exclusivity.md) is not amended.** It governs
which tokens satisfy which grammar position; this is only how the resulting
failure is worded.

## Considered options

- **Keep `depth` and give `finalComplaints` a sticky set of tokens some
  `Command` matcher rejected at position 0**, consulted instead of the
  surviving `missing command` complaint. Fixes the lost did-you-mean and
  nothing else — it says nothing about which branch's leftover won, which is
  the other half of the defect and the whole of the `ship move a 1 2 --help`
  case. Rejected as treating a symptom.

- **Rank by tokens consumed.** Measured against the full case table and
  rejected; see above.

- **Merge when Reach ties *or* when the leftover count ties**, floated to keep
  the old exclusivity wording alive. It rescues only one of the two argument
  orders (`--drifting --moored` still collapses to `--moored`), and leftover
  count as the *primary* key is dead for the same reason tokens-consumed is.
  Rejected, and then made moot by treating the exclusivity wording as the
  defect it was.

## Consequences

- The escape hatch in the comparison (adopt a lesser branch when nothing has
  been recorded yet) is kept. It is unobservable under the whole suite either
  way, but it cannot distort the ranking — the running maximum is still taken
  with `max`, so a lesser branch's Reach never becomes the bar — and dropping
  it risks the degenerate bare `Parsing error:` above a usage block that ADR
  0035 rejected a suppression rule for producing.
- **A Short-Option Cluster is one Reach position, because a peeled remainder
  inherits its parent's `idx`** (ADR 0026). Branches that consumed different
  letters out of the same cluster therefore tie where `depth` separated them,
  and merge. Given `-a <z>` / `-b` and a typed `-ab`, the message gains a
  `missing option: (-b | -h)` line beside `missing argument: <z>` — `-b` was
  typed, just inside a cluster the grammar has nowhere to put. Accepted rather
  than fixed: the same spec improves in both un-clustered orders (`-a -b` drops
  a spurious `unexpected flag: -a`, `-b -a` narrows to it alone), and giving a
  remainder its own index would break the Flag Operation ordering that `idx`
  exists to serve.
- `naval_fate --help shp` still reports `unexpected argument: shp`, and that
  is correct. No positional metric reaches it: naval_fate's usage lines are
  mutually exclusive, so no parse holds both `--help` and a command, and a
  `Command` matcher never scans past position 0. Correcting the typo yields
  `naval_fate --help ship`, which fails too — a did-you-mean there would walk
  the user into a second error. Contrast `shp --help`, where the option sits
  *after* the command position and the corrected line works. Filed as #41 and
  closed as working as intended.
