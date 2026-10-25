# A Flag's `validator` checks the values it receives as text

Builds on [ADR 0085](0085-flag-env-and-config-values.md), and revises
[ADR 0016](0016-flag-clamp.md)'s premise that a Validator never applies to
a Flag.

After ADR 0085, an env or config value for a Flag had to be a Variant or a
value one of its `=` ops sets. A `flag[int]` whose ops set `0` and `5`
rejected `LEVEL=3`, and allowing a range meant turning the Flag into an
`opt` (issue #332).

## Decision

1. **Scope.** A Flag's `validator` checks any value the Flag receives as
   text rather than through a Flag Operation. Env and config are the only
   such sources today. A later one, such as a value attached on the command
   line, extends this rule rather than reversing it.
2. **New overloads, not a new parameter.** Each form of `flag*[T]`'s `ops`
   gets an overload with a required `validator: Validator[T]`, so the
   existing calls are untouched and the excluded types fail at compile
   time. The bare `flag(...)` gets none.
3. **Resolution order.** A Variant, then a value an `=` op sets (ADR 0085),
   then the input converted as an `opt[T]` converts it, checked by
   `validator`, and assigned as an `=` op would. Any Flag Clamp applies
   afterward, as after a Flag Operation, so a clamp narrower than
   `validator` silently narrows an accepted value. Failures read as on an
   `opt[T]`: `ConversionError` or `ValidationError`, naming the source. An
   option-shaped input that fails to convert keeps ADR 0085's Did-You-Mean
   Suggestion.
4. **Excluded types.** `T` must be a Value Type, and not `string` or `bool`:
   - Any text converts to a `string`, so a mistyped Variant
     (`MODE=--fats`) would be stored as data. A string Flag that wants
     arbitrary values should be an `opt[string]`.
   - A `bool` Flag already takes `true` and `false` (ADR 0085).
   - A `set[E]` already fails the Value Type check.

   A `distinct` string, or a custom type whose conversion accepts any text,
   passes. That risk is the spec author's.
5. **Spec construction checks the `=` ops.** Each `=` op's value must pass
   `validator`, or it's a `SpecDefect` naming the op. So no env or config
   input stores a value `validator` rejects, whether given as the value or
   as that op's Variant, and neither is checked again at parse time.
   Relative and opaque ops (`+=`, `-=`, `*=`, procs, Implicit Operations)
   aren't checked: bounding them is the Flag Clamp's job.
6. **Two more `SpecDefect`s.** A `validator` that is or contains a
   history-aware one (`checkSeen`, `checkSeenIt`, `unique`) could never
   fail, since a Flag holds one value. A Flag with `validator` but neither
   `env` nor `configKey` could never run it.
7. **No check on the default** (ADR 0008). The clamp's check on the default
   is unchanged.
8. **Help** gives `validator` its own bracket entry, labelled
   `env/config values: ` and followed by the Validator's own help text,
   after any clamp's entry: `[clamp: 0..9; env/config values: range: 0..5;
   env: LEVEL]`. A `validator` with no help text adds no entry. Completion
   is unchanged.

## Considered options

- **An optional `validator` on the existing overloads.** It couldn't reject
  `string` and `bool` at compile time, since a defaulted parameter can't
  tell whether it was passed.
- **Checking `=` values at parse time instead.** It runs the validator on
  every env or config value, and still lets an `=` op's Variant through
  unchecked unless Variants are checked too, which would make an op's own
  spelling fail at parse time for a spec mistake.

## Consequences

- `FlagArg[T]` stores an optional `Validator[T]`, and `FlagArgBase` gains an
  `assign` hook for the third resolution step.
- `GLOSSARY.md`'s Validator and Flag Clamp no longer say a Validator never
  applies to a Flag.
