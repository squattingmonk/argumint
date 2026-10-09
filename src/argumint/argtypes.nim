## The `ValueArg`/`ValuesArg`/`FlagArg` data model and every piece of
## machinery that touches their private fields: `ValueArgBase`, `FlagArgBase`
## and the hooks their methods call, `fromString`, the Flag Operations a
## `FlagOp` holds, the `initValueArg`/`initValuesArg`/`initFlagArg`
## constructors, and the `rawValue`/`rawDefault` read accessors.
##
## Everything here is exported so `argumint.nim` can reach it, and none of
## it is re-exported by that facade -- the public names (`arg`/`opt`/
## `flag`, `get`, `flagOp`/`flagOpIt`) and their documentation stay there,
## written against this machinery. See
## `docs/adr/0043-facade-machinery-seam.md`; `argumint/argtypes` is an
## implementation detail, not an import path users are meant to type.
##
## The split is forced rather than stylistic: `std/importutils.privateAccess`
## does not survive instantiation in another module, so anything generic or
## templated that reads a private field has to live beside the type. See
## `docs/gotchas.md`.

{.experimental: "openSym".}

import std/[enumutils, fenv, math, options, pegs, sequtils, strformat, strutils, tables, typetraits]

import ./[backend, configsource, display, errors, flagclamp, style, validators]

type
  Description = tuple[defaultStr: string, validatorHelp: StyledText, completions: seq[string]]
    ## What `describe` computes for help and completion, all at once.

  ValueArgBase* = ref object of Arg
    ## The untyped base of `ValueArg[T]` and `ValuesArg[T]`. Not generic, so
    ## its methods are ordinary methods that dispatch; the few that touch
    ## typed storage call a hook its leaf's constructor filled in. A new base
    ## method needs a hook only if it touches typed storage. See
    ## `docs/architecture.md`, Value Conversion.
    env: Option[EnvSource]
    cfgKey: ConfigKey
      ## Not named `configKey` -- that's the base `Arg` method name.
    multi: bool
      ## Whether this is a `ValuesArg`; what `accumulates` returns.
    write: proc (self: ValueArgBase, c: Contribution, how: Arbitration) {.nimcall.}
      ## Converts, validates and stores `c`: `accept`'s body.
    reset: proc (self: ValueArgBase) {.nimcall.}
      ## Empties the typed storage, so the default shows through.
    describe: proc (self: ValueArgBase): Description {.nimcall.}
      ## `defaultStr`, `validatorHelp` and `completions`, computed when help
      ## or completion asks rather than on every run.

  ValueArg*[T: not seq] = ref object of ValueArgBase
    ## What `arg*`/`opt*` return: one value of type `T`. Nameable so an arg
    ## can cross a proc or module boundary; its fields stay private, same
    ## shape as `Spec` -- see `docs/adr/0033-value-arg-flag-arg-exported.md`.
    value: Option[T]
      ## `none` until a tier or a write supplies a value; see `toT`.
    default: T
    validator: Validator[T]

  ValuesArg*[T: not seq] = ref object of ValueArgBase
    ## What `args*`/`opts*` return: any number of values of type `T`.
    ## Nameable on the same terms as `ValueArg`.
    value: Option[seq[T]]
      ## `none` until a tier or a write supplies a value, so `some(@[])`
      ## (supplied empty) reads back empty; see `toSeqT`.
    default: seq[T]
    validator: Validator[T]

  AnyValueArg[T] = ValueArg[T] | ValuesArg[T]
    ## Either arity, for the logic they share.

  FlagOp*[T] = object
    ## One FlagOp Alias group, built by `flagOp*`/`flagOpIt*` and consumed
    ## by `flag*`'s `ops` param: every spelling in `spellings` runs `apply`
    ## on the flag's value. Nameable; its fields stay private.
    spellings: seq[string]
    apply: proc (value: var T)
    desc: string
      ## The Flag Operation Description: the `help` given, else one
      ## generated from a named op, else empty.

  BoundOp = object
    ## A Flag Operation stored on a `FlagArgBase`: its `FlagOp`'s `apply`,
    ## bound to the flag's storage and clamp.
    apply: proc (self: FlagArgBase)
    desc: string
    group: int
      ## Which `FlagOp` it came from: two Variants are FlagOp Aliases if
      ## they share one.

  FlagArgBase* = ref object of Arg
    ## The untyped base of `FlagArg[T]`, on the same terms as
    ## `ValueArgBase`. After construction, nothing reads anything of a
    ## Flag Operation but its Variant.
    env: Option[EnvSource]
    cfgKey: ConfigKey
      ## Not named `configKey` -- that's the base `Arg` method name.
    ops: OrderedTable[string, BoundOp]
      ## Every Variant, in declared order, and the Flag Operation it runs.
    reset: proc (self: FlagArgBase) {.nimcall.}
      ## Restores the default.
    describe: proc (self: FlagArgBase): StyledText {.nimcall.}
      ## The clamp's help, if any.

  FlagArg*[T] = ref object of FlagArgBase
    ## What `flag*` returns. Nameable on the same terms as `ValueArg` --
    ## type public, fields private.
    value: T
    default: T
    clamp: FlagClamp[T]

