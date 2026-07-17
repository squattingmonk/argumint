import std/[sequtils, strformat, strutils, sugar]

import ./lexer

type
  ValidationError* = object of CatchableError

  ValidatorKind = enum
    vkChoice, vkRange, vkCheck, vkCheckSeen, vkAll, vkAny

  Validator*[T] = ref object
    desc: string ## Optional override shown instead of the per-kind
                 ## auto-generated help/failure text below; "" means no
                 ## override. Declared outside the `case` so every kind
                 ## shares one field -- a field name can't be redeclared
                 ## across separate `of` branches, even with an identical
                 ## type in each, but a field declared before the `case`
                 ## discriminator is implicitly shared by all of them.
    case kind: ValidatorKind
    of vkChoice:
      choices: seq[T]
    of vkRange:
      range: Slice[T]
    of vkCheck:
      checker: proc (x: T): bool
    of vkCheckSeen:
      seenChecker: proc (value: T, seen: openArray[T]): bool
    of vkAll, vkAny:
      validators: seq[Validator[T]]

proc choice*[T](choices: openArray[T], desc = ""): Validator[T] =
  ## Returns a `Validator` that checks if a value is in `choices`. `desc`,
  ## if given, is shown instead of the auto-generated help/failure text
  ## (e.g. "choices: foo, bar, baz" / "got X but expected one of [...]").
  Validator[T](kind: vkChoice, choices: @choices, desc: desc)

proc range*[T](range: Slice[T], desc = ""): Validator[T] =
  ## Returns a `Validator` that checks if a value is in `range`. `desc`,
  ## if given, is shown instead of the auto-generated help/failure text
  ## (e.g. "range: a..b" / "got X but expected one of a..b").
  Validator[T](kind: vkRange, range: range, desc: desc)

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

proc checkSeen*[T](checker: proc (value: T, seen: openArray[T]): bool, desc = ""): Validator[T] =
  ## Returns a `Validator` whose check depends on both the candidate
  ## `value` and `seen`, the values already accumulated for the same Arg so
  ## far (in encounter order, not including `value` itself). `seen` reflects
  ## everything matched across every `parse` call ever made on the Arg's
  ## spec tuple, not just the current call -- wrap spec construction in a
  ## proc and call it fresh if you want `seen` scoped to just one `parse`
  ## call. `desc` may be shown to the user to explain the condition. See
  ## `unique` for the most common use case.
  Validator[T](kind: vkCheckSeen, seenChecker: checker, desc: desc)

template checkSeenIt*[T](pred: untyped, desc = ""): Validator[T] =
  ## Convenience template mirroring `checkIt`: the candidate value is `it`
  ## and the previously-accumulated values are `seen`. Since neither type
  ## can be inferred, `T` must be given explicitly. `desc` falls back to the
  ## string form of `pred` if not supplied.
  checkSeen[T]((it, seen) => pred, if desc.len > 0: desc else: astToStr(pred))

proc unique*[T](desc = ""): Validator[T] =
  ## Returns a `Validator` that rejects a value already present among the
  ## values previously matched for the same multi-value Arg. Only requires
  ## `==` on `T` (a linear scan), not `hash()`. See `checkSeen`'s doc
  ## comment for what `seen` reflects across repeated `parse` calls.
  checkSeen[T](proc (value: T, seen: openArray[T]): bool = value notin seen,
    if desc.len > 0: desc else: "must be unique")

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
  Validator[T](kind: vkAll, validators: @validators, desc: desc)

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
  Validator[T](kind: vkAny, validators: @validators, desc: desc)

proc any*[T](validators: varargs[Validator[T]]): Validator[T] =
  ## Same as `any(validators, desc = "")`. See `all`'s equivalent overload
  ## for why this can't just be a default parameter value.
  any[T](validators, "")

proc help*[T](self: Validator[T]): string =
  ## Returns a short description of what values `self` accepts, suitable for
  ## display in help text (e.g. "choices: foo, bar, baz"), or "" if there's
  ## nothing meaningful to show. Every kind shows `self.desc` directly
  ## instead, when it's non-empty.
  if self.desc.len > 0:
    return self.desc
  case self.kind
  of vkChoice:
    "choices: " & self.choices.mapIt($it).join(", ")
  of vkRange:
    fmt"range: {self.range.a}..{self.range.b}"
  of vkCheck, vkCheckSeen:
    "" # desc is required to say anything meaningful; already checked above
  of vkAll, vkAny:
    var parts: seq[string]
    for v in self.validators:
      let h = v.help()
      parts.add(if v.kind in {vkAll, vkAny}: fmt"({h})" else: h)
    parts.join(if self.kind == vkAll: " and " else: " or ")

