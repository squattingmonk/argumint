# An Arg's value sources are two methods, and they are readable

`Arg` carried three exported `{.base.}` methods that all answered one
question — *where else can this Arg's value come from?* — and were never
consulted apart: `resolveEnv` read `envName` and `envDelim`, `resolveConfig`
read `configKey`, and `genHelp`'s annotation block read two of the three.
Nothing else in the library touched any of them.

The first two were not two facts. Both read the single
`Option[EnvSource]` field `ValueArg` and `FlagArg` already store, split
across two overridable methods that had to agree with each other and had
nothing to make them. `EnvSource`'s own doc comment already rejects that
shape for the field — "an override with no name to apply it to is a
meaningless state, so 'is there an env source at all' is instead answered
by wrapping this whole object in `Option`" — and then the method pair
reintroduced exactly the state the field had ruled out.

The cost compounded through the generators. Because `ValueArg[T, multi]`'s
two arities are distinct concrete types, `defineValueArg` emitted each of
the three twice and `defineFlagArg` emitted all three again: nine generated
methods, every one a bare field read, out of the 24 the generators produce.

## The second problem: the contract was write-only

The three methods were **overridable but not readable** from outside the
library. Both halves of that were surprising, and both were verified by
scratch compile rather than reasoned about:

- A hand-written `ref object of Arg` **can** override them with
  `import argumint` alone, and the tiers dispatch to it correctly — value
  delivered, `seenBy` stamped. Nim attaches the override to `backend`'s
  method family because `Arg` itself is in scope, even though the base
  symbol is not.
- But `someArg.envName` did not compile: *undeclared field: 'envName' for
  type backend.Arg*.

So a custom Arg could join the env and Config Source tiers, yet neither it
nor anything else outside the library could read back what it had declared.
That matters because `docs/adr/0042-genhelp-opt-in-via-submodule.md` makes
`genHelp` opt-in precisely so a caller can render help itself — and these
are the values such a renderer annotates with (`env: PORT`,
`configKey: server.port`).

This also means
`docs/adr/0030-core-types-exported-spec-opaque.md`'s Consequences section
was wrong where it said a hand-written subtype "still can't override them
from a caller's module." It could. What it could not do was read them. That
paragraph is corrected as part of this change.

## Decision

The fallback half of the custom-`Arg` contract is one method per tier, each
returning a type `CONTEXT.md` already defines:

```nim
method envSource*(self: Arg): Option[EnvSource] {.base.} = none(EnvSource)
method configKey*(self: Arg): ConfigKey {.base.} = noConfigKey()
```

`envName` survives as a plain **proc** derived from `envSource`, not a
method:

```nim
proc envName*(self: Arg): string =
  let source = self.envSource
  if source.isSome: source.get.name else: ""
```

It has three call sites — `genHelp`'s annotation, `applyFallbacks`'s label,
and `subject`'s variant slot — to `envDelim`'s one, and all three want the
display form rather than the record. Deriving it keeps every one of them
working, gives a subtype the string for free, and makes disagreement
between name and delimiter unrepresentable rather than merely
undocumented. `envDelim` is gone; `resolveEnv` reads `.get.delim`.

`envSource`, `configKey` and `envName` are all re-exported from
`argumint.nim`, closing the read gap.

Generated fallback-tier stubs go from nine to six.

### `Option`'s accessors follow

`envSource*` is the first exported signature to *return* an `Option`, so
`options.isSome`/`isNone`/`get` are re-exported alongside the `some`/`none`
already there. The facade's own comment had argued against them on the
grounds that they were "unrelated to spec construction", which was true
while `Option` appeared only in parameter position. `docs/adr/0029`'s rule
is a demonstrated caller, and reading an Arg's Env Source is one.
`std/options` is still not re-exported wholesale — `map`/`filter`/`flatMap`
and the rest stay out.

## Considered options

**A single `valueSources` record**, folding all three into one method
returning `(env, configKey)`. The smallest possible contract, and it would
have taken the generated stubs from nine to three rather than six.
Rejected because it invents a domain term to bundle two things `CONTEXT.md`
deliberately keeps asymmetric: its **Config Key** entry states outright
that a Config Key "has no delimiter-override concept the way Env Source
does, since a Config Source's own values arrive already split." A shared
record would flatten that distinction in code and then need the entry to
re-explain it in prose. Two methods over two existing types say the same
thing with no new vocabulary.

**A plain public field on `Arg`, no method at all.** ADR 0030 keeps every
`Arg` field public and says a custom subtype constructs one, so `env*` and
`cfgKey*` could simply have moved to the base type: zero generated stubs,
readable and writable for free, no dispatch. Rejected because every Arg
kind would then carry them, implying a Positional Argument or a Command
could have an environment variable — when `arg*`/`args*` deliberately offer
no `env` param at all. The base method returning `none` is what currently
encodes "positionals have no env tier"; a public field asserts the
opposite.

**Re-export the three methods without collapsing them.** Non-breaking, and
it fixes the read gap on its own. Rejected as the wrong half to do alone:
the read gap can be closed at any point in the library's life, but the
contract can only shrink before 1.0 freezes it.

**Leave it and correct ADR 0030 only.** The three methods work. Rejected
because "works" and "is worth freezing" are different bars, and this is the
last moment the second one is cheap to meet.

## Consequences

- **Breaking for a hand-written `Arg` subtype** that overrode `envName` or
  `envDelim`. Taken deliberately before 1.0; afterwards the same change
  needs a deprecation cycle for the same payoff. Nothing registered through
  `defineArg`/`defineFlag`/`defineSetFlag` is affected — the generators
  emit the new method.
- **The contract's fallback half now has test coverage**, which it never
  had. `tests/test_write_side.nim` already declared a `CustomArg` "per ADR
  0030's custom-`Arg` contract" and exercised `parse`/`clear`; it now
  overrides `envSource`/`configKey` too and asserts both tiers dispatch to
  it. That test would have passed before this change as well — it documents
  behaviour that was real, unverified, and contradicted by ADR 0030's own
  text.
- **`envName` is no longer overridable.** A subtype wanting a computed env
  var name overrides `envSource` and returns a constructed `EnvSource`. No
  in-tree caller did otherwise, and the derived form is what every reader
  wanted anyway.
- **The facade grew four names** — `envSource`, `configKey`, `envName`, and
  `Option`'s three accessors as one group. Each has a demonstrated caller
  per ADR 0029; none opens a private field, since all three read through
  method dispatch or a derived proc.
- **ADR 0030 and ADR 0041 both name the old trio** and now carry pointers
  here, following the "Extended by" pattern ADR 0041 itself established on
  ADR 0030.