# ------------------------------------------------------------------------------
# String conversion. Every string-to-`T` conversion goes through `fromString`,
# which calls these by name: a converter used implicitly in a generic is only
# found where the generic is used (docs/gotchas.md). They stay private, and
# aren't converters at all, so `let n: int = "5"` doesn't compile for anyone
# who imports argumint.
# ------------------------------------------------------------------------------

type
  BuiltInValue = SomeNumber | string | bool | char
    ## The types `fromString` converts by name.
  ValueType = concept v
    ## What `fromString` can convert to: see CONTEXT.md, Value Type. Not a
    ## constraint, only checked with `isnot`: a failed match as a constraint
    ## says `concept predicate failed`, not which converter to write.
    v is BuiltInValue or v is enum or compiles((let converted: typeof(v) = ""))
  OutOfRangeError = object of ValueError
    ## A number `fromString` read but `T` can't hold, e.g. `expected a value
    ## in -128..127`.

proc toBool(value: string): bool =
  ## Parses a string value into a bool. Supports on/off, yes/no, y/n, YES/NO,
  ## Y/N, true/false, TRUE/FALSE, and 1/0.
  value.parseBool

proc toChar(value: string): char =
  ## Converts a string value to a char. The value must be 1 character long.
  if value.len != 1:
    raise newException(ValueError, fmt"cannot convert {value} to char")
  value[0]

proc outOfRange(bounds: string): ref OutOfRangeError =
  newException(OutOfRangeError, "expected a value in " & bounds)

proc isInteger(value: string): bool =
  ## Whether `value` is written as an integer, whatever its size.
  let digits = if value.startsWith('-') or value.startsWith('+'): value[1..^1] else: value
  digits.len > 0 and digits.allCharsInSet(Digits)

proc toNumber[T: SomeNumber](value: string): T =
  ## Parses a string value into a `T`, raising `OutOfRangeError` if `T`
  ## can't hold it. Negative numbers may be passed as arguments by prefixing
  ## them with a space, so whitespace characters are stripped to allow this.
  let value = value.strip
  let bounds = $low(T) & ".." & $high(T)
  when T is SomeFloat:
    let parsed = value.parseFloat
    if parsed < low(T) or parsed > high(T) or (T is system.range and parsed.isNaN):
      raise outOfRange(bounds)
    elif parsed.classify notin {fcInf, fcNegInf} and T(parsed).classify in {fcInf, fcNegInf}:
      # Finite, but too large for `float32`, whose bounds are infinite.
      let largest = $maximumPositiveValue(T)
      raise outOfRange("-" & largest & ".." & largest)
    T(parsed)
  else:
    try:
      let parsed = when T is SomeSignedInt: value.parseBiggestInt
                   else: value.parseBiggestUInt
      if parsed < typeof(parsed)(low(T)) or parsed > typeof(parsed)(high(T)):
        raise outOfRange(bounds)
      T(parsed)
    except OutOfRangeError:
      raise
    except ValueError:
      # Too large for a `BiggestInt`, or negative for an unsigned type.
      if value.isInteger: raise outOfRange(bounds)
      raise

template parsesByName(T: typedesc): bool =
  ## Whether `fromString` parses `T` with `parseEnum`: an enum with no
  ## converter of its own where its Arg is built (docs/gotchas.md).
  T is enum and not compiles((let converted: T = ""))

proc fromString[T](value: string): T =
  ## `value` as a `T`: a built-in by name, an enum with no converter by
  ## `parseEnum`, and anything else through the user's converter, found
  ## where the Arg is built. Raises `ValueError` if it can't convert, and
  ## `OutOfRangeError` if it's a number `T` can't hold.
  when T is BuiltInValue:
    when T is string: value
    elif T is bool: toBool(value)
    elif T is char: toChar(value)
    else: toNumber[T](value)
  elif parsesByName(T): parseEnum[T](value)
  else:
    let converted: T = value
    converted

proc typeNoun(T: typedesc): string =
  ## What a value that isn't a `T` was expected to be.
  when T is SomeInteger: "an integer"
  elif T is SomeFloat: "a number"
  else: $T

proc zeroValue*[T](): T =
  ## The value an Arg given no default holds: `default(T)`, unless that's
  ## outside a range type, or isn't one of an enum's values, where it's the
  ## lowest value.
  when T is enum: low(T)
  elif T is SomeNumber:
    when low(T) > 0 or high(T) < 0: low(T) else: default(T)
  else:
    default(T)

# ------------------------------------------------------------------------------
# Read accessors. `argumint.nim`'s `get*`/`toT*`/`toSeqT*` are written against
# these: a template rather than a proc so reading a `ValuesArg` doesn't copy
# the seq, and so `get*` stays the lazy template ADR 0040 needs. Reads only --
# writes go through the constructors below, which can't leave `ops` and
# `aliases` disagreeing the way an exported mutator could.
# ------------------------------------------------------------------------------

template rawValue*[T](arg: AnyValueArg[T]): untyped =
  ## `arg`'s stored value, with no default substitution: `none` until a
  ## Value Precedence tier or a write supplies one.
  arg.value

