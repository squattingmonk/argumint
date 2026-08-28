# `parse` is the write surface, and records its own provenance

> **Amended by [ADR 0044](0044-put-typed-write-accessor.md)**: `put` joins
> `parse` as a second write spelling — the same arbitration, minus the
> string conversion, plus a `validate = false` opt-out. The write-surface
> table below gains a row for it. The "ADR 0040's promise is closable but
> not closed" Consequence is now closed for a `ValueArg`'s own readers — a
> tier-less write is always readable through `get`/`get(otherwise)` — and
> narrowed, not left fully open, for `FlagArg`: a tier-less write is
> readable there too once it actually changes the value away from the
> coded default, and stays invisible only in the narrow case where it
> happens to reproduce the default exactly.

> **Further amended by [ADR 0045](0045-replace-typed-atomic-multi-value-write.md)**:
> `replace` gives a multi-valued `ValueArg` an atomic, one-call
> replacement, closing the "replace a multi Arg's values" row's
> non-atomicity below. Unlike `parse`/`put`, it does not arbitrate at all —
> it always overwrites value and provenance together, which is what lets
> it demote unconditionally in one call instead of `clear()` then a
> declaring `parse`.

> **Further amended by [ADR 0046](0046-arg-value-source-contract.md)**: the
> header below names `envName*`, `envDelim*` and `configKey*` as the three
> methods that "stay" in the custom-`Arg` contract. There are now two —
> `envName`/`envDelim` collapsed into one `envSource*` returning
> `Option[EnvSource]`, since they only ever read the one field and could
> otherwise disagree. `envName` remains, derived from `envSource` as a
> plain proc rather than an overridable method. All are reachable from the
> facade, as that header says the write side already is.

Nothing supported writing a value into an Arg from application code. A
program that wants to seed a default computed at startup, replay a saved
session, or layer a source argumint doesn't know about had no way in.

Issue #29 proposed adding `set`/`add`/`apply` accessors for it. But
`Arg.parse` already *was* all three: `parseImpl` replaces for a scalar
`ValueArg` and appends for a multi one, and `FlagArg.parse` applies the
named Variant's Flag Operation with its Clamp. It was exported from
`backend.nim` and simply never re-exported through the facade, so reaching
it meant the backend import ADR 0030 set out to make unnecessary.

Re-exporting it alone doesn't work. Every reader added by ADR 0040
branches on `seen`, so a by-hand write with no provenance produces an Arg
holding a value that nothing will return:

```nim
let port = opt("-p=<n>", default = 80)
port.parse("77")
port.get              # => 80, the coded default
```

The value is written — a garbage value still raises from the converter,
proving the method runs — but no accessor reports it. So the provenance
parameter isn't a refactor layered on top of the export; it is what makes
the export do anything.

Two further things were in the way. `parse` meant two unrelated things:
`MessageArg`/`HelpArg` overrode it to raise, which *is* their handling,
and `HelpArg` overrode a second `(command, spec, variant)` overload
because it needs the enclosing Spec to render help. And the Value
Precedence tiers gated on provenance but never arbitrated against it — a
value written before parsing was either silently clobbered or silently
accumulated onto, with no way to say which was meant.

## Decision

### `parse` carries a tier, and is public

```nim
method parse*(self: Arg, value: string, variant = "",
              seenBy: options.Option[SeenBy] = none(SeenBy)) {.base.}
```

re-exported through the facade, so `import argumint` alone reaches it.
`some(byCli)` needs no `import std/options` — the facade already
re-exports `some`/`none`/`Option` for `clamp`'s `desc` parameter.

The governing rule is **`seenBy` declares a tier; omitting it extends at
whatever tier is current.** Value semantics are unchanged and
unconditional. This is the whole write surface, with no new accessors:

| operation | spelling |
| --- | --- |
| append a value | `arg.parse(v)` |
| append and declare a tier | `arg.parse(v, seenBy = some(t))` |
| replace a multi Arg's values, non-atomically, from strings | `arg.clear()`, then one `parse` per value |
| replace a multi Arg's values, atomically, from a `seq[T]` | `arg.replace(values)` — see ADR 0045 |
| apply a Flag Operation | `flag.parse("", variant)` |
| hand an Arg to a weaker tier | `arg.clear()`, then `parse` declaring it, or `arg.replace(values, seenBy = some(weakerTier))` |
| write an already-computed `T`, skipping conversion | `arg.put(v)` — see ADR 0044 |

The base implementation is a **quiet recorder**: it records provenance and
does nothing else, and never raises. This matches how `defaultStr` and
`completions` already treat the value-less Arg kinds, and it means
`CommandArg` and `MessageArg` need no `parse` override at all.

