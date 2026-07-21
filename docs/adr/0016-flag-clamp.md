# Flag Clamp is a new mechanism, not a Validator extension

`flag[int]("-v, --verbose, --quiet=0, --boost+=5, --dampen-=2", ...)`
(`examples/verbosity.nim`) let a Flag's shared value drift to any `int`
forever. We wanted authors to be able to pin it to a range (e.g. `0..10`)
without every caller re-checking bounds, and to do so *silently* — no
exception on an out-of-range result, just a corrected value.

The obvious first instinct — reuse `Validator[T]` — doesn't fit, for two
independent reasons, either one of which would be enough on its own:

1. Every `Validator` kind's failure mode is to *raise* `ValidationError`.
   There's no "transform the value instead" mode anywhere in that
   abstraction, and adding one would change what `Validator` fundamentally
   *is* for every existing caller, not just this one.
2. `Validator` already never applies to a Flag (`CONTEXT.md`) — a Flag's
   value comes from author-declared Flag Operations, not arbitrary
   user-typed text passed through a converter. `flag*()` doesn't even take
   a `validator` param.

So this is a new, Flag-specific type, `FlagClamp[T]` (`argumint/
flagclamp.nim`), attached via `flag*()`'s new `clamp` param, applied by
`defineFlagArg`'s generated `parse*`/`setFromEnv*` immediately after every
`self.value.handleFlag(op, arg)` call — CLI- and env-triggered Flag
Operations alike, since both already funnel through the same call.

## Two constructors, not one

`FlagClamp[T]` is built via `clamp[T](bounds: Slice[T], desc = "")` (the
common case — pins to nearest bound, requires `T` to support `<`) or
`adjust[T](proc: proc(v: T): T, desc = "")` (a general escape hatch for any
`T`). Both were kept because neither alone covers the space:

- A pure `range[T]`-typed-value approach (let the Nim type system enforce
  the bound directly, e.g. `flag[range[0..10]](...)`) was considered and
  rejected. It fails *loud*, not silently — `RangeDefect` on an
  out-of-range assignment, not saturation at the boundary — which is the
  opposite of what was asked for. Worse, that `RangeDefect` would be
  triggered by ordinary user input (repeatedly typing `--boost`), and this
  codebase deliberately reserves `Defect` for developer-authored spec
  mistakes (`SpecDefect`) and `CatchableError` for anything a user's input
  can trigger (`ParseError`/`ValidationError`/`MessageError`) — a
  user-triggered `Defect` would be a new, unprecedented category mismatch.
  It also wouldn't have saved any implementation work: `flagOps` is keyed
  by exact type name, so every distinct bound (`range[0..10]`,
  `range[0..20]`, ...) would need its own `defineFlag` registration with
  hand-written saturating arithmetic anyway.
- A general `adjust`-only mechanism (no `clamp` sugar) was considered and
  rejected as pushing boilerplate onto the common case — most callers just
  want a numeric range, and the motivating example (`0..10`) is exactly
  that case.
- `clamp`-only (no `adjust` escape hatch) was considered and rejected
  because `<`-based bounds are meaningless for a type like `set[E]`, whose
  natural `<` is subset inclusion — a *partial* order, not a total one.
  Two incomparable sets are neither "less than" nor "greater than" each
  other, so pin-to-nearest-bound logic built on `<`/`>` alone silently does
  the wrong thing there. `adjust` lets the author of a `set[E]`-backed flag
  define whatever "constrain" means for their own type instead of the
  library imposing one.

The range constructor is not named `range` — confirmed via a scratch
compile, not just style preference: `range*[T](range: Slice[T], desc =
""): Validator[T]` already exists in `validators.nim`, and `argumint.nim`
imports both modules together. Two generic procs with identical argument
shapes but different return types produce an ambiguous-call compile error
in Nim; it doesn't disambiguate by the caller's expected result type here.

It's named simply `clamp` instead — confirmed via a scratch compile that
this doesn't collide with `system.clamp[T](x, a, b: T)` (always in scope —
it's in `system`, auto-imported everywhere) or `std/math.clamp[T](val: T,
bounds: Slice[T])` (in scope only if a caller imports `std/math`
themselves). Neither collides: both take a bare value as their required
first argument, a different shape from `argumint/flagclamp`'s
`clamp(bounds: Slice[T], desc = "")`, whose first argument is the
`Slice[T]` itself — Nim's overload resolution filters on argument
count/type before it would ever reach an ambiguity, so a call like
`clamp(0..10)` only ever matches one candidate.

## Coded defaults raise `SpecDefect`, deliberately not mirroring ADR 0008

`docs/adr/0008-validators-dont-run-against-defaults.md` decided a
`ValueArg`'s coded default is never checked against its own `Validator`, to
let an author use an out-of-range sentinel/fallback value on purpose. Flag
Clamp does the opposite: an out-of-range default raises `SpecDefect`
immediately, at `flag()` call time.

This isn't an oversight of that precedent, it's because the precedent's
premise doesn't hold here. A `ValueArg`'s default lives in a genuine
substitution tier (`Option[seq[T]]`, substituted only if nothing else ever
set a value) that a sentinel can hide behind — real user input replaces the
sentinel outright, so the sentinel never participates in a computation.
`FlagArg.value: T` has no such tier: the coded default *is* the live
initial value from construction on, and Flag Operations like `inc`/`+=`/
`-=` read the *current* value as an operand. An out-of-range "sentinel"
default wouldn't be inert the way `ValueArg`'s is — it would be an input to
the first real operation's result, and since clamp only ever runs on an
operation's *result*, not on the seed itself, the first operation's visible
delta could be far larger than what it claims (e.g. `default = 15,
clamp = 0..10`: `--verbose`'s `inc` computes `15.inc == 16`, then clamps to
`10` — an "increment" that visibly decreases the value by 5). Rejecting the
bad default outright avoids designing around that surprise.

## Consequences

- A Flag's coded default and its clamp must agree, full stop — there's no
  sentinel-default escape hatch for Flags the way there is for
  `ValueArg`/`Validator`.
- `FlagArg[T]` now has a `validatorHelp*` override (reusing the same
  extension point `ValueArg`'s `Validator` uses for its own help-text
  annotation) even though a Flag never carries an actual `Validator` — an
  internal-only naming tension, not part of the public API. It delegates to
  `FlagClamp[T].help()`, which keeps the same name as
  `validators.help[T](self: Validator[T])` on purpose: unlike `range`, this
  doesn't collide, since the two take different concrete parameter types
  (`FlagClamp[T]` vs `Validator[T]`) and Nim filters candidates by argument
  type before return type would ever come into play — confirmed via scratch
  compile.
- Building `FlagClamp` surfaced a broader, pre-existing gap in how
  `argumint.nim` exposes itself to callers registering their own custom
  Arg types (not specific to `FlagClamp`) — see
  `docs/adr/0017-argumint-reexports-for-custom-arg-types.md`.
