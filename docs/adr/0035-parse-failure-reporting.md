# A failed parse names the token the user got wrong

Builds on `docs/adr/0034-strict-option-checking.md`, which added the first
Complaint that names a token.

`walk` (`src/argumint/fsm.nim`) accumulated a set of Complaints as it
backtracked and printed whatever survived. What survived was mostly the
FSM's own bookkeeping. Every example below was reproduced against the tree
before this change.

**`missing option` reported options that were not missing.** The line led
essentially every failure message, drawing from three populations, none of
them user-actionable:

```
app --port            (usage "[options]")
  - missing option: ( -h            <- explicit, but in a DIFFERENT usage line
                    | --port=<n>    <- reached only via the [options] catch-all
                    | -v )          <- likewise

app --port 9090       (usage "[options] add", add missing)
  - missing option: --port=<n>      <- supplied, well-formed, in range
  - missing command: add
```

Supplying `--port` *narrowed* that last complaint from `(-h | --port=<n>)`
to `--port=<n>`, which gives the game away: the line tracked which options
the walk had left to try on the branch it died on.

**The offending token was never named.** A typo'd command and a stray
positional both vanished from the message entirely:

```
naval_fate shp move a 1 2          app stray          (usage "[options]")
  - missing option: (-h | -v)        - missing option: (-h | --port=<n> | -v)
  - missing command: (ship | mine)
```

The machinery to name a leftover token existed and worked — `[options]
<file>` given `a b` correctly said `unexpected argument: b` — but it was
reachable only from a transition that had *succeeded* into a terminal next
state. When every transition at the failing position failed, nothing
reached it.

**A naming complaint could name a token the user got right.**

```
usage "[options]", args ["-v", "stray"]
  - missing option: (--port=<n> | -v)
  - unexpected flag: -v            <- -v was supplied and matched correctly
```

**did-you-mean fired inconsistently.** Suggestions came from plain
Levenshtein at distance exactly 1, so every transposition missed:

```
--prot   (none)      --porrt  --port
--hepl   (none)      --por    --port
```

Only one candidate was ever offered, chosen by whichever the option table
iterated first (`--fort` ties `--port` and `--sort`). A length guard on both
the typed token and the candidate excluded short options entirely — the
right instinct, but drawn on the full dashed spelling, so it also caught
things it shouldn't have.

**`ParseError.msg` had two incompatible shapes.** A grammar failure's
message began with a newline and carried a usage block; a conversion or
validation failure was a bare sentence with neither. `parseOrQuit*` rendered
both through one template, so the first printed a trailing space and a blank
line after `Parsing error:` and the second did not.

## Decision

### `Complaint` grows a `names` field