### `arbitrate` is the tier rule, stated once

Each contribution is arbitrated against the Arg's incoming provenance
**S** by the tier **T** it declares:

| S vs T | behavior |
| --- | --- |
| `S < T` | run the *replacing* body, `clear` the Arg, then apply — a weaker tier's values are replaced, not appended to |
| `S == T` | run the *extending* body and apply without clearing, so values from one tier accumulate |
| `S > T` | refuse; apply nothing |

That lives in one exported template:

```nim
template arbitrate*(self: Arg, tier: options.Option[SeenBy],
                    eqBody, gtBody: untyped)
template arbitrate*(self: Arg, tier: options.Option[SeenBy])
```

Every `parse` implementation routes through it. Stating the rule three
times instead — once per implementation — is how an override silently ends
up demoting, or accumulating where it should reset; neither failure raises,
and both produce a wrong value rather than an error. The second overload is
for the Arg kinds with nothing to do on either branch, which is most of
them; it still skips a weaker tier and still clears on a stronger one.

**A template, not a proc, and two bodies rather than a `bool`.** The two
branches don't just decide *whether* to apply — they need different code.
A history-aware Validator (`unique`, `checkSeenIt`) checks a candidate
against the values already collected, and on the replacing branch those
values are about to be discarded, so validating against them would reject a
value that is about to be the only one there. The extending branch passes
`self.value`; the replacing branch passes nothing.

Running the replacing body **before** the `clear` is what makes a failed
write atomic. Conversion happens earlier still, outside `arbitrate`
entirely. So a `parse` that raises — bad string, rejected value, either
branch — leaves the Arg exactly as it was, rather than cleared, stamped
with the new tier, and holding nothing. That state is not hypothetical: it
is the `IndexDefect` described under "Provenance is written by whoever
writes the value" below, reached from the other direction.

A `bool`-returning proc cannot express either property. It has already
mutated by the time it returns, so the caller's validation runs too late to
prevent the clear, and has no way to know which history to check against.

This makes a write performed before parsing a **pre-seed** the tiers
arbitrate against, rather than something they blindly clobber:

```nim
# three independent scenarios, each starting from a fresh Arg

tags.parse("x", seenBy = some(byCli))    # claims the tier the CLI will use
spec.parse(args = @["--tag", "user"])
tags.get                                 # => @["x", "user"] -- equal tier, appended

tags.parse("x")                          # claims no tier; the Arg stays byNone
spec.parse(args = @["--tag", "user"])
tags.get                                 # => @["user"] -- byNone < byCli, so the
                                         #    first CLI contribution cleared the seed

port.parse("8080", seenBy = some(byCli)) # nothing typed, but byCli outranks both
spec.parse(args = @[])                   # fallback tiers, so both skip the Arg
port.get                                 # => 8080
```

Note that the clearing in the second scenario is done by the command
line's own first contribution, not by the seeding call: a write that
declares no tier never clears, it only extends.

### Arbitration lives in `parse`, not at the tier call sites

The alternative was to leave `parse` as "convert, validate, store, record"
and put the three-way comparison at each of the three tier call sites.
That keeps the virtual method's contract smaller, which matters because it
freezes at 1.0.

It loses to one constraint it can't satisfy from where it sits. A tier
that is *consulted but resolves nothing* must not destroy a pre-seed, so
clearing can only happen once a value is actually in hand — never at the
gate, which runs before the tier is asked. The place where a value is in
hand is `parse`. Putting the comparison anywhere else splits one rule
across two sites and leaves the gate unable to express the interesting
half of it.

The gate keeps only the decision that doesn't depend on the answer: skip a
strictly stronger tier, cheaply, before a possibly expensive
`ConfigSource.lookup` runs for a result that would be discarded.

### `parse` never demotes

A declared tier weaker than the one already recorded is refused outright.
A stronger tier's value can't be quietly undercut by a later write, and
"weaker tier wrote nothing" is the same answer the fallback sweep gives.

Demotion is still available, spelled so it can't happen by accident:

```nim
arg.clear()
arg.parse(v, seenBy = some(byConfig))
```

The rejected alternative was to treat an application-code call as a pure
declaration that always lands and may demote. It reads well in isolation —
a caller who names a tier gets it — but it means a program can silently
undo what the user typed, and the two spellings differ by one call.

### The side-effect overload becomes `action`

