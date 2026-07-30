# `arg`/`opt`/`args`/`opts`/`flag` all get `default(T)` fallback *and* a bare-call shorthand

Supersedes ADR 0023.

ADR 0023 gave `arg[T]`/`opt[T]` a `default(T)` fallback (so `opt[float]("--v")`
works, yielding `0.0`) at the cost of dropping their bare, no-`[T]`-no-`default`
call (`arg("<name>")`, previously `""`) -- ruled a necessary breaking change
after two non-breaking mechanisms were spiked and both failed once
`validator: Validator[T] = nil` was in the signature.

`flag*` (`src/argumint.nim`) was never touched by that ADR and is left
inconsistent: it still declares `default: T = false`, a concrete `bool`
literal, so `flag[int]("--verbose")` (explicit `T`, no `default`) doesn't
compile. Fixing it the same way ADR 0023 fixed `arg`/`opt` -- one proc,
`default: T = default(T)` -- was rejected outright: unlike `arg`/`opt`,
where non-`string` bare calls were always rare, `flag("--verbose")`'s bare
bool inference is `flag`'s dominant, everyday call shape (~40+ sites across
`tests`/`examples`). Losing it isn't an acceptable trade. A separately-named
proc (e.g. `boolFlag`) was also rejected -- one more name to learn for what
should be the same constructor.

## The two-overload mechanism ADR 0023 rejected turns out to work

ADR 0023's second rejected option -- "a generic proc with `default(T)` plus
a non-generic proc for the bare case" -- was ruled out because it "broke
the moment the real parameter list was used", i.e. once `validator:
Validator[T] = nil` was added back. Chasing a fix for `flag`, we re-tested
this mechanism against `flag`'s real shape (`variantHelp`, `variantValues`,
`env`, `clamp`, `configKey`) and found the failure is narrower than that
writeup implies:

- A non-generic overload declared *before or after* a generic `default(T)`
  overload still hard-fails with `cannot instantiate: 'T'` for the
  bracket-less call, confirmed via scratch compile in both orders -- this
  matches ADR 0023's finding, and rules out `T: not bool` or any other
  constraint as a fix, since the failure aborts compilation before overload
  resolution ever gets to prefer a candidate.
- But `variantValues: Table[string, T] = initTable[string, T]()` -- also a
  parameter whose *type* depends on `T` -- is never poisonous on its own.
  Isolating each parameter showed the actual trigger is specifically
  `clamp: FlagClamp[T] = nil` (structurally identical to `arg`/`opt`'s
  `validator: Validator[T] = nil`): a **bare `nil` literal** default for a
  ref-generic type. `Table[string, T]`'s call-based default
  (`initTable[string, T]()`) doesn't have this problem.
- Swapping the literal for a call-based equivalent -- `noClamp[T]():
  FlagClamp[T] = nil` (`argumint/flagclamp`), `noValidator[T]():
  Validator[T] = nil` (`argumint/validators`) -- removes the poison
  entirely. Verified via scratch compile against each constructor's full
  real parameter shape: every one of the four call shapes below now
  compiles and resolves to the right overload, for `arg`, `opt`, `args`,
  `opts`, and `flag` alike.

See `docs/gotchas.md` for the underlying mechanism in more detail.

## Decision

Give each of `arg*`, `opt*`, `args*`, `opts*`, `flag*` a pair of overloads
instead of one proc:

- The existing generic proc, unchanged in shape, gains the `default(T)`
  fallback: `default: T = default(T)` (`default: seq[T] = newSeq[T]()` was
  already there for `args`/`opts`), and its `Validator[T]`/`FlagClamp[T]`
  parameter defaults to `noValidator[T]()`/`noClamp[T]()` instead of `nil`.
- A new non-generic overload provides the bare-call convenience, delegating
  to the generic one via an explicit bracket call (no logic duplication):
  `arg*(variants: string, default: string = "", ...) = arg[string](...)`,
  and correspondingly for `opt*`/`args*`/`opts*` (`string`/`seq[string]`)
  and `flag*` (`bool`).

This gives every one of these four call shapes, for all five constructors:

- bare call (no `[T]`, no `default`) -> the non-generic overload, `T`'s
  natural default (`""`, `@[]`, or `false`)
- explicit `[T]`, no `default` -> the generic overload, `default(T)`
- no `[T]`, explicit `default` -> the generic overload, `T` inferred from
  the default's type (unchanged from before)
- an explicit bracket matching the non-generic overload's own type (e.g.
  `arg[string](...)`, `flag[bool](...)`) -> harmlessly re-enters the
  generic overload with the same result; not an error, so no `not X`
  constraint is needed on any of these generics

`noValidator*`/`noClamp*` are exported, not private, alongside `Validator`/
`FlagClamp` themselves -- the mechanism they exist for (a call-based empty
default, not a literal one) is worth surfacing to a caller writing their
own generic constructor against argumint's types, not just hidden as an
internal workaround.

`args*`/`opts*` never had a bare-call shorthand, even before ADR 0023 --
`newSeq[T]()` had no literal-default equivalent to anchor `T`. They gain
one now anyway, for symmetry: all four scalar/seq constructors, plus
`flag`, follow the identical two-overload pattern.

## Not a breaking change

Every call shape ADR 0023 left compiling keeps compiling identically. The
bare-call shapes it dropped return; `flag`/`args`/`opts` gain call shapes
that never worked before. No release has shipped since ADR 0023's commit
(`a6400c8`, 103 commits past the last tag, `0.1.0`, itself untagged), so
that commit was reverted outright rather than layered on top of.

## `flag*`'s bare-bool overload has one more constraint: declaration order

`flag*`'s non-generic overload's body calls `flag[bool](...)` eagerly. That
instantiation needs `"bool"` already registered in the compile-time
`flagOps` table, which only happens once `defineFlag bool, ...` is reached
further down `src/argumint.nim`. So `flag*(bool)` is declared textually
*after* that `defineFlag` call, not beside `flag*[T]` with the other
constructors. `arg`/`opt`/`args`/`opts`'s non-generic overloads have no
such dependency -- their bodies just build a `ValueArg` object directly --
so they stay beside their generic counterparts.
