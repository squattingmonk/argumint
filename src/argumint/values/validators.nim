## `Validator[T]` combinators for `arg*`/`args*`/`opt*`/`opts*`'s
## `validator` param: `choice`/`range`/`check`/`checkIt`/`unique` build leaf
## validators, `checkSeen`/`checkSeenIt` see prior matches for the same Arg
## (see `docs/adr/0007-history-aware-validators.md`), and `all`/`any`
## compose them (see
## `docs/adr/0006-composable-validators-all-and-any.md`). A validator never
## runs against a coded default, only a value actually supplied by the
## user/env/config -- see
## `docs/adr/0008-validators-dont-run-against-defaults.md`.

import std/[options, sequtils, strformat, strutils, sugar]

import ./annotationtext, ./display, ../core/errors, ../text/style
export ValidationError ## Defined in `errors.nim` with the rest of the
  ## taxonomy; re-exported so importing this module alone still names what
  ## its validators raise.
export annotationtext

type
  ValidatorKind = enum
    vkChoice, vkRange, vkCheck, vkCheckSeen, vkAll, vkAny

  Validator*[T] = ref object
    desc: AnnotationText
      ## Replaces or hides the per-kind generated help below, and a custom
      ## one is the failure's reason. Declared outside the `case` so every
      ## kind shares one field -- a field name can't be redeclared across
      ## separate `of` branches, even with an identical type in each, but a
      ## field declared before the `case` discriminator is implicitly shared
      ## by all of them.
    condition: string
      ## A `checkIt`/`checkSeenIt` predicate's source: the generated help,
      ## and the failure's text after `did not meet condition: `.
    expected: string
      ## `unique`'s generated noun phrase: the help, and the failure's text
      ## after `but expected `.
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

proc noValidator*[T](): Validator[T] = nil
  ## A call-based `nil` `Validator[T]`, for constructors that need `T`
  ## resolvable without a bracket -- a bare `nil` literal default doesn't
  ## work there. See `docs/gotchas.md`.

proc choice*[T](choices: openArray[T], desc: AnnotationText = ""): Validator[T] =
  ## Returns a `Validator` that checks if a value is in `choices`. String
  ## and char choices are always shown quoted. `desc` describes what's
  ## accepted, as a noun phrase (`a NATO letter`), in place of the
  ## generated help and failure text (`choices: "foo", "bar"` / `got "x"
  ## but expected one of "foo", "bar"`); `some("")` hides the help.
  Validator[T](kind: vkChoice, choices: @choices, desc: desc)

proc range*[T](range: Slice[T], desc: AnnotationText = ""): Validator[T] =
  ## Returns a `Validator` that checks if a value is in `range`. `T` must
  ## have `<=`. `desc` describes what's accepted, as a noun phrase (`a
  ## port number`), in place of the generated help and failure text
  ## (`range: a..b` / `got X but expected a value in a..b`); `some("")`
  ## hides the help.
  when not compiles(range.a <= range.b):
    {.error: "range() needs a type with <=".}
  Validator[T](kind: vkRange, range: range, desc: desc)

proc check*[T](checker: proc (x: T): bool, desc: AnnotationText = ""): Validator[T] =
  ## Returns a `Validator` that checks if a proc called on the value returns
  ## true. `desc` describes what's accepted, as a noun phrase (`an even
  ## number`), shown in help and as the failure's reason; with none, help
  ## shows nothing and a failure says only that the value `did not meet
  ## condition`.
  Validator[T](kind: vkCheck, checker: checker, desc: desc)

proc withCondition[T](self: Validator[T], condition: string): Validator[T] =
  ## `self`, with `condition` as its generated text. For `checkIt` and
  ## `checkSeenIt`, which can't name the private field from the caller's
  ## module.
  self.condition = condition
  self

