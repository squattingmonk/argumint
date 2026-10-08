# `accept` is the override point; `parse` arbitrates for every Arg

> **Note (#213):** `ValueArg` no longer overrides `accept` with a generated
> method: the base `accept` calls through the `ValueOps` table
> `initValueArg` gives it (ADR 0068). A custom `Arg` subtype has none, and
> still overrides `accept` as described here.

`Arg.parse(value, variant, seenBy)` was two things at once: the public
write surface (ADR 0041) and the method a custom `Arg` overrode to store a
value. Both halves had a cost.

The `variant` slot meant something different to each caller:

| Caller | `value` | `variant` |
|---|---|---|
| CLI option | typed value | typed spelling |
| CLI flag | Variant name | Variant name |
| env / Config Source | env or config value | `PORT` or `a.b.c` (a source label) |
| `put` | typed value | `""` |

`FlagArg.parse` renamed its parameters to `variantValue`/`variantName` to
cope, `subject` looked at `seenBy` to work out whether the slot held a
Variant or a label, and `precedence.sourceLabel` existed only to fill it.
The overloading misled ADR 0041 itself: its write-surface table, and
`docs/architecture.md`, gave `flag.parse("", "-v")` as the way to apply a
Flag Operation. That call has always raised `"" is not a known variant`.
The lookup key is the value slot, so the working spelling is
`flag.parse("-v")`.

And every override had to arbitrate by hand, calling `arbitrate` (the
`arbitration` proc since #144) before storing. Nothing enforced it. An
override that forgot would demote, or accumulate across tiers, and neither
raises.

## Decision

```nim
type Contribution* = object
  value*: string          # the raw string; for a Flag, the Variant name
  variant*: string        # the Variant typed on the command line; "" otherwise
  tier*: Option[SeenBy]   # none = extend at the current tier

type Arbitration* = enum
  arExtend, arReplace

method accept*(self: Arg, c: Contribution, how: Arbitration) {.base.}
proc parse*(self: Arg, value: string, variant = "",
            seenBy = none(SeenBy))
```

- **`parse` is a proc, not a method.** It asks `arbitration` and returns on
  a refusal. Otherwise it calls `accept` and, on `arReplace`, records the
  tier. Its signature is unchanged, so no caller breaks.
- **`accept` is the one override point.** It converts, checks against the
  history `how` implies (the stored values on `arExtend`, none on
  `arReplace`), calls `clear` on `arReplace`, and stores. The checks come
  first, so a value that fails leaves the Arg untouched. The base version
  only clears, which is all a Command or Message Argument needs.
- **A Contribution carries no source label.** `subject(arg, c)` reads
  `arg.envName` or `arg.configKey` for the claimed tier (ADR 0046 made
  both readable). `sourceLabel` is gone, and the fallback tiers call
  `arg.parse(v, seenBy = some(tier))` like any other writer.
- **For a Flag, `value` is the Variant name on every tier.**
- `accept`, `Contribution` and `Arbitration` are exported from the facade.
  `arbitration` stays withheld: nothing outside the library needs it.

## Considered options

- **Keep `parse` overridable and pass it a Contribution.** Fixes the
  overloaded slot but leaves every override to arbitrate by hand.
- **A `bool` for `replacing`.** It reads as `accept(c, true)` at a call
  site. The two-member enum names the outcome and makes the override's
  `case` exhaustive. A refused tier never reaches `accept`, so it needs no
  member.
- **Two methods, one per outcome.** They'd share nearly all their code, a
  custom Arg would have to implement both, and they could disagree — the
  shape ADR 0046 removed for `envName`/`envDelim`.
- **`accept` returns a closure that stores, so `parse` clears between.**
  The override would have no tier duties at all, at the cost of a closure
  per value and an unusual contract. Clearing on `arReplace` is one line,
  and a test catches it.
- **Check and store as two methods, `parse` clearing between.** No duty
  left either, but `store` must convert the string again, since a
  non-generic method can't hand a `T` to another.
- **Store the source label in the Contribution.** One more field holding
  what the Arg and the tier already determine, and a hand-written call
  could set one that contradicts its tier.

## Consequences

- **Breaking for a custom `Arg` that overrode `parse`.** It overrides
  `accept` instead. A leftover `method parse` still compiles, with Nim's
  `UseBase` warning, but the library never dispatches to it. Taken before
  1.0 for the same reason as ADR 0046.
- **A write that declares a fallback tier names that tier's source.**
  `port.parse("x", seenBy = some(byEnv))` now fails with `--port (env:
  PORT)`, where it used to name `--port=<n>`. The caller claimed the tier,
  so the error says where such a value comes from. A write declaring no
  tier, or `byCli`, names the Arg as before.
- **A write refused as weaker is never checked.** `parse` arbitrates
  before `accept` converts, so `port.parse("x", seenBy = some(byEnv))` on an
  Arg already at `byCli` raises nothing, where it used to raise `expected
  int`. The same goes for an unknown Flag Variant. Nothing is applied either
  way (ADR 0041's "refuse; apply nothing"), and a real parse never reaches
  it: the fallback sweep skips an Arg already above its tier. Checking first
  would put conversion back ahead of arbitration in every `accept`.
- **Clearing on `arReplace` stays the override's one duty.** It has to come
  after the checks and before the store, which only `accept` can order. An
  override that forgets it accumulates across tiers rather than replacing;
  the `CustomArg` tests in `tests/test_write_side.nim` show the one line it
  takes.
- **The fallback error labels are tested**, which they weren't: env, env
  for a Flag's unknown Variant, and Config Key.
- ADR 0041 (the override point and the Flag spelling) and ADR 0046 (the
  custom-`Arg` contract) carry pointers here.
