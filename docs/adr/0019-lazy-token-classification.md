# Lazy, walk-time token classification replaces eager `tokenizeArgs`

`fsm.nim`'s runtime matching split into two decoupled phases:
`tokenizeArgs` classified the *entire* remaining command-line array into a
`seq[CmdLineToken]` (`Command`/`Optional`/`Flag`/`Positional`) in one
eager, greedy, non-backtracking pass, entirely before `walk`/`match` ever
ran; only then did the FSM walk (which does backtrack, trying different
Usage Line alternatives) consult the already-fixed token list.

This was a deliberate choice, made to avoid the cost of a design like
[mow.cli](https://github.com/jawher/mow.cli)'s, where every `Matcher.Match`
call re-derives its answer from the live remaining args on every
backtrack attempt. It works well for the common case, but because
`tokenizeArgs` commits to one *global* classification per raw token using
only spec-wide flat lookups (`spec.commands`/`spec.options` membership)
and lexical shape — with zero awareness of *where* in the compiled Usage
Line graph a walk will eventually be, even though that graph (built by
`parser.nim`, which validates every Command/Option/Argument name against
the spec's tables at usage-string *parse* time) is fully precise about
what's valid at each exact grammar position — the classification pass
ends up being a second, cruder, earlier source of truth that the FSM can
never override once it's run. This produced three real, traced-through
problems:

1. A word that's a declared Command name could never be used as a plain
   positional value in a different Usage Line of the same Spec —
   `tokenizeArgs` checked `args[pos] in spec.commands` unconditionally and
   recursed/returned immediately, so an alternative Usage Line offering a
   plain `<arg>` at that position never got a chance to be tried.
2. The negative-number/dash-value gotcha (a leading space, `" -1"`, was
   required to pass a negative number as a positional value) existed
   because `tokenizeArgs` classified by lexical shape alone before any
   walk happened, with no way to know the grammar wanted a typed
   positional value here that would happily accept `-1` literally.
3. An unrecognized option-shaped token raised `ParseError` immediately,
   even when a different, not-yet-tried Usage Line alternative would have
   accepted it as opaque literal text.

This surfaced while workshopping an unrelated, smaller idea — a
usage-string `--`/end-of-options marker for a Config Source CLI-bootstrap
use case, mow.cli-style — which turned out to hit this exact root cause.
See "Out of scope" below.

## Decision

Move token classification from `tokenizeArgs` (eager, upfront, one pass
over the whole array) into `match` (lazy, walk-time, decided per
transition attempt), while keeping *pure string-shape* recognition eager.

1. **What stays eager**: recognizing that a raw token *has* option-like
   syntax (`-o`, `--opt`, `-o=val`, `--opt=val`, a `-xyz`-shaped cluster
   candidate) or is a literal `--`. This needs no `Spec` knowledge at all —
   there's no case where a Usage Line alternative should ever want
   `-o=val`'s literal three characters (`=`, `o`, `val`) treated as
   anything other than attached-value option syntax.
2. **What becomes lazy**: everything requiring a `spec.commands`/
   `spec.options` lookup — cluster-splitting (which letter a value folds
   onto), attached-name validation, and the Command/Option/Flag/Positional
   *kind* decision itself. This is a correction from this project's own
   first draft of the idea: cluster-splitting and name validation both
   need to know *which Spec's* tables govern this position, and that
   depends on which Commands the walk has already crossed on this
   specific path — a walk-time fact (`pc.spec`, already updated by
   `match`'s `Command` branch), not knowable upfront. So the eager/lazy
   boundary is drawn at "does this need a `Spec` lookup," not at "is this
   the Command/Option/Positional decision" — the two turned out not to be
   the same line.
3. **Why this doesn't need a new cache**: `ParseContext` is a plain value
   `object`, not a `ref`; `walk`'s `var fresh = pc` at every branch point
   is already a full independent copy, so a classification decision made
   inline during one attempt is discarded for free if that attempt fails,
   and a different attempt revisiting the same raw position starts from
   its own copy and reclassifies independently. This is the same mechanism
   that already makes backtracking cheap today — it's what makes lazy
   classification safe to add without also adding memoization
   infrastructure.
4. **Error reporting**: `walk`'s existing end-of-search "unexpected
   argument/option/command/flag" complaint (previously read off a
   precommitted token kind) now derives its wording from the same
   best-effort signals available after the fact (does the shape resolve
   against `pc.spec.options`/`pc.spec.commands`, or not) — an unresolved
   option-shaped token surfaces here, at the same point every other kind
   of match failure already goes through, instead of raising a special
   early exception from inside classification. The did-you-mean
   suggestion `tokenizeArgs` used to attach when raising now lives beside
   `match`'s own pre-existing "missing option" complaint in the `Option`
   branch, since that's the only point that still runs for a spec with no
   Argument/`[options]` catch-all fallback to defer to (a plain choice of
   individually-named options, e.g. `(-h | --help)`, never reaches
   `walk`'s "leftover token" complaint at all — the `Option` matcher
   itself just fails outright for each alternative).
5. **The leading-space escape hatch for negative numbers is kept**, not
   removed — it becomes unnecessary for the plain case this fixes, but
   stays available to force a literal interpretation at a position where
   a real Option genuinely does compete with an Argument for the same
   token.
6. **A Command-classified token is accepted by `Argument` as literal text,
   the same as a Positional one, rather than hard-stopping the scan** —
   another correction found during implementation, not anticipated by the
   original design. The pre-existing `Argument`/`Option` matchers'
   "skip past irrelevant tokens" scans used to `break` outright on a
   Command-kind token (a leftover invariant from the days when
   `tokenizeArgs` had already committed that token to Command,
   permanently, for the whole parse — the `break` was load-bearing then
   because *nothing* could later reinterpret it). Under lazy
   classification that assumption no longer holds: whether a
   Command-shaped word "belongs" to some other transition is exactly the
   fact gap 1 says can't be known in advance, and since a real Command
   matcher only ever looks at position 0 (ADR 0010), a Command-shaped
   token can never be legitimately claimed by a transition further down
   the scan either — there's nothing to defer to by stopping. The scan
   still must not skip *past* a Command-classified token in search of a
   later Positional, though: doing so would consume a repeating
   `<file>...`-style self-loop's values out of the order they were typed
   in (`["ship", "bar"]` would yield `bar` before `ship`). So the scan
   stops the instant it sees one (only Optional/Flag-classified tokens are
   skipped past, same as before) and accepts it as literal text right
   there — the `argVal`/`consumed`/`remainder` shape `consume` reads is
   identical between a `Positional` and a `Command` classification of the
   same raw token, and the scan can only ever reach one or the other,
   never both, in a single call, so there's no remaining behavioral
   difference to keep them as separate cases for. `match`'s `Argument`
   branch handles `of Positional, Command:` as one arm.
7. **Error-context bookkeeping had to be decoupled from live matching
   state** — `walk`'s pre-existing merge step, which records the deepest
   failed branch's `spec`/`command` for the final error message, used to
   write directly into the same `ParseContext.spec`/`.command` fields the
   *next* sibling transition attempt starts its own fresh copy from. This
   was harmless before (gap 1 made "a failed Command descent, followed by
   a sibling Argument attempt on the same leftover token" unreachable),
   but fixing gap 1 makes it reachable — and without decoupling, the
   sibling attempt would silently classify against the wrong (too-deep)
   spec and, worse, tag its match with the wrong spec in `MatchTable`, so
   the value it set would never be picked up. `ParseContext` gained
   dedicated `errorSpec`/`errorCommand` fields, written only by this merge
   step and read only when formatting the final failure message; `.spec`/
   `.command` now stay reserved for live walk state, untouched by a
   sibling's failure.

## Out of scope

A usage-string-level `--`/`[--]` marker (mow.cli-style: `--config=<file>
-- <arg>...`, forcing the split without the user needing to type a literal
`--`, and letting `--help` document the convention) is not part of this
change. It's a natural, now-cheaper follow-up once classification is
walk-time-aware — no longer blocked by the eager-tokenization
chicken-and-egg problem this change removes — but it needs its own
lexer/parser grammar design and wasn't the goal here. The `--config`
CLI-bootstrap use case that originally motivated this thread already works
today with zero changes, using a literal `--` typed on the command line.

## Consequences

- `CmdLineToken` (a precommitted `kind: ArgKind` per token) is replaced by
  a token carrying only the raw string plus eagerly-detected shape facts;
  `ParseContext.tokens`'s element type changes accordingly, and
  `ParseContext` gains a per-path `optsEnd: bool`.
- `tokenizeArgs` shrinks substantially: it no longer touches
  `spec.commands`/`spec.options` at all, and never raises `ParseError` —
  every failure that used to be a tokenization-time exception is now a
  walk-time "no transition matched" outcome, reported the same way every
  other match failure already is.
- `match`'s `Command`/`Option`/`Options`/`Argument` branches gain the
  classification logic `tokenizeArgs` used to own; the "scan forward past
  irrelevant tokens" search shape they already had is unchanged.
- Shell completion (`collectFrontier`/`candidateWords`) reads from the
  same `pc.tokens`/classification path, so it keeps needing no special
  case to stay in sync with real parsing (ADR 0012's own invariant).
