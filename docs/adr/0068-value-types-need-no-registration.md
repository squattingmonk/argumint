# A Value Type needs no registration

Supersedes the one-argument `defineArg(T)`, and #167's registry.

A type could be an Arg's value only once `defineArg(T)` had generated the
`ValueArg[T, multi]` methods for it: `accept`, `defaultStr`,
`validatorHelp`, `completions` and the rest. That took a converter from
string *and* a registration call, even for an enum, where `parseEnum` and
`$` already say everything. Forgetting the call was a compile error since
#167, which kept a registry of the types that had made it.

## Decision

A type is a Value Type if a converter from string is in scope where its
Arg is built, or if it's an enum. Nothing else is needed:

```nim
type
  Color = enum red, green, darkBlue = "dark-blue"
  Port = distinct int

converter toPort(s: string): Port = Port(parseInt(s))

let spec = (
  color: opt("-c, --color=<color>", default = green),
  port: opt("-p, --port=<n>", default = Port(80)),
)
```

1. **A table of function pointers, not generated methods.** Every `Arg`
   carries a private `ValueOps`, `nil` except on a `ValueArg`.
   `initValueArg` fills it from generic procs instantiated for its `T`, and
   the base `Arg` methods (`accept`, `clear`, `accumulates`, `defaultStr`,
   `validatorHelp`, `completions`, `envSource`, `configKey`) call through
   it when it's set. A custom `Arg` subtype has no table, so its own
   overrides and the base behaviour are unchanged (ADR 0062).
2. **Converters stay the extension point.** A user writes
   `converter toPort(s: string): Port`, as before.
3. **Every string-to-`T` conversion goes through one private
   `fromString[T]`.** It calls the built-in conversions by name, parses an
   enum with no converter of its own with `parseEnum`, and otherwise relies
   on `let x: T = s` to find the user's converter. Implicitly, a converter
   is only found where a generic is instantiated (`docs/gotchas.md`), which
   is now the user's module even for `int`. `parseFlagOpsString` uses it
   too.
4. **argumint's own conversions stay private, and stop being converters.**
   `toInt`/`toFloat`/`toBool`/`toChar` are plain procs `fromString` calls by
   name.
5. **The one-argument `defineArg(T)` is removed.** The two-argument
   `defineArg(T, handler)`, `defineFlag` and `defineSetFlag` still register
   a *flag* type; that registry is unchanged.
6. **An enum is parsed with plain `parseEnum`**: case-insensitive after the
   first letter, ignoring underscores, and matching a value's own string
   (`dark-blue`) rather than its identifier -- the rules `defineSetFlag`
   already used. A user's converter for the enum takes precedence.
7. **An enum argumint parses lists its values** in help (`[choices: ...]`),
   in completion (which also turns off path completion) and in a bad
   value's error (`got "x" but expected one of ...`). A validator that lists
   values of its own (`choice(...)`) replaces the list. One that doesn't
   (`check(...)`) filters it, so completion and the error leave out what it
   rejects, and help joins its `desc`, if it has one, with `and`. An enum
   with its own converter lists nothing, since its converter may accept
   other words.
8. **The compile error for any other type names the converter to write:**
   ``Hue is not a value type: define `converter toHue(value: string): Hue`
   where its Arg is built``. It checks for an exact match with a built-in
   (`sameType`), so a type that only converts to one (`int8`, `Natural`,
   `range[0..10]`) is rejected as before.

## Considered options

- **Generic methods on `ValueArg[T: enum, multi]`.** Deprecated, and in a
  prototype they didn't dispatch at all: the base method ran.
- **Generating the methods from the constructors.** `opt(...)` is often
  called inside a proc, where a method can't be declared.
- **The table for enums only.** It builds the same table, but needs two ways
  to dispatch side by side, and a second change to generalise it.
- **An overloadable `parseValue(s: string, _: typedesc[T]): T` proc.**
  Works (with `mixin`), and isn't subject to the converter-scope rule. The
  converter's signature is the cleaner one to ask users for, and it's what
  they already write.
- **A `parse(s: string): T` overloaded on return type.** Nim never picks
  an overload by its expected type: two such procs in one module are
  rejected as ambiguous, and across modules the nearest one shadows the
  rest.
- **Exporting the built-in converters**, so `let x: T = s` finds them in the
  user's module. With them in scope, 13 of 16 type mistakes tried against a
  `name: string` compiled where none did before: `let n: int = name`,
  `takesInt(name)`, `name == 5`, `name + 1` and `max(name, 3)` raise
  `ValueError` at runtime; `if name:` turns `"yes"` into `true`; and
  `"x" in s` compiles through `toChar` when `std/strutils` isn't imported.
  Rejected, and not to be revisited.

## Consequences

- **Breaking:** the one-argument `defineArg(T)` is gone; delete the call.
- **Breaking:** the converter must be in scope where the Arg is built, or,
  when a library wraps `opt` in a generic of its own, where that generic is
  instantiated. A converter a library kept private now fails at the
  `opt(...)` call in its users' code; export it.
- A converter must still come before the Arg is built in its module, as any
  Nim symbol must.
- Generic code on the value path (`acceptImpl`, `validate`,
  `completions`) is now instantiated in the user's module rather than in
  `argtypes`, so an unqualified call inside `fmt` or to a later-declared
  proc there no longer resolves (`docs/gotchas.md`). Those calls were
  hoisted out of `fmt` and reordered.
- ADRs 0017, 0043 and 0062 carry notes pointing here.