The `(command, spec, variant)` base method is renamed, and **both**
`MessageArg` and `HelpArg` override it — `MessageArg` raising
`MessageError`, `HelpArg` raising `HelpError` with generated help text.
It is the *only* `action`; there is no narrower `(variant)` overload for
the kinds that don't need a Spec. A plain `MessageArg` ignores `command`
and `spec`, which costs it nothing and buys the thing that matters: the
per-level message pass dispatches once, with no `of HelpArg` test.

Two overloads split by what each kind needs would have forced that test
back, since one dispatch cannot reach two signatures.

The name mirrors a Spec's own `action` hook and reflects what these Args
do: a matched Message Argument takes over the leaf's action (ADR 0013).
With the raises moved off it, `parse` means exactly one thing everywhere —
record one contribution, at one tier.

`action` is a dependency inversion: help rendering (`genHelp`) lives above
`fsm.nim` in the import graph, so the FSM does not render help itself and
calls back up through the method instead.

That was a consequence of where `genHelp` sat, **not** a constraint —
everything it needs (`formatUsage`, the display base methods, `Spec`'s own
fields) is already in `backend`, so it could move below `fsm` and let the
FSM raise `HelpError` directly.

**Update:** issue #50 made the move, for the unrelated reason that
`argumint.nim` had grown to 1621 lines. `genHelp` now lives in `help.nim`,
directly above `backend`, and the FSM *could* raise `HelpError` itself. The
inversion is retained deliberately: raising from `fsm.nim` would reintroduce
the `of HelpArg` test this ADR removed, and one unified signature is what
lets `parseMessageArgs` dispatch once. Now that the alternative has been
measured rather than assumed, `action`'s value is what it always was — the
extension point for a custom side-effecting Arg.

### `clear` returns an Arg to its coded-default state

An exported `{.base.}` method with a quiet no-op base and unexported
per-type overrides — the same shape as `defaultStr`, and for the same
reason: the value-less kinds are the common case and shouldn't have to opt
out.

It clears **both** the value and the provenance. An Arg that reads as Seen
with an empty value seq makes ADR 0040's scalar accessor index it, so
clearing the value alone arms a crash.

**Named `clear`, not `reset`.** `system.reset(x: var T)` beats a
`{.base.}` method whenever the receiver is a mutable location — exactly
the shape of a spec tuple held in a `var`. The result is silent (the call
nils the reference instead of dispatching) and position-dependent (a
`let`-held Arg resolves correctly). Verified:

```nim
var d = Derived(n: 5); d.clear()   # => 0    (dispatches to the method)
var e = Derived(n: 5); e.reset()   # => nil  (system.reset wins)
```

`clear` has no `system` counterpart, so it needs no guard overload.

### A `FlagArg` retains its coded default

The Flag constructor writes its `default` argument into both the value and
a new private `default` field. Nothing else ever writes it, so there is no
dual-field dispatch to keep in sync, and `clear` restores from it. The
Clamp invariant comes free: spec construction already rejects a default
that violates its own Clamp, so restoring it can never produce an
out-of-range value.

Before this, a Flag's construction-time state was unrecoverable — the
constructor wrote it straight into the value and Flag Operations mutated
it in place.

### Provenance is written by whoever writes the value

This reverses ADR 0039's "the writes are central, not per-type". That
decision gave two reasons and only one still stood: ADR 0032 had already
moved every matched level's conversion ahead of `dispatch`, so a
per-contribution write also completes before the first hook fires.

So the blanket post-walk `byCli` sweep is gone, and the `setValue`
closures in `applyFallbacks` no longer stamp `byEnv`/`byConfig`. Each tier
feeds its resolved values straight to `parse`, which records the tier as it
writes.

**`setFromEnv` and `setFromConfig` are removed outright.** They existed to
map a tier's `seq[string]` onto `parse`'s parameters, and the two Arg types
mapped them in opposite directions: a `ValueArg`'s values went into the
value slot with the source as error context, while a `FlagArg`'s named
Variants went into the *variant* slot with the value slot unused. That
asymmetry is what made the mapping per-type, and per-type is what made it a
method. Making `value` the datum for both — a `FlagArg`'s value names the
Variant to apply, and `variant` is the error context for both — collapses
the mapping to one uniform call, so the dispatch has nothing left to
dispatch on. `envName`, `envDelim` and `configKey` stay: they are how a
tier *finds* values, which is still per-Arg.

Two consequences worth naming. A Flag's Variant is now checked inside
`parse` rather than by the tier, which is where a public write surface
wants it, and which unified two divergent error messages onto one. And
because `parse` carries the tier, a failure can finally name both the Arg
and where the value came from — `subject` renders `--port (env: PORT)`,
so a typo in an env var no longer reads as something typed at the prompt.

