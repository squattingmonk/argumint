# A Flag's env or config value may name a value, not just a Variant

Supersedes [ADR 0005](0005-env-supplied-multi-value-options-and-flags.md)'s
section "Flag env values are now Variant names, not raw values".

Since ADR 0005, each env or config value for a Flag had to spell one of the
Flag's own Variants (`VERBOSE=--verbose`), whose Flag Operation then ran.
That composes the way repeated command-line matches do, but it reads oddly
for a Flag whose ops set fixed values: with `--level2` declared as
`flagOp("--level2", "=", 2)`, `LEVEL=2` was rejected and `LEVEL=--level2`
was required. A `bool` Flag couldn't take `VERBOSE=true` (issue #330).

## Decision

1. **A value may name an op that sets it.** An env or config value for a
   Flag is a Variant spelling, as before, or a value one of the Flag's
   Flag Operations sets. Only two kinds of op have such a value:
   - a named `=` op, from `flagOp(…, "=", v)` or `--x=v` in the string form
     of `ops`;
   - a `bool`'s Implicit Operation, which matches `not default` and runs,
     and also matches `default`, which sets the Flag to its default. With
     `default = false`, both `VERBOSE=true` and `VERBOSE=false` work.

   `+=`, `-=`, `*=`, procs and the integer and enum Implicit Operations are
   relative or opaque, so they never match a value.
2. **A Variant is tried first, then a value.** Every input accepted before
   keeps its meaning, and a command-line Contribution, which always carries
   a Variant, is unchanged. There is no opt-in.
3. **A value is read as an `opt[T]` would read it** and compared with `==`.
   A Flag whose `T` can't do both (a `set[E]`, which has no whole-set
   conversion) matches only by Variant, with no `SpecDefect`. Whether `T`
   can is decided where the Flag is built, so the user's converter is
   found (`docs/gotchas.md`).
4. **A match runs that op**, so a Flag Clamp, Arbitration and Match
   Accumulation are unchanged. Each value of a multi-value input resolves
   on its own, in order: with `--boost` as `+= 5` and `--level2` as `= 2`,
   `VERBOSE=2:--boost` gives `7`. Of two `=` ops that set the same value,
   the first declared wins.
5. **Resolution is in `FlagArgBase.accept`**, so it covers every tier.
6. **An unmatched value** raises `ConversionError`, `"3" is not a known
   variant or value for the flag --level (env: LEVEL)`, without listing the
   accepted values. An option-shaped one (a leading `-`) gets a Did-You-Mean
   Suggestion under the walk's rules, from this Flag's own Variants only;
   those rules already give none to a short form, a Non-Option Short
   included. Anything else gets none.

## Considered options

- **An opt-in per Flag.** Every input accepted today keeps its meaning, so
  there's nothing to protect by asking.
- **Values before Variants.** A string Flag could have an `=` op whose value
  spells another of its Variants; trying the Variant first keeps ADR 0005's
  behavior wherever both match.
- **Arbitrary values through a Validator** (`values: Validator[T]`). A
  separate decision, tracked in #332.

## Consequences

- An `=` op's `FlagOp[T]` keeps the value it sets. ADR 0070 makes the op
  itself an opaque closure, so the value is kept beside it.
- The error for an unknown env or config value now reads "variant or
  value", and may carry a suggestion.