template rawDefault*[T](arg: AnyValueArg[T]): untyped =
  ## `arg`'s coded default.
  arg.default

template rawValue*[T](arg: FlagArg[T]): untyped =
  ## `arg`'s current value, already carrying its coded default.
  arg.value

template rawDefault*[T](arg: FlagArg[T]): untyped =
  ## `arg`'s coded default value.
  arg.default

# ------------------------------------------------------------------------------
# Writing a value. The two arities differ only in `history` and `store`; the
# rest is written once over `AnyValueArg`.
# ------------------------------------------------------------------------------

proc history[T](self: ValueArg[T]): seq[T] =
  ## What a Validator checks a new value against when it extends: the value
  ## already held, if any.
  if self.value.isSome: result.add self.value.get

proc history[T](self: ValuesArg[T]): seq[T] =
  ## What a Validator checks a new value against when it extends: every
  ## value already held.
  if self.value.isSome: result = self.value.get

proc store[T](self: ValueArg[T], value: T) =
  ## Holds `value` in place of any other.
  self.value = some(value)

proc store[T](self: ValuesArg[T], value: T) =
  ## Appends `value`, in place: see the ORC entry in docs/gotchas.md.
  if self.value.isSome: self.value.get.add value
  else: self.value = some(@[value])

proc replaceImpl*[T: not seq](self: ValuesArg[T], values: seq[T], seenBy: Option[SeenBy], validate: bool) =
  ## Validates every candidate in `values` against the prefix of `values`
  ## already accepted -- `self`'s own prior values never enter that history,
  ## since they're about to be discarded -- then, only if all of them pass,
  ## overwrites `self.value` and `self.seenBy` in one step. No `arbitration`
  ## call: unlike `putImpl`, `replaceImpl` always applies, tier or no tier,
  ## which is what lets it demote. Raising mid-validation leaves both fields
  ## untouched, so there's no `clear()` to undo on failure.
  try:
    if validate and not self.validator.isNil:
      for idx, value in values:
        self.validator.validate(value, values[0..<idx])
  except ValidationError as e:
    let name = self.name() # Outside `fmt`: see docs/gotchas.md, openSym.
    raise newPlainError(ValidationError, fmt"for {name}, {e.msg}")
  self.value = some(values)
  self.seenBy = seenBy.get(otherwise = self.seenBy)

proc storeImpl[T](self: AnyValueArg[T], value: T, c: Contribution, how: Arbitration, validate: bool) =
  ## Stores an already-arbitrated `value`: runs the Validator against the
  ## history `how` implies (`history` when extending, none when replacing,
  ## since those values are about to be discarded), then clears on
  ## `arReplace` and stores. Raises a `ValidationError` naming `self` via
  ## `subject(c)`, leaving `self` untouched.
  try:
    if validate and not self.validator.isNil:
      case how
      of arExtend: self.validator.validate(value, self.history)
      of arReplace: self.validator.validate(value)
  except ValidationError as e:
    let subject = self.subject(c) # Outside `fmt`: see docs/gotchas.md, openSym.
    raise newPlainError(ValidationError, fmt"for {subject}, {e.msg}")
  if how == arReplace:
    self.clear
  self.store(value)

proc putImpl*[T](self: AnyValueArg[T], value: T, seenBy: Option[SeenBy], validate: bool) =
  ## `parse`'s arbitration for a value already typed `T` -- backs `put`
  ## (`argumint.nim`). No Variant was typed, so an error names `self`'s
  ## first one.
  let how = self.arbitration(seenBy)
  if how.isNone:
    return
  self.storeImpl(value, Contribution(tier: seenBy), how.get, validate)
  if how.get == arReplace:
    self.seenBy = seenBy.get

proc enumValues[T: enum](): seq[T] =
  ## Every value of `T`, gaps and all.
  when T is HoleyEnum:
    for value in enumutils.items(T): result.add value
  else:
    for value in T: result.add value

proc describedBy[T](self: AnyValueArg[T]): Validator[T] =
  ## The Validator completion and a conversion error describe `self` with.
  ## An enum argumint parses lists its values, filtered by `self`'s own
  ## Validator, unless that lists values of its own.
  when parsesByName(T):
    let values = choice(enumValues[T]())
    if self.validator.isNil: values
    elif self.validator.completions.len > 0: self.validator
    else: all(values, self.validator)
  else:
    self.validator

proc helpDescribedBy[T](self: AnyValueArg[T]): Validator[T] =
  ## `describedBy` for help: the enum's values alone when `self`'s Validator
  ## has nothing to say, rather than `all`'s dangling " and ".
  when parsesByName(T):
    if not self.validator.isNil and self.validator.styledHelp.len == 0:
      return choice(enumValues[T]())
  self.describedBy

