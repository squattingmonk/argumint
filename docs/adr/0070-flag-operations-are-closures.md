# Flag Operations are closures, and flag types need no registration

Supersedes parts of ADR 0027 (decision 1's op strings and `FlagOpGroup`)
and ADR 0028 (the ops the string form accepts).

A type worked as a flag's only after `defineArg(T, handler)`, `defineFlag`
or `defineSetFlag` had generated its methods. The handler was a `case` on
an op string, the ops it listed went into a compile-time registry, and
`flagOp`'s `op` was checked against that registry at run time. `Positive`,
`float32` and `set[E]` each needed registering, and a custom op was a new
name in the handler (`"wrap"`) rather than code at the flag. ADRs 0068 and
0069 removed registration for values; this does the same for flags.

## Decision

1. **A Flag Operation is a closure on the flag's value**,
   `proc (value: var T)`, with its Flag Operation Description and FlagOp
   Alias group. `FlagArg[T]` sits on an untyped `FlagArgBase`, whose
   ordinary methods read only the Variant; nothing is registered. The
   public type is `FlagOp[T]`, replacing `FlagOpGroup[T]`.
2. **Four named ops, of the flag's own type**: `=`, `+=`, `-=` and `*=`.
   `x op= value` uses `T`'s own `op=` if it has one, and otherwise
   `x = x op value`, so any type with the operator supports the op, a set
   included: `+`, `-` and `*` are union, difference and intersection.
   `flagOp`'s `op` is a `static string`, so an op `T` can't do is a
   compile error: `` `+=` needs `+` for Color ``. The `:` op and custom op
   names are gone.
3. **Anything else is a proc**: `flagOp(variants, proc (value: var T), help
   = "")`, or `flagOpIt[T](variants, expr, help = "")`, where `it` is the
   flag's value and `expr` its new value. With no `help`, the op shows no
   description. An op whose value has another type (`DateTime` plus a
   `TimeInterval`) is a proc.
4. **Bare variants run the type's Implicit Operation**, which only three
   kinds of type have: a `bool` is set to the opposite of its default, an
   integer increases by 1, and an enum moves to its next declared value.
   Any other type with bare variants raises `SpecDefect`, pointing to
   `flagOp` with a proc.
5. **A built-in type stops at its bounds.** Named ops and the Implicit
   Operation on integers check `low(T)`/`high(T)` before the arithmetic,
   so they never overflow, and a range type stops at its own bounds. An
   enum stops at its last value. Floats reach ±∞. This is an implicit
   clamp, matching ADR 0016's rule of adjusting silently; a declared clamp
   still narrows it. A user's own operators are the user's responsibility.
6. **The string form of `ops` takes the four named ops only.** Values are
   read with `fromString`, so it needs a Value Type, and for a `set[E]` an
   entry is one `E`. An unsupported or unknown op raises `SpecDefect` with
   the same message `flagOp`'s compile error gives, from the same code.
7. **Generated descriptions** show values as help shows defaults, strings
   quoted: "Set to X", "Increase by X", "Decrease by X" and "Multiply by
   X", and for sets "Set to red, ham" ("Set to none" when empty), "Add",
   "Remove" and "Keep only". Implicit Operations read "Set to true" (or
   "false"), "Increase by 1" and "Move to the next value".

## Considered options

- **Flag Operations as data** (`(op, value)` interpreted by one generic
  `applyOp`). Inspectable, but a custom op would need a second kind of
  entry, or op names found by overload, which brings back the rule that a
  converter must be in scope where a generic is used.
- **A two-type named op** (`flagOp[DateTime, TimeInterval]("--later",
  "+=", 1.days)`). Nim can't infer one type parameter while taking the
  other explicitly, so both would always be written, and it couldn't share
  `flagOp`'s name without making same-type calls ambiguous.
- **Bare variants for any type**, through a `step` parameter on `flag` or
  a trait proc found by overload. The first repeats what a proc says; the
  second brings back the scope rule, and a magic name.
- **Overflow left to the user's build**, as Nim's own `+=` does. A
  `RangeDefect` from a repeated `-v` stops the program in a debug build and
  wraps silently with `-d:danger`.
- **#245's table of function pointers, extended to flags.** Two dispatch
  systems: the table for built-in Args, methods for custom ones.

## Consequences

- **Breaking:** `defineArg(T, handler)`, `defineFlag` and `defineSetFlag`
  are gone. A custom op is a proc passed to `flagOp`; a set needs nothing.
  `FlagOpGroup[T]` is `FlagOp[T]`. The `:` op and custom op names are
  gone. Bare variants need a type with an Implicit Operation, so a type
  whose handler had a blank op now declares a proc for it, unless it's an
  enum. Generated descriptions changed ("Increment by 1" is "Increase by
  1"). Integer flags stop at their type's bounds instead of overflowing.
- `FlagClamp`'s `clamp` needs `<` where it's built, not wherever a flag of
  the type is, so a flag of a type with no `<` works without a clamp.
- An enum with no zero value (`enum a = 1, b`) falls back to its first
  value rather than `default(T)`, which isn't one of its values, for every
  Arg kind.
- The `flagOps` registry, `macrocache` and the template-hygiene workarounds
  for generated flag methods are gone.
- ADRs 0016, 0017, 0024, 0027, 0028, 0043, 0063 and 0069 carry notes
  pointing here.
