# Composable Validators: `all()` and `any()`, genuinely nestable

`TODO.md` originally scoped this as an AND-only combinator (`all()`),
explicitly deferring OR support ("AND-only for now, no OR"). During design
we decided to add both `all()` (AND) and `any()` (OR) together instead: an
AND-only combinator can't express meaningful nesting (`all(a, all(b, c))` is
just the flattened `all(a, b, c)` under AND alone), but once `any()` exists,
nesting the two genuinely composes richer conditions that can't be reduced
by flattening, e.g. `all(a, any(b, c))`.

Consequently, nested `all()`/`any()` validators are stored as real nested
`Validator[T]` nodes rather than being auto-flattened into their parent's
list, for two reasons: a mixed All/Any nest can't be flattened without
changing its meaning, and each node may carry its own optional `desc`
override, which flattening would silently discard.

Both kinds take the same optional trailing `desc` param (named to match
`check()`'s existing param and to avoid colliding with the `help()` proc),
and both use it identically on failure when it's given: the raised
`ValidationError` shows that text directly (`"{value} did not meet
condition: {desc}"`, matching `check()`'s existing wording), regardless of
which child(ren) actually failed. They differ only in what happens when
`desc` is *not* given:

- `all()` short-circuits left-to-right and passes the first failing
  child's own `ValidationError` message through verbatim -- it's already
  the most specific, sufficient reason on its own.
- `any()` has no single dispositive failing child -- the reason is "none
  of these passed" -- so it falls back to joining each child's own
  `help()` text with "or".

Default (non-overridden, i.e. no `desc` given) `help()` doc text follows
the same split: `all()` joins children with "and", `any()` with "or".
Either way, a child that is
itself a composite (`all`/`any`) node is parenthesized in the joined text
so nested AND/OR grouping in mixed trees reads unambiguously, e.g.
`(choices: a, b or range: 0..5) and must be even`.

## Considered options

- **AND-only** (the original TODO plan): rejected once nesting was on the
  table, since AND-only nesting is provably no more expressive than a flat
  list -- there was nothing to gain from allowing it, and disallowing it
  would need its own special-case code.
- **Auto-flatten same-kind nesting** (`all(a, all(b, c))` -> `all(a, b, c)`):
  rejected because it silently discards a nested node's own `desc`
  override, and because it doesn't generalize to mixed All/Any nests
  anyway -- better to have one rule (never flatten) than two.
- **Collecting all failing children's messages for `all()`**: rejected in
  favor of short-circuiting, to mirror ordinary boolean AND evaluation and
  keep the error message single-purpose when no `desc` override applies.
- **A single proc with `desc = ""`** (rather than two overloads, one with
  `desc: string` required and one `varargs`-only that delegates to it):
  not viable at all, not just stylistically rejected. Nim cannot resolve a
  call with more than one `varargs` element against an overload that also
  has a defaulted parameter following the `varargs` -- `all(a, b)` fails to
  compile against `proc all[T](validators: varargs[Validator[T]], desc =
  "")`, while `all(a, b, desc = "x")` and `all(a)` alone both compile fine.
  The two-overload split is the workaround, not a preference.