proc acceptImpl[T](self: AnyValueArg[T], c: Contribution, how: Arbitration) =
  ## Converts `c.value` into a `T`, then stores it. Raises `ParseError` if it
  ## can't convert.
  try:
    self.storeImpl(fromString[T](c.value), c, how, validate = true)
  except OutOfRangeError as e:
    # Outside `fmt`: see docs/gotchas.md, openSym.
    let (got, subject, expected) = (c.value.quoted, self.subject(c), e.msg)
    raise newPlainError(ParseError, fmt"for {subject}, got {got} but {expected}")
  except ValueError:
    # Outside `fmt`: see docs/gotchas.md, openSym.
    let (got, subject) = (c.value.quoted, self.subject(c))
    when parsesByName(T):
      let values = self.describedBy.completions.join(", ")
      raise newPlainError(ParseError, fmt"for {subject}, got {got} but expected one of {values}")
    else:
      let what = typeNoun(T)
      raise newPlainError(ParseError, fmt"expected {what} for {subject} but got {got}")

proc defaultText[T](self: ValueArg[T]): string =
  ## `self`'s default as help shows it, or "" if it's still `zeroValue` (e.g.
  ## "", 0, or false) -- the fallback used when no default was given (see
  ## `arg*`). Requires `T` to support `default(T)` and `==`, which nearly
  ## every type does; a `{.requiresInit.}` object would be a rare exception
  ## that fails to compile here.
  if self.default != zeroValue[T](): display.showValue(self.default) else: ""

proc defaultText[T](self: ValuesArg[T]): string =
  ## `self`'s defaults comma-joined, or "" if there are none.
  self.default.mapIt(display.showValue(it)).join(", ")

# The hooks each constructor gives its `ValueArgBase`, instantiated for its
# leaf type `A`: see `ValueArgBase`.

proc writeHook[A](self: ValueArgBase, c: Contribution, how: Arbitration) =
  ## Converts, validates and stores `c`: see `acceptImpl`.
  A(self).acceptImpl(c, how)

proc resetHook[A](self: ValueArgBase) =
  ## Back to `none`: the coded default is substituted at read time, never
  ## stored (see `docs/adr/0008-validators-dont-run-against-defaults.md`).
  A(self).value = typeof(A(self).value).default

proc describeHook[A](self: ValueArgBase): Description =
  ## What help and completion show for `self`: see `describedBy`.
  let
    arg = A(self)
    forHelp = arg.helpDescribedBy
    forCompletion = arg.describedBy
  result.defaultStr = arg.defaultText
  if not forHelp.isNil: result.validatorHelp = forHelp.styledHelp
  if not forCompletion.isNil: result.completions = forCompletion.completions

method accept(self: ValueArgBase, c: Contribution, how: Arbitration) =
  self.write(self, c, how)

method clear(self: ValueArgBase) =
  ## Removes `self`'s `seenBy` provenance and its value, so its coded
  ## default shows through.
  procCall clear(Arg(self))
  self.reset(self)

method accumulates(self: ValueArgBase): bool = self.multi

method envSource(self: ValueArgBase): Option[EnvSource] = self.env

method configKey(self: ValueArgBase): ConfigKey = self.cfgKey

method defaultStr(self: ValueArgBase): string = self.describe(self).defaultStr

method validatorHelp(self: ValueArgBase): StyledText = self.describe(self).validatorHelp

method completions(self: ValueArgBase): seq[string] = self.describe(self).completions

# ------------------------------------------------------------------------------
# Flag Operations. Each is a closure on the flag's value: a named op built by
# `namedOp`, a type's Implicit Operation, or the user's own proc. Named ops and
# Implicit Operations on numbers stop at `T`'s bounds rather than overflowing.
# ------------------------------------------------------------------------------

proc splitFlagSpellings*(variants: string): seq[string] =
  ## Parses a comma-separated list of bare flag spellings (`-f`/`--flag`).
  ## Shared by `flag*`'s own `variants` string and each `flagOp*`'s.
  if variants.len == 0: return @[]
  for rawName in variants.split(Comma):
    if rawName =~ FlagVariantFormat:
      result.add matches[0]
    else:
      let escapedRawName = strutils.escape(rawName)
      raise newException(SpecDefect, fmt"Cannot parse flag spelling {escapedRawName}: must be in the format '-f' or '--flag'")

proc addSat[B: SomeInteger](a, b: B): B =
  ## `a + b`, stopping at `B`'s bounds, checked before adding.
  if b >= 0: (if a > high(B) - b: high(B) else: a + b)
  else: (if a < low(B) - b: low(B) else: a + b)

proc subSat[B: SomeInteger](a, b: B): B =
  ## `a - b`, stopping at `B`'s bounds, checked before subtracting.
  if b >= 0: (if a < low(B) + b: low(B) else: a - b)
  else: (if a > high(B) + b: high(B) else: a - b)

proc mulSat[B: SomeInteger](a, b: B): B =
  ## `a * b`, stopping at `B`'s bounds, checked before multiplying. Each
  ## sign case divides by the operand that can't make the division overflow.
  if a == 0 or b == 0: B(0)
  else:
    when B is SomeUnsignedInt:
      if a > high(B) div b: high(B) else: a * b
    else:
      if a > 0 and b > 0: (if a > high(B) div b: high(B) else: a * b)
      elif a < 0 and b < 0: (if a < high(B) div b: high(B) else: a * b)
      elif a < 0: (if a < low(B) div b: low(B) else: a * b)
      else: (if b < low(B) div a: low(B) else: a * b)