proc candidateValues[T](self: Validator[T]): seq[T] =
  ## Every value `self` would accept, or `@[]` if `self` isn't enumerable.
  ## Stays in `T`-space so `vkAll`'s re-validation step below can call
  ## `validate` directly -- this module has no access to argumint.nim's
  ## string converters, so stringifying earlier would lose that ability.
  case self.kind
  of vkChoice:
    result = self.choices
  of vkRange, vkCheck, vkCheckSeen:
    discard # not enumerable -- a range/predicate can't list its own domain
  of vkAny:
    # OR semantics: any candidate satisfying any child is valid, so the
    # union of every child's own candidates is correct.
    for v in self.validators:
      for c in v.candidateValues():
        if c notin result: result.add c
  of vkAll:
    # Intersect enumerable children's candidates, then re-validate each
    # survivor against every child (including non-enumerable ones like
    # `check(isEven)`) so they still filter the set.
    var base: seq[T]
    var haveBase = false
    for v in self.validators:
      let c = v.candidateValues()
      if c.len == 0: continue
      if not haveBase:
        base = c
        haveBase = true
      else:
        base = base.filterIt(it in c)
    if not haveBase:
      return @[]
    for candidate in base:
      var ok = true
      for v in self.validators:
        try:
          v.validate(candidate)
        except ValidationError:
          ok = false
          break
      if ok:
        result.add candidate

proc completions*[T](self: Validator[T]): seq[string] =
  ## Every value `self` would accept, stringified (`$`), or `@[]` if `self`
  ## isn't enumerable (a `range`/`check`/`checkSeen`, or an `all`/`any`
  ## composite with no enumerable branch) -- callers should treat an empty
  ## result as "no candidates," not as an error.
  self.candidateValues().mapIt($it)

