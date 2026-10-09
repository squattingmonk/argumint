# Every number type, and range types, are Value Types

> **Note (#248):** flags need no registering either now, so the last
> consequence below no longer holds (ADR 0070).

Amends ADR 0068, decision 16.

ADR 0068 made a type a Value Type if it's a built-in (`string`, `int`,
`float`, `bool`, `char`), an enum, or has a converter from string where its
Arg is built. The built-ins were matched exactly, so `int8`, `float32`,
`Natural` and `range[0..10]` were compile errors asking for a converter,
though `Natural` is the natural type for a count. Before #167 they compiled
and then ignored every value given.

## Decision

1. **Every integer and float type, and range types, are Value Types** with
   no converter: `int8` to `int64`, `uint8` to `uint64`, `int`, `uint`,
   `float32`, `float64`, `Natural`, `Positive`, `range[1..10]`. A
   `distinct` type still needs a converter, even `distinct int`.
2. **A value outside the type is a `ParseError`**, worded like a `range`
   validator's failure: `for --level, got "300" but expected a value in
   -128..127`. A range type uses its own bounds. Integers are parsed as a
   `BiggestInt` (or `BiggestUInt`) and checked against `low(T)`/`high(T)`,
   so nothing a user types raises a `RangeDefect`. Text written as an
   integer that's too large even for that, or negative for an unsigned
   type, is out of range too, rather than "not an integer".
3. **A finite value too large for `float32` is out of range**, rather than
   silently becoming `inf`. A literal `inf` is accepted. A float range type
   is checked against its bounds like an integer one, and rejects `nan`; a
   plain float takes it.
4. **A non-number is described in plain words for every number type**,
   `int` included: `expected an integer for --port but got "abc"`, and
   `expected a number` for floats. This changes `int`'s message, which was
   `expected int`. Other types keep their name (`expected DateTime`).
5. **A leading space before a negative number is allowed**, as it was for
   `int`.
6. **The fallback default is the type's lowest value if zero is outside
   it.** With no `default`, `opt[Positive]("--n=<n>")` holds `1`, not
   `default(Positive)`, which is `0`. Help leaves out a default equal to
   that fallback, as it does `default(T)` for other types. `arg`, `opt` and
   `flag` share it.
7. **Help shows no bounds for a range type.** A `range` validator still
   does. The guide offers a range type as the simpler way to bound a number
   when the bounds needn't show.

## Considered options

- **A converter per type, written by the user.** What ADR 0068 required.
  Every program bounding a count would write the same `parseInt` and range
  check, and most would leave out the range check.
- **Converting through `int` and letting Nim's conversion check the
  range.** A `RangeDefect` from user input stops the program instead of
  reporting a parsing error.
- **Showing a range type's bounds in help.** Help would show `[range:
  0..9223372036854775807]` for every `Natural`. A `range` validator is the
  way to show bounds.

## Consequences

- **Breaking, in wording only:** a non-number for an `int` reads `expected
  an integer` instead of `expected int`.
- A program that wrote a converter for one of these types keeps working,
  but argumint's own conversion now runs instead, as it does for `int`.
- Two specs whose tuples differ only in a range type (`opt[int]` in one,
  `opt[Natural]` in the other) can fail in the C compiler, a Nim bug
  (`docs/gotchas.md`).
- Flags are unchanged here: a number or range type still needs registering
  to be a flag's type.
