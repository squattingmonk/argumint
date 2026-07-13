import std/[sequtils, strformat, strutils, sugar]

import ./lexer

type
  ValidationError* = object of CatchableError

  ValidatorKind = enum
    vkChoice, vkRange, vkCheck, vkAll, vkAny

  Validator*[T] = ref object
    case kind: ValidatorKind
    of vkChoice:
      choices: seq[T]
    of vkRange:
      range: Slice[T]
    of vkCheck:
      checker: proc (x: T): bool
      desc: string
    of vkAll, vkAny:
      validators: seq[Validator[T]]
      groupDesc: string

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

proc all*[T](validators: varargs[Validator[T]], desc: string): Validator[T] =
  ## Returns a `Validator` that passes only if every one of `validators`
  ## passes (AND semantics), short-circuiting on the first failure. May
  ## itself contain another `all`/`any` `Validator` as a child, forming an
  ## arbitrary AND/OR tree -- children are never flattened into `self`.
  ## `desc`, if given, is shown directly as both the failure reason and the
  ## `help` text; otherwise the failure reason falls back to the failing
  ## child's own message verbatim, and the `help` text falls back to each
  ## child's own `help` joined with "and". Raises `SpecDefect` if
  ## `validators` is empty.
  ##
  ## `desc` has no default here (see the overload below) because Nim
  ## cannot resolve a call with more than one `varargs` element against an
  ## overload that also has a defaulted parameter following the `varargs`
  ## -- so a bare `all(a, b)` (no `desc`) must dispatch to a genuinely
  ## separate, `varargs`-only overload instead of relying on a default.
  if validators.len == 0:
    raise newException(SpecDefect, "all() requires at least one Validator")
  Validator[T](kind: vkAll, validators: @validators, groupDesc: desc)

proc all*[T](validators: varargs[Validator[T]]): Validator[T] =
  ## Same as `all(validators, desc = "")`. See the overload above for why
  ## this can't just be a default parameter value.
  all[T](validators, "")

proc any*[T](validators: varargs[Validator[T]], desc: string): Validator[T] =
  ## Returns a `Validator` that passes if at least one of `validators`
  ## passes (OR semantics). May itself contain another `all`/`any`
  ## `Validator` as a child, forming an arbitrary AND/OR tree -- children
  ## are never flattened into `self`. `desc`, if given, is shown directly
  ## as both the failure reason and the `help` text; otherwise both fall
  ## back to each child's own `help` joined with "or" (there being no
  ## single failing child to blame when none of them pass). Raises
  ## `SpecDefect` if `validators` is empty.
  ##
  ## `desc` has no default here for the same reason as `all`'s overload
  ## above -- see there.
  if validators.len == 0:
    raise newException(SpecDefect, "any() requires at least one Validator")
  Validator[T](kind: vkAny, validators: @validators, groupDesc: desc)

proc any*[T](validators: varargs[Validator[T]]): Validator[T] =
  ## Same as `any(validators, desc = "")`. See `all`'s equivalent overload
  ## for why this can't just be a default parameter value.
  any[T](validators, "")

proc help*[T](self: Validator[T]): string =
  ## Returns a short description of what values `self` accepts, suitable for
  ## display in help text (e.g. "choices: foo, bar, baz"), or "" if there's
  ## nothing meaningful to show.
  case self.kind
  of vkChoice:
    "choices: " & self.choices.mapIt($it).join(", ")
  of vkRange:
    fmt"range: {self.range.a}..{self.range.b}"
  of vkCheck:
    self.desc
  of vkAll, vkAny:
    if self.groupDesc.len > 0:
      self.groupDesc
    else:
      var parts: seq[string]
      for v in self.validators:
        let h = v.help()
        parts.add(if v.kind in {vkAll, vkAny}: fmt"({h})" else: h)
      parts.join(if self.kind == vkAll: " and " else: " or ")

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
  of vkAll:
    for v in self.validators:
      try:
        v.validate(value)
      except ValidationError:
        if self.groupDesc.len > 0:
          raise newException(ValidationError, fmt"{tmpVal} did not meet condition: {self.groupDesc}")
        else:
          raise
  of vkAny:
    var passed = false
    for v in self.validators:
      try:
        v.validate(value)
        passed = true
        break
      except ValidationError:
        discard
    if not passed:
      raise newException(ValidationError, fmt"{tmpVal} did not meet condition: {self.help()}")

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

    test "All short-circuits and passes the failing child's message through verbatim":
      let validator = all(range(0..100), checkIt[int](it mod 2 == 0, "must be even"))
      validator.validate(50)

      var caught = ""
      try:
        validator.validate(101)
      except ValidationError as e:
        caught = e.msg
      check caught == "got 101 but expected one of 0 .. 100"

      caught = ""
      try:
        validator.validate(3)
      except ValidationError as e:
        caught = e.msg
      check caught == "3 did not meet condition: must be even"

    test "All with a desc override reports it directly regardless of which child failed":
      let validator = all(
        range(0..100), checkIt[int](it mod 2 == 0, "must be even"),
        desc = "must be an even number 0-100",
      )
      var caught = ""
      try:
        validator.validate(101)
      except ValidationError as e:
        caught = e.msg
      check caught == "101 did not meet condition: must be an even number 0-100"

    test "All help text joins children with 'and', or shows the desc override":
      let validator = all(range(0..100), checkIt[int](it mod 2 == 0, "must be even"))
      check validator.help() == "range: 0..100 and must be even"

      let overridden = all(
        range(0..100), checkIt[int](it mod 2 == 0, "must be even"),
        desc = "must be an even number 0-100",
      )
      check overridden.help() == "must be an even number 0-100"

    test "Any passes if at least one child passes":
      let validator = any(choice([1, 3, 5]), range(10..20))
      validator.validate(3)
      validator.validate(15)

      var caught = ""
      try:
        validator.validate(7)
      except ValidationError as e:
        caught = e.msg
      check caught == "7 did not meet condition: choices: 1, 3, 5 or range: 10..20"

    test "Any with a desc override reports it directly instead of the joined children":
      let validator = any(choice([1, 3, 5]), range(10..20), desc = "must be 1, 3, 5, or 10-20")
      var caught = ""
      try:
        validator.validate(7)
      except ValidationError as e:
        caught = e.msg
      check caught == "7 did not meet condition: must be 1, 3, 5, or 10-20"

    test "All and Any nest without flattening, and parenthesize composite children in help":
      let validator = all(
        range(0..100),
        any(choice([1, 3, 5]), checkIt[int](it mod 2 == 0, "must be even")),
      )
      validator.validate(4) # in range; fails choice but passes even check
      validator.validate(3) # in range; passes choice

      var caught = ""
      try:
        validator.validate(101)
      except ValidationError as e:
        caught = e.msg
      check caught == "got 101 but expected one of 0 .. 100"

      caught = ""
      try:
        validator.validate(7)
      except ValidationError as e:
        caught = e.msg
      check caught == "7 did not meet condition: choices: 1, 3, 5 or must be even"

      check validator.help() == "range: 0..100 and (choices: 1, 3, 5 or must be even)"

    test "All and Any require at least one Validator":
      expect SpecDefect:
        discard all[int]()
      expect SpecDefect:
        discard any[int]()