proc stepped[T: SomeNumber](value: T, op: char, by: SomeNumber): T =
  ## `value op by` (`op` is `+`, `-` or `*`), stopping at `T`'s bounds: an
  ## integer never overflows, and a range type never leaves its range. Done
  ## in `T`'s base type, which `by` must fit, though it may lie outside
  ## `T`'s range.
  type Base = typeof(low(T) + low(T))
  let (current, by) = (Base(value), Base(by))
  let exact =
    when T is SomeFloat:
      case op
      of '+': current + by
      of '-': current - by
      else: current * by
    else:
      case op
      of '+': current.addSat(by)
      of '-': current.subSat(by)
      else: current.mulSat(by)
  T(clamp(exact, Base(low(T)), Base(high(T))))

template supports(T: typedesc, opEq, op: untyped): bool =
  ## Whether `T` can do a named op: `opEq` itself, or the `op` it's named
  ## for.
  compiles((var current = default(T); opEq(current, default(T)))) or
    compiles((var current = default(T); current = op(current, default(T))))

proc opError*[T](op: string): string =
  ## Why `T` can't do the named Flag Operation `op`, or "" if it can.
  ## `flagOp*` reports it at compile time and the string form of `ops` at
  ## run time, so both say the same thing.
  proc needs(op, operator: string, supported: bool): string =
    if supported: "" else: "`" & op & "` needs `" & operator & "` for " & $T
  case op
  of "=": ""
  of "+=": needs(op, "+", supports(T, `+=`, `+`))
  of "-=": needs(op, "-", supports(T, `-=`, `-`))
  of "*=": needs(op, "*", supports(T, `*=`, `*`))
  else: "`" & op & "` is not a Flag Operation: use `=`, `+=`, `-=` or `*=`"

template combine(current, by, opEq, op: untyped) =
  ## `current opEq by` if that compiles, else `current = current op by`.
  when compiles(opEq(current, by)): opEq(current, by)
  else: current = op(current, by)

proc namedOp*[T](op: string, value: T): proc (current: var T) =
  ## The closure the named Flag Operation `op` runs with `value`. Raises
  ## `SpecDefect` with `opError`'s message if `T` can't do it.
  let error = opError[T](op)
  if error.len > 0:
    raise newException(SpecDefect, error)
  when T is SomeNumber:
    case op
    of "+=": return proc (current: var T) = current = current.stepped('+', value)
    of "-=": return proc (current: var T) = current = current.stepped('-', value)
    of "*=": return proc (current: var T) = current = current.stepped('*', value)
    else: discard
  else:
    case op
    of "+=":
      when supports(T, `+=`, `+`):
        return proc (current: var T) = combine(current, value, `+=`, `+`)
    of "-=":
      when supports(T, `-=`, `-`):
        return proc (current: var T) = combine(current, value, `-=`, `-`)
    of "*=":
      when supports(T, `*=`, `*`):
        return proc (current: var T) = combine(current, value, `*=`, `*`)
    else: discard
  proc (current: var T) = current = value

proc describeOp*[T](op: string, value: T): string =
  ## The Flag Operation Description generated for a named op: see
  ## CONTEXT.md. A set's elements are listed.
  when T is set:
    var shown: seq[string]
    for element in value: shown.add display.showValue(element)
    let text = if shown.len == 0: "none" else: shown.join(", ")
    case op
    of "=": "Set to " & text
    of "+=": "Add " & text
    of "-=": "Remove " & text
    else: "Keep only " & text
  else:
    let text = display.showValue(value)
    case op
    of "=": "Set to " & text
    of "+=": "Increase by " & text
    of "-=": "Decrease by " & text
    else: "Multiply by " & text

proc next[T: enum](value: T): T =
  ## The value declared after `value`, or `value` if it's the last.
  when T is HoleyEnum:
    result = value
    var found = false
    for declared in enumutils.items(T):
      if found: return declared
      found = declared == value
  else:
    if value < high(T): succ(value) else: value

proc initFlagOp*[T](variants: string, apply: proc (value: var T), desc: string): FlagOp[T] =
  ## A `FlagOp` for `flagOp*`/`flagOpIt*`, splitting `variants` into
  ## spellings.
  FlagOp[T](spellings: splitFlagSpellings(variants), apply: apply, desc: desc)

proc implicitOp[T](default: T): FlagOp[T] =
  ## `T`'s Implicit Operation, which a flag's bare variants run, or one with
  ## no `apply` if `T` has none.
  when T is bool:
    let opposite = not default
    FlagOp[T](apply: proc (value: var T) = value = opposite, desc: "Set to " & $opposite)
  elif T is SomeInteger:
    FlagOp[T](apply: proc (value: var T) = value = value.stepped('+', 1), desc: "Increase by 1")
  elif T is enum:
    FlagOp[T](apply: proc (value: var T) = value = value.next, desc: "Move to the next value")
  else:
    FlagOp[T]()

proc bindOp[T](op: FlagOp[T], group: int): BoundOp =
  ## `op` bound to a `FlagArg[T]`'s value, then its clamp. Its own proc, not
  ## inline in `initFlagArg`'s loop: see docs/gotchas.md, closures in loops.
  let apply = op.apply
  BoundOp(desc: op.desc, group: group, apply: proc (self: FlagArgBase) =
    let flag = FlagArg[T](self)
    apply(flag.value)
    if not flag.clamp.isNil:
      flag.value = flag.clamp.apply(flag.value))

