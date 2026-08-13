## `FlagClamp[T]` for `flag*`'s `clamp` param: `clamp` pins a value to a
## `Slice[T]` and `adjust` runs an arbitrary proc, both applied silently
## (never raising, unlike a `Validator`) after every Flag Operation. See
## `docs/adr/0016-flag-clamp.md`.

import std/math
import std/options

type
  FlagClampKind = enum
    fckRange, fckAdjust

  FlagClamp*[T] = ref object
    desc: Option[string] ## `none` (the default) shows the auto-generated
                          ## help text below (`fckRange` only -- `fckAdjust`
                          ## has no auto-generated text); `some("...")`
                          ## overrides it; `some("")` suppresses help output
                          ## entirely, regardless of auto-generation.
    case kind: FlagClampKind
    of fckRange:
      bounds: Slice[T]
    of fckAdjust:
      adjustProc: proc (v: T): T

proc noClamp*[T](): FlagClamp[T] = nil
  ## A call-based `nil` `FlagClamp[T]`, for constructors that need `T`
  ## resolvable without a bracket -- a bare `nil` literal default doesn't
  ## work there. See `docs/gotchas.md`.

proc clamp*[T](bounds: Slice[T], desc = none(string)): FlagClamp[T] =
  ## Returns a `FlagClamp` that pins a Flag's value to `bounds` after every
  ## Flag Operation, silently -- never raises. Requires `T` to support `<`
  ## (duck-typed at the point `apply` is actually called, same as
  ## `argumint/validators`' own `range`). Not named `range` -- that name
  ## collides ambiguously with `argumint/validators`' `range` the moment
  ## both modules are imported together (identical `(Slice[T], desc = "")`
  ## shape). `clamp` itself doesn't collide with `system.clamp`/
  ## `std/math.clamp` (both take a value as their first, required arg, a
  ## different shape from this proc's `Slice[T]` first arg) -- confirmed via
  ## scratch compile, not assumed. See `docs/adr/0016-flag-clamp.md`. `desc`
  ## is `some("")` to suppress help output entirely, or `some("...")` to
  ## override the auto-generated text -- see `help*` below and issue #12.
  FlagClamp[T](kind: fckRange, bounds: bounds, desc: desc)

proc adjust*[T](adjustProc: proc (v: T): T, desc = none(string)): FlagClamp[T] =
  ## Returns a `FlagClamp` that runs `adjustProc` on a Flag's value after
  ## every Flag Operation, silently -- never raises. Works for any `T`,
  ## including one with no natural total order (e.g. `set[E]`, where
  ## `clamp`'s `<`/`>` semantics would be meaningless). `desc`, if
  ## `some("...")`, is shown in help text; otherwise nothing is shown,
  ## since an arbitrary proc has no auto-generated description. `some("")`
  ## is a no-op here (there's nothing to suppress by default), kept only
  ## for symmetry with `clamp`.
  FlagClamp[T](kind: fckAdjust, adjustProc: adjustProc, desc: desc)

proc apply*[T](self: FlagClamp[T], value: T): T =
  ## Returns `value` adjusted by `self` -- pinned to `self`'s bounds
  ## (`clamp`) or passed through `self`'s proc (`adjust`).
  case self.kind
  of fckRange: math.clamp(value, self.bounds)
  of fckAdjust: self.adjustProc(value)

proc help*[T](self: FlagClamp[T]): string =
  ## Returns a short description of `self`'s constraint, suitable for
  ## display in help text (e.g. "clamp: 0..10"), or "" if there's nothing
  ## meaningful to show. `self.desc`, if `some("...")`, is shown instead of
  ## the auto-generated text; if `some("")`, suppresses help output
  ## entirely (see issue #12) regardless of what auto-generation would
  ## otherwise produce. Same name as `argumint/validators`'
  ## `Validator[T].help` -- unlike `range` above, this doesn't collide: the
  ## two take different concrete parameter types (`FlagClamp[T]` vs
  ## `Validator[T]`), which Nim's overload resolution filters on before
  ## return type would ever matter. See `docs/adr/0016-flag-clamp.md` for a
  ## case that looked like the same problem but wasn't.
  if self.desc.isSome:
    return self.desc.get
  case self.kind
  of fckRange: "clamp: " & $self.bounds.a & ".." & $self.bounds.b
  of fckAdjust: ""

when isMainModule:
  import std/unittest

  type Rank = enum rBronze, rSilver, rGold

  suite "FlagClamp":
    test "clamp pins a value above, below, and within bounds":
      let c = clamp(0..10)
      check c.apply(15) == 10
      check c.apply(-5) == 0
      check c.apply(7) == 7

    test "adjust runs an arbitrary proc, including for a type with no total order":
      let c = adjust(proc (v: set[Rank]): set[Rank] = v * {rBronze, rSilver, rGold})
      check c.apply({rBronze, rGold}) == {rBronze, rGold}
      check c.apply({}) == {}

    test "help shows auto-generated text for clamp, nothing for adjust, unless desc overrides":
      check clamp(0..10).help() == "clamp: 0..10"
      check adjust(proc (v: int): int = v).help() == ""
      check clamp(0..10, desc = some("verbosity level")).help() == "verbosity level"
      check adjust(proc (v: int): int = v, desc = some("rounded to nearest 5")).help() ==
        "rounded to nearest 5"

    test "desc = some(\"\") suppresses help output entirely, overriding auto-generation":
      check clamp(0..10, desc = some("")).help() == ""
      check adjust(proc (v: int): int = v, desc = some("")).help() == ""

    test "clamp works for any T supporting <, e.g. char":
      let c = clamp('a'..'z')
      check c.apply('A') == 'a'
      check c.apply('!') == 'a'
      check c.apply('m') == 'm'