template checkIt*[T](pred: untyped, desc: AnnotationText = ""): Validator[T] =
  ## Convenience template to allow anonymous functions to be used with `check`.
  ## The variable to be checked is declared as `it`. Since the type of `it`
  ## cannot be inferred, the type `T` must be explicitly specified. `desc`
  ## describes what's accepted, as `check`'s does; with none, help shows the
  ## source of `pred`, and a failure reads `3 did not meet condition: it mod
  ## 2 == 0`.
  withCondition(check[T](it => pred, desc), astToStr(pred))

proc checkSeen*[T](checker: proc (value: T, seen: openArray[T]): bool, desc: AnnotationText = ""): Validator[T] =
  ## Returns a `Validator` whose check depends on both the candidate
  ## `value` and `seen`, the values already accumulated for the same Arg so
  ## far (in encounter order, not including `value` itself). `seen` reflects
  ## everything matched across every `parse` call ever made on the Arg's
  ## spec tuple, not just the current call -- wrap spec construction in a
  ## proc and call it fresh if you want `seen` scoped to just one `parse`
  ## call. `desc` describes what's accepted, as `check`'s does. See
  ## `unique` for the most common use case.
  Validator[T](kind: vkCheckSeen, seenChecker: checker, desc: desc)

template checkSeenIt*[T](pred: untyped, desc: AnnotationText = ""): Validator[T] =
  ## Convenience template mirroring `checkIt`: the candidate value is `it`
  ## and the previously-accumulated values are `seen`. Since neither type
  ## can be inferred, `T` must be given explicitly. With no `desc`, help and
  ## failures use the source of `pred`, as `checkIt`'s do.
  withCondition(checkSeen[T]((it, seen) => pred, desc), astToStr(pred))

proc unique*[T](desc: AnnotationText = ""): Validator[T] =
  ## Returns a `Validator` that rejects a value already present among the
  ## values previously matched for the same multi-value Arg. Only requires
  ## `==` on `T` (a linear scan), not `hash()`. See `checkSeen`'s doc
  ## comment for what `seen` reflects across repeated `parse` calls. Its
  ## generated text is `a unique value`, which `desc` can replace or hide.
  result = checkSeen[T](proc (value: T, seen: openArray[T]): bool = value notin seen, desc)
  result.expected = "a unique value"

proc all*[T](validators: varargs[Validator[T]], desc: AnnotationText): Validator[T] =
  ## Returns a `Validator` that passes only if every one of `validators`
  ## passes (AND semantics), short-circuiting on the first failure. May
  ## itself contain another `all`/`any` `Validator` as a child, forming an
  ## arbitrary AND/OR tree -- children are never flattened into `self`.
  ## `desc` describes what's accepted, as a noun phrase, shown as the help
  ## and as the failure's reason; otherwise the failure is the failing
  ## child's own message verbatim, and the help is each child's own `help`
  ## joined with "and". Raises `SpecDefect` if `validators` is empty.
  ##
  ## `desc` has no default here -- see docs/gotchas.md for why a bare
  ## `all(a, b)` needs the separate `varargs`-only overload below instead.
  if validators.len == 0:
    raise newException(SpecDefect, "all() requires at least one Validator")
  Validator[T](kind: vkAll, validators: @validators, desc: desc)

proc all*[T](validators: varargs[Validator[T]]): Validator[T] =
  ## Same as `all(validators, desc = "")`. See the overload above for why
  ## this can't just be a default parameter value.
  all[T](validators, "")

proc any*[T](validators: varargs[Validator[T]], desc: AnnotationText): Validator[T] =
  ## Returns a `Validator` that passes if at least one of `validators`
  ## passes (OR semantics). May itself contain another `all`/`any`
  ## `Validator` as a child, forming an arbitrary AND/OR tree -- children
  ## are never flattened into `self`. `desc` describes what's accepted, as
  ## a noun phrase, shown as the help and as the failure's reason;
  ## otherwise both use each child's own `help` joined with "or" (there
  ## being no single failing child to blame when none of them pass).
  ## Raises `SpecDefect` if `validators` is empty.
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

