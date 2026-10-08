# A Value Type needs no registration

Supersedes the one-argument `defineArg(T)`, and #167's registry.

A type could be an Arg's value only once `defineArg(T)` had generated the
`ValueArg[T, multi]` methods for it: `accept`, `defaultStr`,
`validatorHelp`, `completions` and the rest. Generic methods don't dispatch,
so every type needed its own. That took a converter from string *and* a
registration call, even for an enum, where `parseEnum` and `$` already say
everything. Forgetting the call was a compile error since #167, which kept a
registry of the types that had made it.

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

### An untyped base with a typed leaf

1. **`ValueArgBase` sits between `Arg` and the typed Args.** It isn't
   generic, so its methods are ordinary methods that dispatch. It holds
   what isn't typed (`env`, `cfgKey`, whether it's multi-value), and
   answers `accumulates`, `envSource` and `configKey` from it.
2. **Only two things need the value's type at run time: writing a value and
   clearing it.** The leaf's constructor fills in three **hooks**,
   `{.nimcall.}` procs instantiated for its type that take the base and
   downcast: `write` (convert, validate, store; `accept`'s body), `reset`
   (empty the storage; called by `clear`) and `describe` (`defaultStr`,
   `validatorHelp` and `completions`, computed when help or completion
   asks). No closures, so no reference cycles.
3. **The rule for extending it:** a new base method is an ordinary method
   on `ValueArgBase`, and needs a hook only if it touches typed storage. A
   test fails if a constructor leaves a hook unset.
4. **The custom-Arg contract is unchanged.** A custom `Arg` subtype still
   overrides `accept`, `clear` and the optional methods (ADR 0062).
5. **`describe` is lazy.** Precomputing its three results as fields was
   measured at about 0.4 µs and 265 B per option (an option is 893 B), paid
   on every run, including `__complete`, which never shows help.

### Two arities, two types

6. **`ValueArg[T]` is the scalar arity and `ValuesArg[T]` the multi-value
   one**, replacing `ValueArg[T, multi: static bool]`. The `multi`
   parameter was merged in so one set of generated methods covered both;
   with nothing generated, the reason is gone. Each leaf carries its own
   `Validator[T]`. The arities differ in two small overloads, `history`
   (what a Validator checks against) and `store` (set or append); the rest
   is written once over both.
7. **Storage is an `Option`:** `ValueArg[T]` holds `Option[T]` with a `T`
   default, and `ValuesArg[T]` holds `Option[seq[T]]` with a `seq[T]`
   default. `none` means no tier or write has supplied a value, and is what
   `clear` restores.
   - Not a plain `T`: a tier-less `put` stores a value but leaves `seenBy`
     at `byNone`, and `get(otherwise)` must still see it (ADR 0040, amended
     for `put`), so a plain `T` would need a separate "held" flag.
   - `Option[seq[T]]` tells "supplied empty" apart from "not supplied". A
     tier-less `replace(@[])` on `opts("--tag=<t>", default = @["x"])` used
     to read back as `@["x"]`, and `get(otherwise)` needed a `seen or`
     check to cover the tiered case. Now both read `@[]`, and the check is
     gone: a tier claimed with nothing stored falls back, as it does for a
     scalar.
8. **`get` and `put` overload on the two types.** `toT` exists only for
   `ValueArg`, and `toSeqT` and `replace` only for `ValuesArg`.
9. **`FlagArg[T]` is unchanged here.** Its own redesign follows separately.

### Converting a value

10. **Converters stay the extension point.** A user writes
    `converter toPort(s: string): Port`, as before.
11. **Every string-to-`T` conversion goes through one private
    `fromString[T]`.** It calls the built-in conversions by name, parses an
    enum with no converter of its own with `parseEnum`, and otherwise relies
    on `let x: T = s` to find the user's converter. Implicitly, a converter
    is only found where a generic is instantiated (`docs/gotchas.md`), which
    is now the user's module even for `int`. `parseFlagOpsString` uses it
    too.
12. **argumint's own conversions stay private, and stop being converters.**
    `toInt`/`toFloat`/`toBool`/`toChar` are plain procs `fromString` calls
    by name.
13. **The one-argument `defineArg(T)` is removed.** The two-argument
    `defineArg(T, handler)`, `defineFlag` and `defineSetFlag` still register
    a *flag* type; that registry is unchanged.
14. **An enum is parsed with plain `parseEnum`**: case-insensitive after the
    first letter, ignoring underscores, and matching a value's own string
    (`dark-blue`) rather than its identifier -- the rules `defineSetFlag`
    already used. A user's converter for the enum takes precedence.
15. **An enum argumint parses lists its values** in help (`[choices: ...]`),
    in completion (which also turns off path completion) and in a bad
    value's error (`got "x" but expected one of ...`). A validator that
    lists values of its own (`choice(...)`) replaces the list. One that
    doesn't (`check(...)`) filters it, so completion and the error leave out
    what it rejects, and help joins its `desc`, if it has one, with `and`.
    An enum with its own converter lists nothing, since its converter may
    accept other words. An enum with gaps lists every declared value.
16. **The compile error for any other type names the converter to write:**
    ``Hue is not a value type: define `converter toHue(value: string): Hue`
    where its Arg is built``. It checks for an exact match with a built-in
    (`sameType`), so a type that only converts to one (`int8`, `Natural`,
    `range[0..10]`) is rejected as before.

## Considered options

- **A table of function pointers on every `Arg`** (#245). One dispatch path
  for built-in Args, but eight table entries, an `isNil` branch in every
  base method, and methods still used for custom Args: two dispatch systems
  side by side. It also left flags untouched.
- **No subclassing at all**: `Arg` as one record of closures, custom Args
  included. The most uniform, but it drops the method-based custom-Arg
  contract (ADR 0062).
- **Generic methods on `ValueArg[T, multi]`.** Deprecated, and in a
  prototype they didn't dispatch at all: the base method ran.
- **Generating the methods from the constructors.** `opt(...)` is often
  called inside a proc, where a method can't be declared.
- **Values stored as strings until read.** `put` takes a typed value, and
  `$` doesn't round-trip through a converter (`DateTime`).
- **A generic middle class** sharing `validator` between the two leaves.
  Not worth a third level for one field.
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
- **Breaking:** `ValueArg[T, false]` and `ValueArg[T, true]` are now
  `ValueArg[T]` and `ValuesArg[T]`.
- **Breaking:** a tier-less `replace(@[])` now reads back empty instead of
  as the default, and a multi-value Arg whose tier was claimed with nothing
  stored reads as its default rather than as `@[]`.
- A converter must still come before the Arg is built in its module, as any
  Nim symbol must.
- Generic code on the value path (`acceptImpl`, `validate`,
  `completions`) is now instantiated in the user's module rather than in
  `argtypes`, so an unqualified call inside `fmt` or to a later-declared
  proc there no longer resolves (`docs/gotchas.md`). Those calls were
  hoisted out of `fmt` and reordered.
- The `static bool` parameter was the condition for the ORC corruption in
  `docs/gotchas.md`. It's gone, but `ValuesArg` still appends in place, and
  the regression test stays.
- ADRs 0017, 0033, 0043 and 0062 carry notes pointing here.