A Complaint records whether it points at a specific token the user typed (a
**Naming Complaint**) as opposed to naming something the grammar wanted.
It is a property of the Complaint, deliberately **not** a test on its
wording: ADR 0034's starved-option complaint (`option --port requires a
value`) names a token and has to participate in the suppression rules
below, and a string-prefix test on `unrecognized`/`unexpected` would miss
it. That ADR's requirement — that a starved option and an unrecognized
token both appear rather than one masking the other — depends on this.

### Two rules suppress `missing option`

> **Extended by [ADR 0037](0037-missing-argument-only-where-required.md)**:
> the rules below stay exactly as written, but they scope to `missing
> option` only because this ADR's brief said so. `missing argument` is now
> suppressed too — on unrelated grounds, never rule 2's, but whenever the
> grammar could have stopped where the positional went unfilled.

1. An option reached through the Options Catch-all is never complained
   about. It is optional by construction, so it can never be the thing the
   user had to supply. (`Options` matcher: the catch-all already rolled each
   failed probe's own messages back; now nothing takes their place.)
2. Any surviving `missing option` is dropped when the message contains at
   least one Naming Complaint. When every Complaint is a `missing …`, all
   are kept.

Between them these cover all three populations above, including the
supplied-`--port` case: it is reached through the catch-all, so rule 1
retires it and `app --port 9090` against `[options] add` reports only
`missing command: add`.

**A third rule — "an option already in `MatchTable` on this branch is never
complained about" — was tried and reverted.** `MatchTable` is keyed by
`Arg`, so membership answers "did this Arg match at all on this branch",
which is not the same question as "did the user supply everything the
grammar asked for". Given `--foo=<v> --foo=<v>` and a command line of
`--foo a`, the first position matches, the second correctly complains, and
the membership test suppresses that complaint — leaving the Complaint list
*empty* and the user with a bare `Parsing error:` above a usage block. The
information needed to tell one occurrence from two lives in the grammar,
not in the match table, and is not available at the complaint site.

**A graph-level "is this option required" bit was considered and
rejected** for the same family of reasons. It does not fix the most visible
case — `-h` and `-v` in the `naval_fate shp` example are unbracketed inside
their own Usage Lines, so a requiredness test keeps them — and it would push
the change down into FSM construction for no gain.

`missing command` is dropped on the narrower condition that the named token
stands in the command's own position. The valid set stays visible in the
usage block below, so repeating it as a complaint adds nothing.

### Wording comes from the grammar's expectation, not the token's shape

`shp` is lexically a positional. Calling it an `unexpected argument`
describes what it looks like instead of what the user got wrong, so the
same token is worded differently depending on where the grammar wanted it:

```
naval_fate shp move a 1 2      ->  - unrecognized command: shp; did you mean ship?
app stray  (usage "[options]") ->  - unexpected argument: stray
```

Extending the existing shape-derived complaint was the cheaper option and
was rejected on message quality.

This is why leftover tokens are *recorded* during the walk (`Leftover`,
`ParseContext.errorTokens`) and *worded* afterwards, in `finalComplaints`:
the wording draws on the whole accumulated message ("a Command was expected
here"), which no single branch can see. `Leftover` keeps the branch's whole
remaining token list, not just the first token — `classify` looks ahead to
decide whether an Optional has a value, and a one-token slice would make
every leftover option look starved.

Three recording sites, because the grammar fails in three shapes:

- **A terminal state whose every transition failed**, at the tail of `walk`.
  This is the general case, and it replaces the old caller-side site that
  required a transition to have succeeded first.
- **A failed `Command` matcher.** A Command matcher never scans past
  position 0, so it is the one place that knows a Command was expected
  *here* — and it fires whether or not the grammar has a terminal state the
  leftover could ever reach, which is what makes a command-only spec (no
  `[options]` line) report a typo'd command at all.
- **A failed `Option` matcher** still holding an unresolved option-shaped
  token. Like the Command matcher it reports its own complaint and stops, so
  it never reaches `walk`'s tail; it is what names `unrecognized option:
  --nope` when a spec's only Usage Lines are option alternations.

### The named token comes from the deepest failed branch

> **Superseded by [ADR 0036](0036-rank-failed-branches-by-reach.md)**:
> branches now rank by Reach — how far into the input they got — rather than
> by `depth`, which counted matchers satisfied. `depth`/`maxDepth` are gone,
> the merge's justification below is void (it survives on a different one),
> and `[--moored | --drifting]` given both now names only the later token.
> The only-ever-rises rule stands, restated there against the new metric.

`ParseContext.maxDepth` was allowed to *fall* when a branch's complaints
were adopted because nothing had complained yet. Every later sibling then
tied against that lowered bar and merged in, which is how a branch that got
nowhere came to name `-v`. `maxDepth` now only ever rises.

**The tied-depth merge itself stays.** It is what surfaces both sides of a
FlagOp Alias exclusivity conflict, where two mutually-exclusive variants each
correctly complain about the other; leftovers merge on exactly the same
terms and for the same reason, so `[--moored | --drifting]` given both
still reports `unexpected flag: (--drifting | --moored)`.

### Damerau–Levenshtein, thresholded against the candidate

One rule serves options and commands alike. A candidate is offered when its
optimal-string-alignment Damerau–Levenshtein distance from the typed token
is within `min(2, max(1, n div 4))`, where `n` is the length of the
**candidate's** name with leading dashes stripped. Every candidate tied at
the best distance is offered, in sorted order so declaration order cannot
decide a tie; when none qualifies, the token is still named without a
suggestion.

Three parts of that are load-bearing:

- **Transposition costs 1.** Every miss in the table above is a
  transposition, which plain Levenshtein scores 2. A flat distance ≤ 2
  catches the same typos but starts offering unrelated names on short
  options (`--sort` for `--por`).
- **The cap.** Uncapped, `n div 4` offers semantically *inverted*
  suggestions: `--disable-experimental` for a typo'd
  `--enable-experimental`. The formula is a two-step function in practice —
  threshold 1 for bare names under 8 characters, 2 for 8 or more — written
  as a formula to express intent and to make the cap the tunable part, not
  because it scales smoothly.
- **Stripping the dashes before measuring.** Measuring the full spelling
  inflates every threshold, which produces `--sort` as a candidate for
  `--prot` and `--verbose` for `--verison`.

The distance function is hand-rolled: `std/editdistance` has no
transposition variant. It runs over `Rune`s, because that module's
byte-wise `editDistanceAscii` would compare halves of a multi-byte
character. (`OptionFormat`'s `\w` is ASCII-only, so a multi-byte token is
never option-shaped — but a Command name has no such restriction.)

**A candidate's bare name must be at least `MinSuggestable` (2) characters**
or it is never offered. `shortOption <- '-' \w` makes a short option's bare
name exactly one character and `longOption` makes a long one's at least two,
so this is precisely "a short option is never a suggestion" — the old
guard's intent, restated in the same dash-stripped terms as the threshold
and applied to the candidate only.

Without it, every one-character name is exactly one edit from every other,
so *any* unrecognized short option draws the entire short-option surface of
the spec:

```
$ app -j          (spec declares -h, -q, -v)
  - unrecognized option: -j; did you mean -h, -q or -v?