proc showRange[T](range: Slice[T]): string =
  ## `range` as help and errors show it, e.g. `0..100` or `"a".."f"`.
  range.a.showValue & ".." & range.b.showValue

proc styledHelp*[T](self: Validator[T]): StyledText

proc generatedHelp[T](self: Validator[T]): StyledText =
  ## `styledHelp` as if `self` had no `desc`.
  case self.kind
  of vkChoice:
    result = styled(srAnnotation, "choices: ")
    for i, choice in self.choices:
      if i > 0: result.add styled(", ")
      result.add styled(srLiteral, choice.showValue)
  of vkRange:
    result = styled(srAnnotation, "range: ") &
      styled(srLiteral, self.range.showRange)
  of vkCheck, vkCheckSeen:
    result = markup(self.condition & self.expected)
  of vkAll, vkAny:
    for i, v in self.validators:
      if i > 0: result.add styled(if self.kind == vkAll: " and " else: " or ")
      let h = v.styledHelp
      result.add(if v.kind in {vkAll, vkAny}: styled("(") & h & styled(")") else: h)

proc styledHelp*[T](self: Validator[T]): StyledText =
  ## `help` as Styled Text: key labels are `srAnnotation`, values
  ## `srLiteral`, and a `desc` gets Help Markup.
  let desc = Option[string](self.desc)
  if desc.isSome: markup(desc.get) else: self.generatedHelp

proc help*[T](self: Validator[T]): string =
  ## Returns a short description of what values `self` accepts, suitable for
  ## display in help text (e.g. `choices: "foo", "bar"`), or "" if there's
  ## nothing meaningful to show. A custom `desc` is shown instead, and a
  ## hidden one shows "".
  self.styledHelp.plain

proc custom(desc: AnnotationText): string =
  ## `desc`'s custom text, or "" if it's generated or hidden.
  Option[string](desc).get("")

proc validate*[T](self: Validator[T], value: T, seen: openArray[T] = []) =
  ## Checks if `value` satisfies `validator`. If it does not, raises a
  ## `ValidationError`. `seen` is the values already accumulated for the
  ## same Arg so far (not including `value`), consulted only by
  ## `vkCheckSeen`-kind validators (see `checkSeen`) -- every other kind
  ## ignores it.
  var passed = true
  case self.kind
  of vkChoice:
    passed = value in self.choices
  of vkRange:
    # Only `range` builds one, and it needs `<=`: a type without stays
    # registrable (#206).
    when compiles(value <= value):
      passed = value in self.range
  of vkCheck:
    passed = self.checker(value)
  of vkCheckSeen:
    passed = self.seenChecker(value, seen)
  of vkAll:
    for v in self.validators:
      try:
        v.validate(value, seen)
      except ValidationError:
        if self.desc.custom.len == 0: raise
        passed = false
        break
  of vkAny:
    passed = false
    for v in self.validators:
      try:
        v.validate(value, seen)
        passed = true
        break
      except ValidationError:
        discard
  if passed: return

  # Locals outside `fmt`: see docs/gotchas.md, openSym.
  let
    tmpVal = value.showValue
    custom = plainMarkup(self.desc.custom)
  if custom.len > 0:
    raise newPlainError(ValidationError, fmt"got {tmpVal} but expected {custom}")
  case self.kind
  of vkChoice:
    let choices = self.choices.mapIt(it.showValue).join(", ")
    raise newPlainError(ValidationError, fmt"got {tmpVal} but expected one of {choices}")
  of vkRange:
    let bounds = self.range.showRange
    raise newPlainError(ValidationError, fmt"got {tmpVal} but expected a value in {bounds}")
  of vkCheck, vkCheckSeen:
    let
      expected = self.expected
      condition = plainMarkup(self.condition)
    if expected.len > 0:
      raise newPlainError(ValidationError, fmt"got {tmpVal} but expected {expected}")
    let suffix = if condition.len > 0: fmt": {condition}" else: ""
    raise newPlainError(ValidationError, fmt"{tmpVal} did not meet condition{suffix}")
  of vkAny:
    let help = self.generatedHelp.plain
    raise newPlainError(ValidationError, fmt"{tmpVal} did not meet condition: {help}")
  of vkAll:
    discard # a failing child re-raised above

