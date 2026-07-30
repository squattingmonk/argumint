## `FlagClamp[T]` for `flag*`'s `clamp` param: `clamp` pins a value to a
## `Slice[T]` and `adjust` runs an arbitrary proc, both applied silently
## (never raising, unlike a `Validator`) after every Flag Operation. See
## `docs/adr/0016-flag-clamp.md`.

import std/math

type
  FlagClampKind = enum
    fckRange, fckAdjust

  FlagClamp*[T] = ref object
    desc: string ## Optional override shown instead of the auto-generated
                 ## help text below (`fckRange` only -- `fckAdjust` has no
                 ## auto-generated text to override); "" means no override.
    case kind: FlagClampKind
    of fckRange:
      bounds: Slice[T]
    of fckAdjust:
      adjustProc: proc (v: T): T

proc noClamp*[T](): FlagClamp[T] = nil
  ## A call-based `nil` `FlagClamp[T]`, for constructors that need `T`
  ## resolvable without a bracket -- a bare `nil` literal default doesn't
  ## work there. See `docs/gotchas.md`.

proc clamp*[T](bounds: Slice[T], desc = ""): FlagClamp[T] =
  ## Returns a `FlagClamp` that pins a Flag's value to `bounds` after every
  ## Flag Operation, silently -- never raises. Requires `T` to support `<`
  ## (duck-typed at the point `apply` is actually called, same as
  ## `argumint/validators`' own `range`). Not named `range` -- that name
  ## collides ambiguously with `argumint/validators`' `range` the moment
  ## both modules are imported together (identical `(Slice[T], desc = "")`
  ## shape). `clamp` itself doesn't collide with `system.clamp`/
  ## `std/math.clamp` (both take a value as their first, required arg, a
  ## different shape from this proc's `Slice[T]` first arg) -- confirmed via
  ## scratch compile, not assumed. See `docs/adr/0016-flag-clamp.md`.
  FlagClamp[T](kind: fckRange, bounds: bounds, desc: desc)

proc adjust*[T](adjustProc: proc (v: T): T, desc = ""): FlagClamp[T] =
  ## Returns a `FlagClamp` that runs `adjustProc` on a Flag's value after
  ## every Flag Operation, silently -- never raises. Works for any `T`,
  ## including one with no natural total order (e.g. `set[E]`, where
  ## `clamp`'s `<`/`>` semantics would be meaningless). `desc`, if given, is
  ## shown in help text; otherwise nothing is shown, since an arbitrary proc
  ## has no auto-generated description.
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
  ## meaningful to show. `self.desc`, if non-empty, is shown instead. Same
  ## name as `argumint/validators`' `Validator[T].help` -- unlike `range`
  ## above, this doesn't collide: the two take different concrete parameter
  ## types (`FlagClamp[T]` vs `Validator[T]`), which Nim's overload
  ## resolution filters on before return type would ever matter. See
  ## `docs/adr/0016-flag-clamp.md` for a case that looked like the same
  ## problem but wasn't.
  if self.desc.len > 0:
    return self.desc
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
      check clamp(0..10, desc = "verbosity level").help() == "verbosity level"
      check adjust(proc (v: int): int = v, desc = "rounded to nearest 5").help() ==
        "rounded to nearest 5"

    test "clamp works for any T supporting <, e.g. char":
      let c = clamp('a'..'z')
      check c.apply('A') == 'a'
      check c.apply('!') == 'a'
      check c.apply('m') == 'm'