This is not merely tidier. Central stamping wrote provenance whether or
not anything was written, which was a live crash: a `ConfigSource`
returning `some(@[])` — it has the key, but offers no values for it — took
the apply path, wrote nothing, and was stamped `byConfig` anyway. The Arg
then read as Seen with an empty value seq, and `get` indexed it:

```
seenBy=byConfig seen=true
Error: unhandled exception: index out of bounds, the container is empty [IndexDefect]
```

Tying the write to the writer makes provenance unable to outrun the value
it describes.

### The fallback gates skip only a *strictly* stronger tier

ADR 0039's gates were `arg.seenBy >= byEnv` and `arg.seenBy < byConfig`,
which is the two-state question "has anyone supplied this?". Under the
`S == T` row they become `> byEnv` and `<= byConfig`, so a pre-seed
declaring `byEnv` still collects the env var's own values.

Those gates were quietly doing a second job. `applyFallbacks` recurses per
Spec level, so an Arg declared at both an ancestor and a nested command is
visited twice; on the second visit its own provenance had already been
raised by the first, and `>=` skipped it. Once an equal tier appends
rather than skips, that free ride is gone.

The dedup moves onto `ValueCursor.applied`, alongside the `tried` and
`complained` sets ADR 0039 created for the same reason — a fact about what
this tier has done belongs in the tier's own bookkeeping, not borrowed
from the Arg.

## Consequences

- **The custom-`Arg` contract nets out lighter.** It gains two
  obligations, recorded in ADR 0030: a `parse` override must route through
  `arbitrate`, and a value-carrying subtype must override `clear` or it
  will accumulate where it should reset. It loses three methods —
  `setFromEnv`, `setFromConfig`, and the second `action` overload — so
  `parse` is now the single place a subtype handles every tier.
  `arbitrate` exists so the first obligation is one call rather than a
  rule to reimplement — in its no-body form, one line.
- **`arg in info.matched` and `arg.seenBy == byCli` are no longer
  equivalent**, which ADR 0039's Consequences asserted. A programmatic
  write declaring `byCli` sets provenance without a match-table entry.
  `HookInfo.matched` remains the answer to "what did the command line
  name", which is a different question and still its own use case.
- **ADR 0040's promise is closable but not closed.** Its Consequences said
  a by-hand write leaving an Arg holding an unreadable value would be
  fixed by #29. It is fixed for a write that declares a tier, and persists
  by design for one that doesn't — the "extend, don't declare" case.
- **`FlagArg.parse` raises `ParseError`, not `SpecDefect`,** for an
  unregistered Variant. Now that `parse` is public the Variant can come
  from user input, not only from spec construction, so a catchable error
  is the right kind.
- A fallback tier still checks a Variant name against `ops` itself before
  delegating, rather than leaving it to `parse`, which resolves `""` to
  the first Variant as a convenience for programmatic callers. A blank env
  var names no Variant; it must not silently get the first one.
- A `Spec` remains single-use (ADR 0031). Pre-parse writes are supported
  and arbitrated; reusing a parsed Spec is still not.
- Issue #29 is narrowed to what this doesn't cover: writes taking an
  already-computed `T` rather than a string, a `validate = false` opt-out,
  and a one-call replace for a multi-valued Arg.

## Considered options

**`set`/`add`/`apply` accessors (issue #29 as filed).** Three new names
for what one existing method already did, each needing its own answer to
"does it validate?", "does it clamp?", and "does it mark the Arg as
supplied?" — questions `parse` answers by construction, because it is the
path every tier already takes.

**Keeping `setFromEnv`/`setFromConfig` and giving them a `SeenBy` too.**
Considered before the value/variant asymmetry was noticed, on the grounds
that their tier was implied by the method name. Once the asymmetry is fixed
they have no work left to do, so the question of what to pass them is moot.

**Making `parse` consult precedence — "supply this only if nothing else
did".** A caller wanting that writes `if not arg.seen: arg.parse(...)`,
which is one legible line and reports what happened, unlike a call that
silently does nothing.

**Operator sugar for writes.** Nim reserves `=` as the `=copy` hook, and a
Flag's operations are themselves named `+=`/`-=`/`*=`, so `verbose += 1`
would read as applying the `+=` op and would not be that.

**Enforcing *when* a write is legal.** Pre-parse writes are supported by
the arbitration above, and a post-parse write is the caller's business.
There is no phase to enforce that ADR 0031 doesn't already cover.

---

Earlier ADRs that name `setFromEnv`/`setFromConfig` in passing — 0016,
0018, 0029, 0032, 0033, 0039 — describe the mechanism as it stood when they
were written. The behaviour each documents still holds; it now happens
inside `parse`.