proc parseFlagOpsString*[T](ops: string): seq[FlagOp[T]] =
  ## Parses `flag*`'s convenience `ops: string` overload: each comma item
  ## is `<flag><op><value>`, becoming its own single-spelling FlagOp Alias
  ## group -- sugar for the matching `flagOp*` call. The value is read with
  ## `fromString`; for a `set[E]`, as one `E`. See
  ## `docs/adr/0028-flag-ops-string-convenience.md`.
  for rawName in ops.split(Comma):
    var matches: array[3, string]
    if not rawName.match(FlagOpVariantFormat, matches):
      var unknown: array[1, string]
      if rawName.match(UnknownFlagOpFormat, unknown):
        raise newException(SpecDefect, opError[T](unknown[0]))
      let escapedRawName = strutils.escape(rawName)
      let helpText = strutils.dedent("""

        Flag ops entries must be in the format '<flag><op><value>', where:
          - '<flag>' is in the format '-f' or '--flag'
          - '<op>' is '=', '+=', '-=' or '*='
          - '<value>' is the value the operation applies
        Examples: '--foo=true' or '--bar+=1'. A bare spelling with no op
        belongs in flag*'s own `variants` string instead.""")
      raise newException(SpecDefect, fmt"Cannot parse flag ops entry {escapedRawName}:" & helpText)
    let (spelling, op, text) = (matches[0], matches[1], matches[2])
    let error = opError[T](op)
    if error.len > 0:
      raise newException(SpecDefect, error)
    let value =
      try:
        when T is set: {fromString[typeof(elementType(default(T)))](text)}
        else: fromString[T](text)
      except ValueError as e:
        raise newException(SpecDefect, fmt"unexpected flag value for {spelling}: {e.msg}")
    result.add FlagOp[T](spellings: @[spelling], apply: namedOp(op, value), desc: describeOp(op, value))

proc putImpl*[T](self: FlagArg[T], value: T, seenBy: Option[SeenBy]) =
  ## Sets the value of `self` directly, arbitrating against `seenBy` like
  ## every other write, then clamping -- unconditionally and with no
  ## Validator, since a `FlagArg` has neither. No `variant`/`validate`
  ## params: nothing here can raise, so there's no message to give context
  ## to and no check to opt out of. See
  ## `docs/adr/0044-put-typed-write-accessor.md`.
  let how = self.arbitration(seenBy)
  if how.isNone:
    return
  if how.get == arReplace:
    self.clear
    self.seenBy = seenBy.get
  self.value = value
  if not self.clamp.isNil:
    self.value = self.clamp.apply(self.value)

# The hooks `initFlagArg` gives its `FlagArgBase`, instantiated for its leaf
# type `A`: see `FlagArgBase`.

proc resetFlagHook[A](self: FlagArgBase) =
  A(self).value = A(self).default

proc describeFlagHook[A](self: FlagArgBase): StyledText =
  let clamp = A(self).clamp
  if not clamp.isNil: result = clamp.styledHelp

method accept(self: FlagArgBase, c: Contribution, how: Arbitration) =
  ## `c.value` is the Variant whose Flag Operation applies, on every tier.
  if not self.ops.hasKey(c.value):
    raise newPlainError(ParseError, "$# is not a known variant for the flag $#" % [c.value.quoted, self.subject(c)])
  if how == arReplace:
    self.clear
  self.ops[c.value].apply(self)

method clear(self: FlagArgBase) =
  ## Removes the `seenBy` provenance and restores the default value of `self`.
  procCall clear(Arg(self))
  self.reset(self)

method accumulates(self: FlagArgBase): bool = true

method validatorHelp(self: FlagArgBase): StyledText = self.describe(self)

method variantDesc(self: FlagArgBase, variant: string): string =
  ## `variant`'s Flag Operation Description, empty unless the flag's
  ## descriptions diverge: see ADR 0063.
  if not self.ops.hasKey(variant): return ""
  result = self.ops[variant].desc
  for op in self.ops.values:
    if op.desc != result: return
  result = ""

method envSource(self: FlagArgBase): Option[EnvSource] = self.env

method configKey(self: FlagArgBase): ConfigKey = self.cfgKey

method aliases(self: FlagArgBase, a, b: string): bool =
  ## Whether `a` and `b`, both Variants of `self`, are FlagOp Aliases: the
  ## spellings of one `flagOp`, or both bare.
  a == b or self.ops[a].group == self.ops[b].group

# ------------------------------------------------------------------------------
# Constructors. `argumint.nim`'s `arg*`/`args*`/`opt*`/`opts*`/`flag*` are thin
# delegations to these -- they're generic, so `privateAccess` can't rescue them
# on the far side of the module boundary (see docs/gotchas.md).
# ------------------------------------------------------------------------------

template requireValueType(T: typedesc) =
  ## Stops compilation unless `fromString` can convert to `T`.
  when T isnot ValueType:
    {.error: $T & " is not a value type: define `converter to" & $T & "(value: string): " &
      $T & "` where its Arg is built".}