```

It is worse for a Short-Option Cluster remainder, which the user never
typed at all: `-1x` against a declared `-1` peels to a leftover `-x`, which
then draws suggestions including the numeric `-1` it was just peeled from.

**A long option is never offered in a short option's place either.** A
short-form token — exactly one leading dash — is cluster syntax, so the
thing that failed to resolve is a letter inside it, not the run as a whole.
`--ab` is not what `-ab` "meant"; at most `-a` is. Offering the long name
papers over a mis-parse with a plausible-looking guess.

The two rules compose into a single observable one: **a short-form token
never receives a suggestion at all**, since short candidates are excluded
from everything and long ones from short-form tokens. That is the intended
end state, not an accident of two filters — so the token-side half is
decided in `unknownOption`, before a candidate list is built, rather than
re-asked per candidate inside `didYouMean`. Eligibility is a property of
what the user typed; only the distance test is per candidate.

Nothing is lost by leaving the *floor* itself scoped to the candidate. A
one-character token is either one edit from a one-character candidate
(excluded) or far outside the threshold of any longer one. And the case that
motivated dropping the old guard — `--verbose` against a spec declaring only
`-v` — was never rescued by dropping it either, since `verbose` is six edits
from `v` and outside any threshold this scheme would set.

### One message shape

Every parse-time failure renders as a Complaint list followed by a usage
block. `formatComplaints` returns that list with **no leading newline** —
the caller owns the separation between its own prefix and the block — and
`parseOrQuit*` renders prefix and block unconditionally, with no branch on
message shape.

A conversion or validation failure becomes a single Complaint with an empty
`kind`, so it renders as a bare sentence under the same bullet:

```
Parsing error:
  - expected int for --port but got "abc"

Usage:
  app [options] add
```

`arg.parse` has no view of the Spec it belongs to, so the reshaping happens
in `parse*`, around `applyFallbacks` and `parseAllValues` — the two places
that convert values and do have one. `ValidationError` keeps its own type
and its own `parseOrQuit*` prefix; only the body's shape changes.

## Consequences

- Every message text in `README.md` changes, and so do the assertions in
  `tests/test_argumint.nim` and `tests/test_strict_options.nim` that pinned
  the old wording. `unrecognized option --nope` becomes `unrecognized
  option: --nope`, matching `unrecognized command:` and every other
  `kind: subject` line.
- A spec whose only Usage Lines are required and whose options are all
  explicitly named still reports `missing option` when nothing is named —
  `naval_fate` with no arguments still says `missing option: (-h | -v)`.
  Rule 2 has nothing to suppress against, and per the rejected requiredness
  bit above, that is deliberate.
- An embedder catching `ParseError` from `parse*` now receives a message
  that always carries a usage block, including for conversion failures.
  Whether such a caller should be able to ask for a short message without
  one is a public API question, left open.
