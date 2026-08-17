# `get` is the escape hatch when the value converters can't fire

`toT`/`toSeqT` let a parsed Arg be used directly as its value type, and
that is the documented idiom: `fmt"Copying {file} to {spec.dest}"` reads
the way it should. Nim converters fire when the expected type is known, so
interpolation, `==`, `.len`, iteration, `mapIt`, arithmetic, `$`, `&`, and
`if` on a flag all work.

They do not fire when a generic parameter has to be inferred *from* the
Arg. `T` then binds to the Arg's own type, and the failure lands somewhere
downstream naming `ValueArg`. The shapes that hit this are not exotic:

```nim
spec.tags.join(",")                 # openArray[T]
"a" in spec.tags                    # contains[T]
case spec.name                      # of "Bob": ...
%*{"name": spec.name}
let xs: seq[string] = @[spec.name]
var s = spec.name; s.add "!"
some(spec.name)                     # compiles as Option[ValueArg[...]]
```

`join` and `in` are the two obvious things to do with an `opts()` result.
`some(...)` is the worst of them: it compiles, silently inferring
`Option[ValueArg[system.string, false]]`, and errors only wherever the
expected type is finally named.

Escape hatches existed — `toT(...)`, `toSeqT(...)`, `spec.name.string`,
`seq[string](spec.tags)` — but they were documented nowhere, and picking
between `toT` and `toSeqT` requires knowing an Arg's arity.

## Decision

One accessor spelling, uniform across scalar Args, multi-value Args, and
flags:

```nim
proc get*[T](arg: ValueArg[T, false]): T
proc get*[T](arg: ValueArg[T, true]): seq[T]
proc get*[T](arg: FlagArg[T]): T

template get*[T](arg: ValueArg[T, false], otherwise: T): T
template get*[T](arg: ValueArg[T, true], otherwise: seq[T]): seq[T]
template get*[T](arg: FlagArg[T], otherwise: T): T
```

`arg.get` is exactly the converter's semantics: the parsed value, falling
back to the coded default. `arg.get(otherwise)` returns the parsed value
when some tier supplied one, and `otherwise` when none did — the coded
default is ignored for that call.

### It is an escape hatch, not the primary idiom

The implicit conversion stays the documented default and stays what the
examples use. Nothing in `README.md`, `examples/`, or the existing tests
changed. Rewriting ~57 read sites to `spec.dest.get` would make the
documentation worse to buy uniformity nobody asked for; `get` exists for
the call sites where the conversion doesn't reach.

`README.md`'s new *Getting Values Out* section documents `get` and the
shapes that need it. It deliberately does not document `toT`/`toSeqT` or
the cast forms: a converter must be exported to fire, but naming it in the
docs would give readers a second spelling to choose between for no gain.

### The converters delegate to `get`, not the reverse

Two independent implementations could silently diverge, leaving
`spec.name` and `spec.name.get` disagreeing. One body, one answer.

### `otherwise` is lazy, via `template`

The motivating use is computing a fallback from other Args' values, which
should not run when its result is discarded. A `proc` was measured
evaluating the fallback on the supplied path. Each template binds `arg` to
a local first, so the operand is evaluated exactly once on both paths
(`let a = arg`, not two mentions of `arg`) — pinned by tests that count
evaluations of both operands.

The templates read `ValueArg`'s private `value` field and expand in the
caller's module. That works because a template declared in the same module
as the type reaches its private fields wherever it expands — the rule
`docs/gotchas.md` already records for `defineArg`/`defineFlag` — so `get`
needs no new exported predicate to test "was it supplied". Verified with a
scratch compile before committing to the shape.

### `seen` is the supplied-or-not predicate, for every type

All three `get(otherwise)` overloads ask the same question the same way:
`arg.seen` (ADR 0039). Nothing else would work for a `FlagArg` — its
`value` is a plain `T` that always holds something, so a flag declared
with a non-zero default is indistinguishable from a supplied one by
storage alone — and `seen` is simply the domain's own answer to "did a
tier supply this Arg", which is exactly what `otherwise` branches on.