proc validate*[T](self: Validator[T], value: T, seen: openArray[T] = newSeq[T]()) =
  ## Checks if `value` satisfies `validator`. If it does not, raises a
  ## `ValidationError`. `seen` is the values already accumulated for the
  ## same Arg so far (not including `value`), consulted only by
  ## `vkCheckSeen`-kind validators (see `checkSeen`) -- every other kind
  ## ignores it.
  let tmpVal =
    when value is string: value.escape
    else: $value
  case self.kind
  of vkChoice:
    if value notin self.choices:
      if self.desc.len > 0:
        raise newException(ValidationError, fmt"{tmpVal} did not meet condition: {self.desc}")
      else:
        raise newException(ValidationError, fmt"got {tmpVal} but expected one of {$self.choices}")
  of vkRange:
    if value notin self.range:
      if self.desc.len > 0:
        raise newException(ValidationError, fmt"{tmpVal} did not meet condition: {self.desc}")
      else:
        raise newException(ValidationError, fmt"got {tmpVal} but expected one of {$self.range}")
  of vkCheck:
    if not self.checker(value):
      let desc = if self.desc.len > 0: fmt": {self.desc}" else: ""
      raise newException(ValidationError, fmt"{tmpVal} did not meet condition{desc}")
  of vkCheckSeen:
    if not self.seenChecker(value, seen):
      let desc = if self.desc.len > 0: fmt": {self.desc}" else: ""
      raise newException(ValidationError, fmt"{tmpVal} did not meet condition{desc}")
  of vkAll:
    for v in self.validators:
      try:
        v.validate(value, seen)
      except ValidationError:
        if self.desc.len > 0:
          raise newException(ValidationError, fmt"{tmpVal} did not meet condition: {self.desc}")
        else:
          raise
  of vkAny:
    var passed = false
    for v in self.validators:
      try:
        v.validate(value, seen)
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

    test "Choice/Range desc override replaces both the auto-generated help and failure text":
      let c = choice(["foo", "bar"], desc = "must be foo or bar")
      check c.help() == "must be foo or bar"
      var caught = ""
      try:
        c.validate("qux")
      except ValidationError as e:
        caught = e.msg
      check caught == "\"qux\" did not meet condition: must be foo or bar"

      let r = range(0..4, desc = "must be 0-4")
      check r.help() == "must be 0-4"
      caught = ""
      try:
        r.validate(5)
      except ValidationError as e:
        caught = e.msg
      check caught == "5 did not meet condition: must be 0-4"

      # no desc given -- falls back to the auto-generated text, as before
      check choice(["foo", "bar"]).help() == "choices: foo, bar"
      check range(0..4).help() == "range: 0..4"

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

    test "checkSeenIt passes it and seen through to the predicate":
      let validator = checkSeenIt[int](it notin seen, "must not repeat")
      validator.validate(1, seen = @[])
      validator.validate(3, seen = @[1, 2])

      var caught = ""
      try:
        validator.validate(2, seen = @[1, 2])
      except ValidationError as e:
        caught = e.msg
      check caught == "2 did not meet condition: must not repeat"

    test "unique rejects a value already in seen, using == only":
      let intValidator = unique[int]()
      intValidator.validate(3, seen = @[1, 2])

      var caught = ""
      try:
        intValidator.validate(2, seen = @[1, 2])
      except ValidationError as e:
        caught = e.msg
      check caught == "2 did not meet condition: must be unique"

      # only requires `==`, not `hash()` -- a type with no `hash` still works
      let strValidator = unique[string]()
      strValidator.validate("c", seen = @["a", "b"])
      expect ValidationError:
        strValidator.validate("b", seen = @["a", "b"])

    test "unique with a desc override reports it directly":
      let validator = unique[int](desc = "no repeated tags")
      var caught = ""
      try:
        validator.validate(2, seen = @[1, 2])
      except ValidationError as e:
        caught = e.msg
      check caught == "2 did not meet condition: no repeated tags"

    test "unique defaults to an empty seen when none is given":
      let validator = unique[int]()
      validator.validate(1) # no `seen` passed -- defaults to empty, always passes

    test "All and Any thread seen through unchanged to a checkSeen child":
      let validator = all(range(0..100), unique[int]())
      validator.validate(3, seen = @[1, 2])

      var caught = ""
      try:
        validator.validate(2, seen = @[1, 2])
      except ValidationError as e:
        caught = e.msg
      check caught == "2 did not meet condition: must be unique"

      let anyValidator = any(choice([1, 3, 5]), unique[int]())
      anyValidator.validate(7, seen = @[1, 2]) # fails choice, but unique still passes
      expect ValidationError:
        anyValidator.validate(2, seen = @[1, 2]) # fails both choice and unique

    test "All and Any require at least one Validator":
      expect SpecDefect:
        discard all[int]()
      expect SpecDefect:
        discard any[int]()

    test "Choice completions returns its own choices, stringified":
      check choice(["foo", "bar", "baz"]).completions() == @["foo", "bar", "baz"]
      check choice([1, 3, 5]).completions() == @["1", "3", "5"]

    test "Range/Check/CheckSeen aren't enumerable -- completions is empty":
      check range(0..4).completions() == newSeq[string]()
      check checkIt[int](it mod 2 == 0).completions() == newSeq[string]()
      check checkSeenIt[int](it notin seen).completions() == newSeq[string]()

    test "Any completions is the union of every child's own completions":
      check any(choice([1, 3, 5]), choice([3, 5, 7])).completions() == @["1", "3", "5", "7"]
      # a non-enumerable child contributes nothing, but doesn't blank out siblings
      check any(choice([1, 3]), range(10..20)).completions() == @["1", "3"]

    test "All completions intersects enumerable children, then re-validates against every child":
      let validator = all(choice(["a", "bb", "ccc"]), checkIt[string](it.len <= 2))
      check validator.completions() == @["a", "bb"]

      # no enumerable child at all -- nothing to intersect from
      check all(range(0..100), checkIt[int](it mod 2 == 0)).completions() == newSeq[string]()

    test "All/Any completions nest without flattening":
      let validator = all(range(0..100), any(choice([4, 7, 101]), choice([4, 200])))
      # union of the nested any's completions (4, 7, 101, 200), filtered by
      # the outer range (0..100) via re-validation
      check validator.completions() == @["4", "7"]

