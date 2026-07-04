import std/[strformat, strutils, sugar]

type
  ValidationError* = object of CatchableError

  ValidatorKind = enum
    vkChoice, vkRange, vkCheck

  Validator*[T] = ref object
    case kind: ValidatorKind
    of vkChoice:
      choices: seq[T]
    of vkRange:
      range: Slice[T]
    of vkCheck:
      checker: proc (x: T): bool
      desc: string

proc choice*[T](choices: openArray[T]): Validator[T] =
  ## Returns a `Validator` that checks if a value is in `choices`.
  Validator[T](kind: vkChoice, choices: @choices)

proc range*[T](range: Slice[T]): Validator[T] =
  ## Returns a `Validator` that checks if a value is in `range`.
  Validator[T](kind: vkRange, range: range)

proc check*[T](checker: proc (x: T): bool, desc = ""): Validator[T] =
  ## Returns a `Validator` that checks if a proc called on the value returns
  ## true. `desc` may be shown to the user to explain the condition the value
  ## must meet to pass the check.
  Validator[T](kind: vkCheck, checker: checker, desc: desc)

template checkIt*[T](pred: untyped, desc = ""): Validator[T] =
  ## Convenience template to allow anonymous functions to be used with `check`.
  ## The variable to be checked is declared as `it`. Since the type of `it`
  ## cannot be inferred, the type `T` must be explicitly specified. `desc` may
  ## be shown to the user to explain the condition the value must meet to pass
  ## the check; if not supplied, the string form of `pred` will be used.
  check[T](it => pred, if desc.len > 0: desc else: astToStr(pred))

proc validate*[T](self: Validator[T], value: T) =
  ## Checks if `value` satisfies `validator`. If it does not, raises a
  ## `ValidationError`.
  let tmpVal =
    when value is string: value.escape
    else: $value
  case self.kind
  of vkChoice:
    if value notin self.choices:
      raise newException(ValidationError, fmt"got {tmpVal} but expected one of {$self.choices}")
  of vkRange:
    if value notin self.range:
      raise newException(ValidationError, fmt"got {tmpVal} but expected one of {$self.range}")
  of vkCheck:
    if not self.checker(value):
      let desc = if self.desc.len > 0: fmt": {self.desc}" else: ""
      raise newException(ValidationError, fmt"{tmpVal} did not meet condition{desc}")

when isMainModule:
  import std/[unittest]

  suite "Validators":
    test "Choices":
      let a = choice(["foo", "bar", "baz"])
      a.validate("foo")
      expect ValidationError:
        a.validate("qux")

      let b = choice([1, 3, 5])
      b.validate(1)
      expect ValidationError:
        b.validate(2)

    test "Ranges":
      let validator = range(0..4)
      validator.validate(2)
      expect ValidationError:
        validator.validate(5)


    test "Conditions":
      let
        a = checkIt[string](it.startsWith("f"))
        b = checkIt[int](it mod 2 == 0, "must be even")
      a.validate("foo")
      b.validate 2
      expect ValidationError:
        a.validate("bar")
      expect ValidationError:
        b.validate 3