Issue #16's brief asked for a `ValueArg` to test its own stored value
(`value.len > 0`) instead, on the grounds that `seenBy` and the stored
value disagreed inside a parent command's `before` hook. That window is
closed: ADR 0032 moved every tier's conversion ahead of `dispatch`, and
ADR 0039 writes provenance for the whole matched tree right after the
walk, so both are fully resolved before any hook can observe either. With
the disagreement gone, two predicates for one question is a distinction
without a difference, and the uniform one is the accessor's whole point.

The scalar overload indexes `value[0]` on the seen branch, so it now
depends on that agreement — a `seen` `ValueArg` always has a stored value.
`tests/test_get_accessor.nim` pins it across all three supplied tiers and
from inside a parent hook, so a later change to dispatch ordering breaks a
test rather than an index.

The no-arg `get` is not a second implementation of that test: it *is* the
`otherwise` form, called with the Arg's coded default as the fallback.

```nim
proc get*[T](arg: ValueArg[T, false]): T = arg.get(otherwise = arg.default[0])
proc get*[T](arg: ValueArg[T, true]): seq[T] = arg.get(otherwise = arg.default)
```

So there is exactly one supplied-or-not test in the library, and "no tier
supplied this, so substitute the coded default" is stated once. A
`FlagArg`'s no-arg `get` returns `value` outright, since a flag's coded
default *is* its starting value rather than a separate substitution tier.

This makes the template's laziness load-bearing for correctness, not just
for efficiency: `arg.default[0]` must not be evaluated on the supplied
path. Every scalar `ValueArg` reaching this code came from `arg*`/`opt*`,
which store `@[default]`, so the index is safe — but an Arg constructed
by hand with an empty `default` would fault, and only the unsupplied
branch would show it.

### It is not a fifth tier of Value Precedence

`otherwise` substitutes for the coded default at read time, per call site.
It is never validated (ADR 0008's rule for the coded default it replaces),
never becomes a Seen Value, and never touches `seenBy`. Two reads of one
Arg may legitimately differ — `spec.port.get` and `spec.port.get(8080)`
answer different questions about the same Arg.

## Consequences

- `get` is additive. No existing example, test, or README snippet needed
  editing.
- `get` shadows nothing: `options.get` overloads on `Option[T]`, and the
  new overloads take `ValueArg`/`FlagArg`, so a module importing both
  resolves each by argument type.
- The write-side counterpart — setting or adding to an Arg's value
  programmatically — is issue #29 and stays out of scope.
- The compiler error produced when inference binds `T` to the Arg is
  unchanged. `get` routes around it rather than fixing it.
- Because every `get` branches on provenance, an Arg constructed and
  `parse`d directly — bypassing `fsm.parse`, so nothing writes `seenBy` —
  now reads as unsupplied and returns its coded default rather than the
  value it holds. `import argumint` cannot reach that state — it does not
  re-export `parse*` — but `import argumint/backend` can, so a custom Arg
  subtype driven by hand rather than through `parse*` sees it. Feeding a
  spec that way was never supported; every path that is (the walk, the env
  sweep, the Config Source sweep) writes provenance for the whole tree
  before any value is readable. The embedded white-box tests in
  `src/argumint.nim` that do drive `parse` by hand assert on `value`
  directly, never through `get` or a converter. Issue #29 closes the state
  outright: a programmatic write marks the Arg as Seen, via `parse` taking
  a `SeenBy` and writing provenance wherever a value is written.

## Considered options

**Make `get` the primary documented idiom and demote the converters.**
Only affordable pre-1.0, and it trades the library's best-reading feature
for uniformity. The quickstart is where the converter earns its keep.

**Un-export or deprecate the converters.** A converter must stay exported
to fire implicitly, so this is the same proposal as above with a migration
cost attached.

**`getOr` as a separate name for the fallback form.** An overload of one
name keeps the arity question out of the caller's head, which is the whole
point of the accessor; two names would put a different one back in.

**Fix the inference failure itself.** Not possible from library code —
where a converter fires is a language rule.
