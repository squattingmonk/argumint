# Rejected: Option Operations for multi-value Options

TODO.md and `OptionValueFormat`'s `optSep` capture (`fsm.nim`) had long
suggested a natural extension: give a multi-value Option (`opts*`) a
selectable accumulation operator per CLI token -- `^=` (prepend), `+=`
(append), `-=` (remove), `&=` (reset) -- mirroring Flag Operation. This was
designed in detail (including working code) and then deliberately backed
out. This ADR records why, so the idea isn't silently re-attempted without
first re-deriving the same gap.

## The gap: operators can break a Usage Line's own cardinality guarantee

A Usage Line can pin an Option to an exact count without `...`, e.g.
`--option=<value> --option=<value>` for "exactly two". Once an operator
can mutate the accumulated list independently of how many CLI tokens were
actually consumed, that guarantee breaks: `--option=foo --option-=foo`
satisfies both grammar positions but leaves zero stored values. It's not
only the shrinking operators, either -- `--option+=a --option+=b` against
a non-empty coded default first copies the default in as a baseline, so
two named positions can produce *three or more* stored values. Any
operator that can materialize a baseline or drop elements can desync
"number of explicit positions the grammar named" from "number of values
that end up stored."

The fix has to be "explicit operators are only valid where the position is
genuinely repeatable (`...`, or reachable only via the Options Catch-all)"
-- which means detecting that fact for a specific matched position isn't
optional, it's the whole feature.

## Why that detection isn't a small addition

"Repeatable" turns out to require real graph analysis, not a cheap check
in the runtime matcher:

- `Matcher`/`Arg` alone can't tell a `...`-repeated position apart from
  the same Arg simply named twice in one Usage Line with no repeat marker
  -- both look identical at that level. The difference only exists in the
  compiled `State`/`Transition` graph shape: a repeat produces a cycle
  (directly, or via `simplify()`'s shortcut-folding), a fixed count of
  mentions produces a strictly acyclic chain.
- Critically, the case this feature exists to serve -- pinning two or more
  multi-value Options to the same count via a repeated group, e.g.
  `(--tag=<t> --other=<v>)...`, so callers can rely on `tags.len ==
  others.len` -- produces a *multi-state* cycle, not a literal
  single-state self-loop. Detecting only the simple self-loop case would
  silently mis-handle exactly the scenario the feature is supposed to
  make safe, so a real reachability/SCC-style analysis over the whole
  compiled FSM is required, not a shortcut heuristic.
- That analysis has to run once per `Spec` (`prepare()`, after
  `simplify()`), storing a new `repeatable` bit on every `Transition`, and
  that bit then has to be threaded through `match`/`push`/`Match` down to
  wherever the operator is finally interpreted, so a specific *match* (not
  just an Arg, or a Usage Line in the abstract) can be checked against it.

## Decision: not worth the FSM surface area

This is a new field on `Transition`, a new whole-graph pass in `prepare()`,
and a new parameter threaded through `match`'s signature and every one of
its call sites and branches, all in `fsm.nim`/`backend.nim` -- the core
matching engine, not an isolated corner. That's a meaningful, permanent
increase in FSM complexity, for a feature whose most compelling use case
(cross-Option cardinality locking via a repeated group) is exactly the
case that needs the most machinery to handle correctly. Rejected as not
worth it relative to that cost; multi-value Options keep their existing,
simple, always-append Match Accumulation rule.

## What was rolled back

The runtime `op`/`repeatable` plumbing this design added to
`fsm.nim`/`backend.nim`/`argumint.nim` was reverted in full. Additionally,
`OptionValueFormat`'s operator-prefix alternation (`^`/`+`/`-`/`&` before
`=`/`:`) -- which predated this design attempt and was the thing that
originally tempted it, tokenizing into `CmdLineToken.optSep` but never
consumed downstream -- has been removed too, leaving `OptionValueFormat`
recognizing only a plain `=`/`:` separator. A CLI token like
`--option^=value` is no longer silently accepted with the `^` discarded;
it now falls through to whatever handling an unrecognized token shape
already gets (an unexpected-argument error, or literal inclusion in a
folded short-option value), rather than inviting a half-implemented
operator syntax to sit dormant in the tokenizer again.

If this is revisited, the reachability/SCC analysis over `Transition`
outlined above is the way to make it correct -- not a self-loop-only
shortcut, which would look correct in testing while silently mishandling
the repeated-group case that matters most.
