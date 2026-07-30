# `arg`/`opt` fall back to `default(T)`, matching `args`/`opts`, dropping the bare-call string shorthand

> **Superseded by
> [ADR 0024](0024-flag-arg-opt-default-t-and-bare-call.md)**: the
> two-overload mechanism ruled out below turned out to work once the bare
> `nil` literal default poisoning it was replaced with a call-based one.
> The bare-call shorthand this ADR dropped has been restored, without
> losing the `default(T)` fallback motivating this decision. The empirical
> writeup below is kept because it's still accurate as far as it goes.

Requested: `opt[float]("--volume=<v>")` (explicit `T`, no `default` given)
should just work, yielding `0.0`, the same convenience `args[T]()`/`opts[T]()`
already have via `newSeq[T]()`. Today it's a compile error --
`arg*`/`opt*` (`src/argumint.nim`) declare `default: T = ""`, a concrete
string literal that only typechecks when `T` is `string`.

## Two non-breaking mechanisms were tried and empirically ruled out

Both were spiked with real scratch compiles (Nim 2.2.10) before deciding to
break anything, per this project's usual practice of verifying uncertain
Nim mechanics rather than reasoning about them in the abstract.

**1. A default generic-parameter type (`[T: not seq = string]`).** This
feature is real and works, for both generic types
(`type Pair[A; B = int]`, `Pair[string]` fills `B = int`) and generic procs
(`proc arg1[T; M: static bool = false](...)`, `arg1[int](...)` fills
`M = false`). But it **only ever activates through bracket syntax** -- a
fully bracket-less call never consults a generic parameter's declared
default, whether that default lives on the proc's own `T` or (separately
confirmed) on the *return type*'s own defaulted `T`
(`ValueArg[T: not seq = string, M: static bool]` compiles fine as a type,
but wiring a proc's bracket-less call through it changes nothing -- the
proc's own `T` binding and the return type's `T` binding are separate,
non-communicating sites). Since `arg("<name>")` needs to stay bracket-less,
this mechanism structurally cannot reach it.

**2. Two overloads** -- a generic proc with `default: T = default(T)` plus a
non-generic `string`-only proc for the bare case. This worked cleanly in
isolation. It broke the moment the real parameter list was used, because
`arg`/`opt` also carry `validator: Validator[T] = nil`. Confirmed, via a
parameter-reordering test, that this isn't an overload-resolution artifact
at all: even a *single*, non-overloaded proc with `default: T = default(T)`
and `validator: Validator[T] = nil` fails identically
(`Error: cannot instantiate: 'T'`) for the bracket-less call, regardless of
declaration order. The only reason today's shipped code works is that
`default: T = ""` is a concrete literal, letting Nim resolve `T = string`
early enough (Nim elaborates parameter defaults left-to-right) for
`Validator[T]` to concretize to `Validator[string]` afterward -- reordering
`validator` before `default` breaks even the *current*, already-working
code the same way. Swap `""` for the circular `default(T)` and nothing
anchors `T` for the bracket-less call, so `Validator[T]`'s type can't be
built for any candidate -- this kills the call outright, before overload
resolution ever gets a chance to prefer the non-generic fallback.

See `docs/gotchas.md` for the full empirical writeup of finding #2 -- it's
worth knowing on its own, independent of this decision, since it explains a
genuinely fragile (if currently working) property of the existing code.

## Decision

Drop the bare-call convenience. `default: T = ""` becomes
`default: T = default(T)`, with no second overload and no generic-parameter
default -- a single proc per constructor:

```nim
proc arg*[T: not seq](variants: string, default: T = default(T), ...): ValueArg[T, false] = ...
proc opt*[T: not seq](variants: string, default: T = default(T), ...): ValueArg[T, false] = ...
```

Exactly two call shapes are supported now:

- Explicit `[T]`, no `default` -> `default(T)` (the motivating case:
  `opt[float]("--v")` -> `0.0`).
- No `[T]`, explicit `default = value` -> `T` inferred from the value, same
  as before (argument-driven inference never inspects the default
  expression, so this path is unaffected by the change).

`arg("<name>")` -- no `[T]`, no `default` -- is now a compile error
(`cannot instantiate: 'T'`). Every call site relying on that shorthand
needs an explicit `[string]` or `default = "..."` added; see the migration
commit for the mechanical sweep across `tests/`, `examples/`, and the
README.

## This also makes `arg`/`opt` consistent with `args`/`opts`

`args*`/`opts*` never supported the bare, no-`T`-no-`default` shape --
`args("<foo>")` has always failed with `cannot instantiate: 'T: not seq'`,
since `newSeq[T]()` needs `T` from somewhere too. `arg`/`opt`'s bare-string
shorthand was never a designed convenience shared across all four
constructors; it was incidental to `""` happening to be a concrete literal
that `args`/`opts`'s `newSeq[T]()` never had an equivalent for. All four
constructors now follow the same single rule -- supply either an explicit
`[T]` or an explicit `default`, always -- rather than the singular forms
special-casing `string` while the plural forms never could. A user moving
from `arg(...)` to `args(...)` (or back) no longer needs to relearn a
different inference rule.

## Considered options

- **Keep the bare-call shorthand and add `default(T)` support alongside
  it** via a default generic-parameter type or a second overload: rejected
  -- both empirically fail once `Validator[T] = nil` is in the signature,
  see above. Not a matter of trying harder; the bracket-only scoping of
  generic defaults and the eager-instantiation requirement of a
  generic-typed default parameter are both structural properties of how
  Nim resolves calls, not implementation details this library controls.
- **A distinctly-named second constructor** (e.g. `argOf[T]`/`optOf[T]`),
  per the precedent `docs/gotchas.md` already recommends for a related
  overload failure: rejected in favor of changing `arg`/`opt` directly --
  it would have avoided the breaking change, but at the cost of leaving
  `arg`/`opt` permanently inconsistent with `args`/`opts`, and adding a
  fifth/sixth constructor name for what's really one coherent rule across
  all of them.