template initAnyValueArg(A: typedesc, isMulti: bool): untyped =
  ## The body `initValueArg`/`initValuesArg` share, reading their params.
  A(kind: kind, variants: variants.split(Comma), default: default,
    help: help, group: group.groupOr(kind), hidden: hidden, validator: validator,
    env: env, cfgKey: cfgKey, multi: isMulti,
    write: writeHook[A], reset: resetHook[A], describe: describeHook[A])

proc initValueArg*[T: not seq](kind: ArgKind, variants: string, default: T,
    help: HelpText, group: string, hidden: bool, validator: Validator[T],
    env = none(EnvSource), cfgKey = noConfigKey()): ValueArg[T] =
  ## Builds a `ValueArg[T]`, splitting `variants` on commas. Behind `arg*`
  ## (`kind = Positional`, no `env`/`cfgKey`) and `opt*` (`kind =
  ## Optional`). Call it with named arguments: `help`/`group` are adjacent
  ## same-typed parameters that a positional call could swap silently.
  requireValueType(T)
  initAnyValueArg(ValueArg[T], false)

proc initValuesArg*[T: not seq](kind: ArgKind, variants: string, default: seq[T],
    help: HelpText, group: string, hidden: bool, validator: Validator[T],
    env = none(EnvSource), cfgKey = noConfigKey()): ValuesArg[T] =
  ## Builds a `ValuesArg[T]`, behind `args*` and `opts*`. See
  ## `initValueArg`.
  requireValueType(T)
  initAnyValueArg(ValuesArg[T], true)

proc initFlagArg*[T](variants: string, ops: openArray[FlagOp[T]], default: T,
    help: HelpText, group: string, hidden: bool, clamp: FlagClamp[T],
    env: Option[EnvSource], cfgKey: ConfigKey): FlagArg[T] =
  ## Builds a `FlagArg[T]` in full -- its bound ops, duplicate-variant
  ## detection, and the clamp-versus-default check -- behind `argumint.nim`'s
  ## `flag*`. Call it with named arguments, same as `initValueArg` above.
  ## Bare spellings in `variants` run `T`'s Implicit Operation, and form one
  ## FlagOp Alias group; each of `ops` forms its own, even if two run the
  ## same operation (see docs/adr/0027).
  result = FlagArg[T](kind: Flag, variants: @[], value: default, default: default,
    help: help, group: group.groupOr(Flag), hidden: hidden, clamp: clamp, env: env, cfgKey: cfgKey,
    reset: resetFlagHook[FlagArg[T]], describe: describeFlagHook[FlagArg[T]])
  var implicit = implicitOp(default)
  implicit.spellings = splitFlagSpellings(variants)
  if implicit.spellings.len > 0 and implicit.apply.isNil:
    let name = implicit.spellings[0]
    raise newException(SpecDefect,
      fmt"{name} has no operation: {$T} has no Implicit Operation; give it a proc with `flagOp`")
  if not clamp.isNil and clamp.apply(default) != default:
    let name =
      if implicit.spellings.len > 0: implicit.spellings[0]
      elif ops.len > 0 and ops[0].spellings.len > 0: ops[0].spellings[0]
      else: ""
    raise newException(SpecDefect, fmt"default {default} for flag {name} does not satisfy its own clamp")
  for group, op in @[implicit] & @ops:
    let bound = bindOp(op, group)
    for name in op.spellings:
      if result.ops.hasKeyOrPut(name, bound):
        raise newException(SpecDefect, fmt"duplicate variant for {name}")
      result.variants.add name

