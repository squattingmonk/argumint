# History-aware Validators: `checkSeen()`/`checkSeenIt()`/`unique()`

Every existing `Validator` kind checks a candidate value in isolation.
There was no way to validate a value against what's already been
accumulated for the same multi-value Arg -- e.g. rejecting a duplicate
`--tag` value. `checkSeen`/`checkSeenIt`/`unique` add this, generalizing
beyond just uniqueness: `checkSeen`'s predicate takes both the candidate
value and `seen`, the values already accumulated for the Arg so far
(`unique` is a thin convenience built on top).

## Stateless, not stateful

`Validator[T].validate` gained a `seen: openArray[T]` parameter, sourced by
`parseImpl` (`src/argumint.nim`) from the `ValueArg`'s own already-stored
`value` at the call site -- read *before* that field is mutated, so `seen`
never includes the candidate itself. The `Validator` object carries no
mutable state of its own.

The alternative -- a stateful kind carrying its own mutable "seen" set,
mutated inside `validate()` -- was rejected because it would silently
misbehave the moment a single `Validator[T]` instance is shared across two
different Args of the same type. That's a normal, currently-safe idiom for
every other kind (e.g. reusing one `range(1..10)` on two options), but a
stateful validator would let Arg A's matches count toward Arg B's
uniqueness check purely by ref-identity accident, with no error. The
stateless design has no such failure mode, because there's no instance
state to leak: `seen` is derived fresh, every call, from the single source
of truth (`ValueArg.value`) that actually governs what gets stored.

## Only `openArray[T]`, not the whole Arg

`checkSeen`'s predicate signature is `proc (value: T, seen: openArray[T]):
bool` -- not `proc (value: T, self: ValueArg[T, multi]): bool` or similar.
Passing the whole Arg in was rejected on two independent grounds: it would
invert the module dependency graph (`validators.nim` is imported *by*
`argumint.nim`, not the other way around, so `Validator` can't reference a
type defined there), and it would buy nothing -- every plausible
history-aware check only needs "the previously-accumulated values of type
`T`", which is already exactly what `openArray[T]` provides.

## `seen` spans every `.parse()` call on a spec instance, by design

Nothing in argumint resets an `Arg`'s accumulated state between repeated
`.parse()` calls on the same already-built spec tuple, and that's
intentional, desired behavior, not a gap -- so `seen` reflects everything
ever matched across every `.parse()` call made on that spec instance, not
just the current call. A caller who wants `unique()`/`checkSeen` scoped to
just one `.parse()` invocation should wrap their spec construction in a
builder proc and call it fresh each time:

```nim
proc mySpec(): auto = (tags: opts[string]("--tag", validator = unique[string]()))
let s = mySpec()
s.parse(args = @["--tag=a", "--tag=a"], command = "prog") # ValidationError
```

This already works with zero library changes, since it re-runs the
original construction code -- which also correctly rebinds any Command's
`handler` closure to that invocation's own fresh Args, something a
hypothetical library-provided deep-copy-the-tuple operation could not do:
`CommandArg` (`backend.nim`) discards the caller's nested tuple after
building its own `Spec`, keeping only the already-built `Spec` and a
`handler` closure bound to the *original* tuple -- so cloning an
already-built spec containing a Command would leave that Command's handler
pointing at stale, pre-clone data with no way to rebind it short of
re-running the original `command(...)` call. No dedicated library API was
added for this; the builder-proc idiom is the documented answer.

## No scalar/multi-value guard

Attaching `unique()`/`checkSeen` to a scalar (non-multi) `arg`/`opt` is
allowed, undocumented behavior -- there's no `SpecDefect` construction-time
guard against it. Within a single `.parse()` call it's inert (the FSM
already prevents a scalar Arg from matching twice there, so `seen` is
always empty), but it becomes meaningful across repeated `.parse()` calls
on a reused spec tuple, per the point above.