proc seesHistory*[T](self: Validator[T]): bool =
  ## Whether `self` is, or contains, a `checkSeen` (`checkSeenIt`, `unique`).
  ## Withheld from the facade.
  case self.kind
  of vkCheckSeen: true
  of vkAll, vkAny: self.validators.anyIt(it.seesHistory)
  else: false

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
        # Not `filterIt`: it warns for a range excluding zero (docs/gotchas.md).
        var kept: seq[T]
        for value in base:
          if value in c: kept.add value
        base = kept
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

    test "a custom Choice/Range desc replaces the generated help, and is what a failure expected":
      let c = choice(["foo", "bar"], desc = "foo or bar")
      check c.help() == "foo or bar"
      var caught = ""
      try:
        c.validate("qux")
      except ValidationError as e:
        caught = e.msg
      check caught == "got \"qux\" but expected foo or bar"

      let r = range(0..4, desc = "a small number")
      check r.help() == "a small number"
      caught = ""
      try:
        r.validate(5)
      except ValidationError as e:
        caught = e.msg
      check caught == "got 5 but expected a small number"

      # no desc given -- falls back to the auto-generated text, as before
      check choice(["foo", "bar"]).help() == "choices: \"foo\", \"bar\""
      check range(0..4).help() == "range: 0..4"

    test "Conditions":
      let
        a = checkIt[string](it.startsWith("f"))
        b = checkIt[int](it mod 2 == 0, "an even number")
      a.validate("foo")
      b.validate 2
      expect ValidationError:
        a.validate("bar")
      expect ValidationError:
        b.validate 3

    test "a failed choice lists the choices the way help does":
      var caught = ""
      try:
        choice(["date", "title"]).validate("size")
      except ValidationError as e:
        caught = e.msg
      check caught == "got \"size\" but expected one of \"date\", \"title\""

    test "string and char choices are always quoted, and escaped only where needed":
      let v = choice(["date", "a, b", "", "say \"hi\"", "café", "tab\there"])
      check v.help() == """choices: "date", "a, b", "", "say \"hi\"", "café", "tab\there""""
      var caught = ""
      try:
        v.validate("crème")
      except ValidationError as e:
        caught = e.msg
      check caught == """got "crème" but expected one of "date", "a, b", "", "say \"hi\"", "café", "tab\there""""
      check choice([',', 'x']).help() == """choices: ",", "x""""
      check choice([1, 2]).help() == "choices: 1, 2"

    test "a typed char is quoted like a typed string":
      var caught = ""
      try:
        choice([',', ';']).validate('x')
      except ValidationError as e:
        caught = e.msg
      check caught == """got "x" but expected one of ",", ";""""

    test "a char range quotes its bounds like its typed value":
      check range('a'..'f').help() == """range: "a".."f""""
      var caught = ""
      try:
        range('a'..'f').validate('z')
      except ValidationError as e:
        caught = e.msg
      check caught == """got "z" but expected a value in "a".."f""""

    test "All short-circuits and passes the failing child's message through verbatim":
      let validator = all(range(0..100), checkIt[int](it mod 2 == 0, "an even number"))
      validator.validate(50)

      var caught = ""
      try:
        validator.validate(101)
      except ValidationError as e:
        caught = e.msg
      check caught == "got 101 but expected a value in 0..100"

      caught = ""
      try:
        validator.validate(3)
      except ValidationError as e:
        caught = e.msg
      check caught == "got 3 but expected an even number"

    test "All with a custom desc expects it regardless of which child failed":
      let validator = all(
        range(0..100), checkIt[int](it mod 2 == 0, "an even number"),
        desc = "an even number from 0 to 100",
      )
      var caught = ""
      try:
        validator.validate(101)
      except ValidationError as e:
        caught = e.msg
      check caught == "got 101 but expected an even number from 0 to 100"

    test "All help text joins children with 'and', or shows the desc override":
      let validator = all(range(0..100), checkIt[int](it mod 2 == 0, "an even number"))
      check validator.help() == "range: 0..100 and an even number"

      let overridden = all(
        range(0..100), checkIt[int](it mod 2 == 0, "an even number"),
        desc = "an even number from 0 to 100",
      )
      check overridden.help() == "an even number from 0 to 100"

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

    test "Any with a custom desc expects it instead of the joined children":
      let validator = any(choice([1, 3, 5]), range(10..20), desc = "1, 3, 5, or a number from 10 to 20")
      var caught = ""
      try:
        validator.validate(7)
      except ValidationError as e:
        caught = e.msg
      check caught == "got 7 but expected 1, 3, 5, or a number from 10 to 20"

    test "All and Any nest without flattening, and parenthesize composite children in help":
      let validator = all(
        range(0..100),
        any(choice([1, 3, 5]), checkIt[int](it mod 2 == 0, "an even number")),
      )
      validator.validate(4) # in range; fails choice but passes even check
      validator.validate(3) # in range; passes choice

      var caught = ""
      try:
        validator.validate(101)
      except ValidationError as e:
        caught = e.msg
      check caught == "got 101 but expected a value in 0..100"

      caught = ""
      try:
        validator.validate(7)
      except ValidationError as e:
        caught = e.msg
      check caught == "7 did not meet condition: choices: 1, 3, 5 or an even number"

      check validator.help() == "range: 0..100 and (choices: 1, 3, 5 or an even number)"

    test "checkSeenIt passes it and seen through to the predicate":
      let validator = checkSeenIt[int](it notin seen, "a new number")
      validator.validate(1, seen = @[])
      validator.validate(3, seen = @[1, 2])

      var caught = ""
      try:
        validator.validate(2, seen = @[1, 2])
      except ValidationError as e:
        caught = e.msg
      check caught == "got 2 but expected a new number"

    test "unique rejects a value already in seen, using == only":
      let intValidator = unique[int]()
      intValidator.validate(3, seen = @[1, 2])

      var caught = ""
      try:
        intValidator.validate(2, seen = @[1, 2])
      except ValidationError as e:
        caught = e.msg
      check caught == "got 2 but expected a unique value"
      check intValidator.help() == "a unique value"

      # only requires `==`, not `hash()` -- a type with no `hash` still works
      let strValidator = unique[string]()
      strValidator.validate("c", seen = @["a", "b"])
      expect ValidationError:
        strValidator.validate("b", seen = @["a", "b"])

    test "unique with a custom desc expects it":
      let validator = unique[int](desc = "a new tag")
      var caught = ""
      try:
        validator.validate(2, seen = @[1, 2])
      except ValidationError as e:
        caught = e.msg
      check caught == "got 2 but expected a new tag"

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
      check caught == "got 2 but expected a unique value"

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

  suite "seesHistory":
    test "a checkSeen anywhere in the tree sees history; nothing else does":
      let unseen = checkSeenIt[int](it notin seen)
      check unique[int]().seesHistory
      check any(range(0..5), all(unseen)).seesHistory
      check not all(range(0..5), choice([1]), checkIt[int](it > 0)).seesHistory

  suite "styledHelp":
    proc roles(t: StyledText): seq[(StyleRole, string)] =
      for span in t.spans: result.add (span.role, span.text)

    test "labels are srAnnotation and values srLiteral":
      check choice(["a", "b"]).styledHelp.roles == @[
        (srAnnotation, "choices: "), (srLiteral, "\"a\""), (srPlain, ", "), (srLiteral, "\"b\"")]
      check range(0..4).styledHelp.roles ==
        @[(srAnnotation, "range: "), (srLiteral, "0..4")]

    test "composites keep each part's roles":
      check all(range(0..4), any(choice([1]), checkIt[int](it > 0, "`positive`"))).styledHelp.withoutTicks.roles == @[
        (srAnnotation, "range: "), (srLiteral, "0..4"), (srPlain, " and ("),
        (srAnnotation, "choices: "), (srLiteral, "1"), (srPlain, " or "),
        (srLiteral, "positive"), (srPlain, ")")]

    test "a desc gets Help Markup":
      check checkIt[int](it > 0, "not `-x`").styledHelp.withoutTicks.roles ==
        @[(srPlain, "not "), (srOption, "-x")]

    test "help is the plain text, ticks kept":
      check checkIt[int](it > 0, "not `-x`").help() == "not `-x`"

  suite "Annotation Text":
    test "a hidden desc hides every kind's help":
      check choice([1, 2], desc = some("")).help() == ""
      check range(0..4, desc = some("")).help() == ""
      let hiddenCheck = validators.check(proc (x: int): bool = true, desc = some(""))
      check hiddenCheck.help() == ""
      check checkIt[int](it > 0, some("")).help() == ""
      check checkSeen(proc (x: int, seen: openArray[int]): bool = true, desc = some("")).help() == ""
      check checkSeenIt[int](it notin seen, some("")).help() == ""
      check unique[int](desc = some("")).help() == ""
      check all(range(0..4), desc = some("")).help() == ""
      check any(range(0..4), desc = some("")).help() == ""

    proc failure[T](v: Validator[T], value: T, seen: openArray[T] = []): string =
      try:
        v.validate(value, seen)
      except ValidationError as e:
        result = e.msg

    test "a hidden desc leaves the generated failure":
      check range(0..4, desc = some("")).failure(5) == "got 5 but expected a value in 0..4"
      check choice([1, 2], desc = some("")).failure(3) == "got 3 but expected one of 1, 2"
      check checkIt[int](it mod 2 == 0, some("")).failure(3) == "3 did not meet condition: it mod 2 == 0"
      check unique[int](desc = some("")).failure(2, [2]) == "got 2 but expected a unique value"
      check all(range(0..4), desc = some("")).failure(5) == "got 5 but expected a value in 0..4"
      check any(range(0..4), desc = some("")).failure(5) == "5 did not meet condition: range: 0..4"

    test "a custom desc is what every kind's failure expected":
      let described = validators.check(proc (x: int): bool = false, desc = "a good number")
      check described.failure(3) == "got 3 but expected a good number"
      check checkSeen(proc (x: int, seen: openArray[int]): bool = false, desc = "a new number").failure(3) ==
        "got 3 but expected a new number"
      check checkIt[int](it mod 2 == 0, "a positive even number").failure(3) ==
        "got 3 but expected a positive even number"

    test "generated text keeps a frame that fits it":
      check checkIt[int](it mod 2 == 0).failure(3) == "3 did not meet condition: it mod 2 == 0"
      check checkIt[int](it mod 2 == 0).help() == "it mod 2 == 0"
      check checkSeenIt[int](it notin seen).failure(2, [2]) == "2 did not meet condition: it notin seen"
      let plain = validators.check(proc (x: int): bool = false)
      check plain.failure(3) == "3 did not meet condition"
      check plain.help() == ""

  suite "desc in failure messages":
    test "reads as it would with no styler: ticks kept, escapes collapsed":
      for v in [choice([1], desc = "one of ``1``"), checkIt[int](it > 1, "one of ``1``")]:
        try:
          v.validate(0)
          fail()
        except ValidationError as e:
          check e.msg == "got 0 but expected one of `1`"