when isMainModule:
  ## Tests for what no importer can name: the private conversions, the
  ## saturating arithmetic behind named ops and Implicit Operations, and
  ## `FlagArgBase`'s methods driven by hand. `tests/test_flag_ops.nim` covers
  ## flags through the full pipeline.
  import std/unittest

  type Rank = enum
    rLow, rMid, rHigh

  converter toRank(value: string): Rank = parseEnum[Rank](value)

  type Grade = enum
    gPoor, gFair, gGood

  type Gap = enum
    gapOne = 1, gapFive = 5

  suite "the export boundary drawn in issue #27":
    test "`BoundOp` exists but is private to this module":
      # `tests/test_public_api.nim` asserts this name is unreachable from a
      # bare `import argumint`; it's private here, so no importer can name
      # it to mirror that.
      check BoundOp(desc: "bump").desc == "bump"

    test "`fromString` exists but is private to this module":
      # `acceptImpl` and `parseFlagOpsString` are its only callers.
      check fromString[int](" 5 ") == 5
      check fromString[Rank]("rMid") == rMid
      check fromString[Grade]("gFair") == gFair

    test "the string-to-scalar conversions exist but are private to this module":
      # `tests/test_public_api.nim` asserts a bare `import argumint` leaves
      # `let n: int = "5"` failing to compile. Their mirror lives here
      # because they're private to this module, so no importer can name
      # them at all.
      check toNumber[int](" 5 ") == 5
      check toNumber[float](" 2.5 ") == 2.5
      check toBool("yes")
      check toChar("c") == 'c'
      expect ValueError:
        discard toChar("cc")

  suite "saturating arithmetic":
    # Run in a debug build, so an overflow inside would raise.
    test "matches `int` arithmetic, clamped, for every `int8` and `uint8`":
      for a in int8.low .. int8.high:
        for b in int8.low .. int8.high:
          check a.stepped('+', b) == clamp(int(a) + int(b), -128, 127)
          check a.stepped('-', b) == clamp(int(a) - int(b), -128, 127)
          check a.stepped('*', b) == clamp(int(a) * int(b), -128, 127)
      for a in uint8.low .. uint8.high:
        for b in uint8.low .. uint8.high:
          check int(a.stepped('+', b)) == clamp(int(a) + int(b), 0, 255)
          check int(a.stepped('-', b)) == clamp(int(a) - int(b), 0, 255)
          check int(a.stepped('*', b)) == clamp(int(a) * int(b), 0, 255)

    test "stops at `int64`'s and `uint64`'s edges":
      const (lo, hi) = (int64.low, int64.high)
      check hi.stepped('+', 1) == hi
      check lo.stepped('-', 1) == lo
      check lo.stepped('+', -1) == lo
      check hi.stepped('-', -1) == hi
      check hi.stepped('*', 2) == hi
      check lo.stepped('*', 2) == lo
      check lo.stepped('*', -1) == hi
      check (-1'i64).stepped('*', lo) == hi
      check hi.stepped('*', -1) == -hi
      check 2'i64.stepped('*', lo) == lo
      check (hi div 2).stepped('*', 2) == hi - 1
      check uint64.high.stepped('+', 1) == uint64.high
      check 0'u64.stepped('-', 1) == 0
      check uint64.high.stepped('*', 2) == uint64.high
      check (uint64.high div 2).stepped('*', 2) == uint64.high - 1

    test "a range type stops at its own bounds":
      check Natural(2).stepped('-', 5) == 0
      check Positive(high(int)).stepped('+', 1) == high(int)
      check range[1..10](4).stepped('*', 3) == 10

  suite "Flag Operations":
    test "`opError` says what an op needs, or that it isn't one":
      check opError[int]("+=") == ""
      check opError[Rank]("=") == ""
      check opError[Rank]("+=") == "`+=` needs `+` for Rank"
      check opError[string]("-=") == "`-=` needs `-` for string"
      check opError[string]("*=") == "`*=` needs `*` for string"
      check opError[int]("/=") == "`/=` is not a Flag Operation: use `=`, `+=`, `-=` or `*=`"
      expect SpecDefect:
        discard namedOp("+=", rMid)

    test "an enum's next value skips gaps and stops at the last":
      check rLow.next == rMid
      check rHigh.next == rHigh
      check gapOne.next == gapFive
      check gapFive.next == gapFive

  proc rankArgs(): ValuesArg[Rank] =
    initValuesArg[Rank](kind = Positional, variants = "<rank>", default = @[],
      help = "", group = "", hidden = false, validator = noValidator[Rank]())

  proc rankFlag(variants: string, ops: varargs[FlagOp[Rank]]): FlagArg[Rank] =
    initFlagArg[Rank](variants = variants, ops = ops, default = rLow, help = "", group = "",
      hidden = false, clamp = noClamp[Rank](), env = none(EnvSource), cfgKey = noConfigKey())

  proc setTo(variants: string, value: Rank, desc = ""): FlagOp[Rank] =
    initFlagOp[Rank](variants, namedOp("=", value), desc)

  suite "ValueArgBase and FlagArgBase, built directly":
    test "a ValueArg's parse/defaultStr work when built directly, bypassing arg()":
      let a = initValueArg[Rank](kind = Positional, variants = "<rank>", default = rLow,
        help = "", group = "", hidden = false, validator = noValidator[Rank]())
      a.parse("rHigh")
      check a.value == some(rHigh)
      check a.defaultStr() == ""

    test "a flag rejects a Variant it doesn't have, naming its own":
      let f = rankFlag("-b", setTo("-r", rHigh))
      try:
        f.parse("--unknown")
        fail()
      except ParseError as e:
        check "--unknown" in e.msg
        check "-b" in e.msg

    test "variantDesc is empty for every variant when the flag's ops are described alike (#154)":
      let f = rankFlag("-b, --bump", setTo("-r", rHigh, "Move to the next value"))
      check f.variantDesc("-b") == ""
      check f.variantDesc("--bump") == ""
      check f.variantDesc("-r") == ""
      let g = rankFlag("-b", setTo("-r", rHigh))
      check g.variantDesc("-b") == "Move to the next value"
      check g.variantDesc("-r") == ""

    test "two ops built in one loop each keep their own value":
      # See docs/gotchas.md, closures in loops.
      let f = rankFlag("", setTo("--mid", rMid), setTo("--high", rHigh))
      f.parse("--mid")
      check f.value == rMid
      f.parse("--high")
      check f.value == rHigh

    test "repeated parse() calls on a multi-value ValueArg don't corrupt earlier elements (ORC regression)":
      let a = rankArgs()
      a.parse("rLow")
      a.parse("rMid")
      a.parse("rHigh")
      check a.value == some(@[rLow, rMid, rHigh])
