## The `ValueArg`/`ValuesArg`/`FlagArg` data model and every piece of
## machinery that touches their private fields: `ValueArgBase` and the hooks
## its methods call, `fromString`, the method-generating `defineFlagArg`/
## `defineSetFlagArg` templates and the `flagOps` registry they write, the
## `initValueArg`/`initValuesArg`/`initFlagArg` constructors, and the
## `rawValue`/`rawDefault` read accessors.
##
## Everything here is exported so `argumint.nim` can reach it, and none of
## it is re-exported by that facade -- the public names (`arg`/`opt`/
## `flag`, `get`, `defineArg`/`defineFlag`/`defineSetFlag`) and their
## documentation stay there, written against this machinery. See
## `docs/adr/0043-facade-machinery-seam.md`; `argumint/argtypes` is an
## implementation detail, not an import path users are meant to type.
##
## The split is forced rather than stylistic: `std/importutils.privateAccess`
## does not survive instantiation in another module, so anything generic or
## templated that reads a private field has to live beside the type. See
## `docs/gotchas.md`.

{.experimental: "openSym".}

import std/[enumutils, macros, macrocache, options, pegs, sequtils, strformat, strutils, tables, typetraits]

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

  FlagOp[T] = tuple[op: string, arg: T, desc: string]

  FlagOpGroup*[T] = tuple[variants: seq[string], op: string, value: T, help: string]
    ## One explicit FlagOp Alias group, built by `flagOp*` and consumed by
    ## `flag*`'s `ops` param -- every spelling in `variants` shares this
    ## exact Flag Operation (`op`/`value`) and `help` override. See
    ## `flag*`.

  FlagArg*[T] = ref object of Arg
    ## What `flag*` returns. Nameable on the same terms as `ValueArg` --
    ## type public, fields private. `FlagOp` stays internal: `ops` is
    ## private, so naming `FlagArg[T]` never requires naming it.
    value: T
    default: T
    ops: OrderedTableRef[string, FlagOp[T]]
    aliases: TableRef[string, seq[string]]
    env: Option[EnvSource]
    clamp: FlagClamp[T]
    cfgKey: ConfigKey
      ## Not named `configKey` -- that's the base `Arg` method name; see
      ## `defineFlagArg`.

const flagOps = CacheTable"flagOps"
  ## Compile-time registry of the Flag Operations each type supports,
  ## written by `defineFlagOps` (below) and read by `getFlagOps`. Crosses
  ## the module boundary in both directions: the built-in registrations at
  ## the bottom of this file write it, and so does a user's own `defineArg`
  ## call in their own module. Keyed by the type as written at registration;
  ## read through `flagOpsKey`.

# ------------------------------------------------------------------------------
# String conversion. Every string-to-`T` conversion goes through `fromString`,
# which calls these by name: a converter used implicitly in a generic is only
# found where the generic is used (docs/gotchas.md). They stay private, and
# aren't converters at all, so `let n: int = "5"` doesn't compile for anyone
# who imports argumint.
# ------------------------------------------------------------------------------

proc toInt(value: string): int =
  ## Parses a string value into an int. Negative numbers may be passed as
  ## arguments by prefixing them with a space, so whitespace characters are
  ## stripped to allow this.
  value.strip.parseInt

proc toFloat(value: string): float =
  ## Parses a string value into a float. Negative numbers may be passed as
  ## arguments by prefixing them with a space, so whitespace characters are
  ## stripped to allow this.
  value.strip.parseFloat

proc toBool(value: string): bool =
  ## Parses a string value into a bool. Supports on/off, yes/no, y/n, YES/NO,
  ## Y/N, true/false, TRUE/FALSE, and 1/0.
  value.parseBool

proc toChar(value: string): char =
  ## Converts a string value to a char. The value must be 1 character long.
  if value.len != 1:
    raise newException(ValueError, fmt"cannot convert {value} to char")
  value[0]

macro sameType(T, U: typedesc): bool =
  ## Whether `T` and `U` are the same type, aliases included. Not `is`:
  ## `Natural is int`.
  newLit(sameType(T.getTypeInst[1], U.getTypeInst[1]))

template isBuiltIn(T: typedesc): bool =
  ## Whether `T` is one of the types `fromString` converts by name.
  sameType(T, string) or sameType(T, int) or sameType(T, float) or
    sameType(T, bool) or sameType(T, char)

template hasConverter(T: typedesc): bool =
  ## Whether a converter from string to `T` is in scope where the generic
  ## using this is instantiated (docs/gotchas.md).
  compiles((let converted: T = ""))

template parsesByName(T: typedesc): bool =
  ## Whether `fromString` parses `T` with `parseEnum`: an enum with no
  ## converter of its own where its Arg is built.
  T is enum and not hasConverter(T)

template isValueType(T: typedesc): bool =
  ## Whether `fromString` can convert to `T`: see CONTEXT.md, Value Type.
  isBuiltIn(T) or T is enum or hasConverter(T)

proc fromString[T](value: string): T =
  ## `value` as a `T`: a built-in by name, an enum with no converter by
  ## `parseEnum`, and anything else through the user's converter, found
  ## where the Arg is built. Raises `ValueError` if it can't convert.
  when sameType(T, string): value
  elif sameType(T, int): toInt(value)
  elif sameType(T, float): toFloat(value)
  elif sameType(T, bool): toBool(value)
  elif sameType(T, char): toChar(value)
  elif parsesByName(T): parseEnum[T](value)
  else:
    let converted: T = value
    converted

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
  except ValueError:
    # Outside `fmt`: see docs/gotchas.md, openSym.
    let (got, subject) = (c.value.quoted, self.subject(c))
    when parsesByName(T):
      let values = self.describedBy.completions.join(", ")
      raise newPlainError(ParseError, fmt"for {subject}, got {got} but expected one of {values}")
    else:
      raise newPlainError(ParseError, fmt"expected {$typeOf(T)} for {subject} but got {got}")

proc defaultText[T](self: ValueArg[T]): string =
  ## `self`'s default as help shows it, or "" if it's still `T`'s zero value
  ## (e.g. "", 0, or false) -- the fallback used when no default was given
  ## (see `arg*`). Requires `T` to support `default(T)` and `==`, which
  ## nearly every type does; a `{.requiresInit.}` object would be a rare
  ## exception that fails to compile here.
  if self.default != default(T): display.showValue(self.default) else: ""

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

macro defineFlagOps(typeName, body: untyped) =
  body.expectLen 1
  let caseBody = body.findChild(it.kind == nnkCaseStmt) or body.findChild(it.kind == nnkStmtList).findChild(it.kind == nnkCaseStmt)

  caseBody.expectKind nnkCaseStmt
  caseBody.expectMinLen 3 # ident + at least 2 of branches

  var ops = nnkBracket.newTree()

  for op in caseBody[1..^1]:
    op.expectKind {nnkOfBranch, nnkElse, nnkElifBranch}
    case op.kind
    of nnkOfBranch:
      for opStr in op[0..^2]:
        opStr.expectKind nnkStrLit
        ops.add opStr
      op[^1].expectKind nnkStmtList
    else:
      discard

  flagOps[typeName.repr] = ops

macro getFlagOps(typeName: string): untyped =
  ## The Flag Operations registered for `typeName`, as an array literal.
  ## `checkFlagOp` below is the only thing that reads it.
  if $typeName notin flagOps:
    raise newException(SpecDefect, fmt"{typeName} is not a supported type for flags")
  result = flagOps[$typeName]

macro flagOpsKey(T: typedesc): string =
  ## `T`'s key in `flagOps`: its name, or failing that its alias-free name,
  ## so `float64` finds `float`'s ops. Not `$T`: see docs/gotchas.md.
  let
    asWritten = T.getTypeInst[1].repr
    resolved = T.getType[1].repr
  result = newLit(if asWritten notin flagOps and resolved in flagOps: resolved else: asWritten)

proc checkFlagOp*[T](op: string) =
  ## Raises `SpecDefect` unless `op` is one of the Flag Operations `T`
  ## registered via `defineArg`/`defineFlag`. Both ways of declaring an
  ## explicit FlagOp Alias group make this check -- `argumint.nim`'s
  ## `flagOp*` on its `op` param, and `parseFlagOpsString` below on each
  ## parsed `<op>` -- and they must reject the same ops with the same
  ## message, so they share one implementation rather than two copies on
  ## either side of the module seam.
  if op notin getFlagOps(flagOpsKey(T)):
    let escapedOp = strutils.escape(op)
    raise newException(SpecDefect, fmt"{escapedOp} is not a supported operation for {$typeOf(T)} flags")


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

template defineFlagArg*[T](typeName: typedesc[T], blankDesc: string, flagHandler: untyped): untyped =
  ## Generates the `FlagArg[T]` methods for `T`. The machinery behind
  ## `argumint.nim`'s `defineArg*` and `defineFlag*`; see there for the
  ## user-facing docs.
  ##
  ## `variantDesc`'s locals below are named `vOp`/`vArg`/`vDesc` rather than
  ## `op`/`arg` for template-hygiene reasons documented in
  ## `docs/gotchas.md`.
  defineFlagOps typeName:
    flagHandler

  proc handleFlag(value {.inject.}: var T, op {.inject.}: string, arg {.inject.}: T) =
    flagHandler

  method accept(self: FlagArg[T], c: Contribution, how: Arbitration) =
    ## `c.value` is the Variant whose Flag Operation applies, on every tier.
    if not self.ops.hasKey(c.value):
      raise newPlainError(ParseError, "$# is not a known variant for the flag $#" % [c.value.quoted, self.subject(c)])
    if how == arReplace:
      self.clear
    let (op {.inject.}, arg {.inject.}, _) = self.ops[c.value]
    self.value.handleFlag(op, arg)
    if not self.clamp.isNil:
      self.value = self.clamp.apply(self.value)

  method accumulates(self: FlagArg[T]): bool = true

  method validatorHelp(self: FlagArg[T]): StyledText =
    if not self.clamp.isNil: result = self.clamp.styledHelp

  method variantDesc(self: FlagArg[T], variant: string): string =
    proc describe(entry: FlagOp[T]): string =
      let (vOp, vArg, vDesc) = entry
      if vDesc.len > 0: return vDesc
      case vOp
      of "=": "Set to " & $vArg
      of "+=": "Increase by " & $vArg
      of "-=": "Decrease by " & $vArg
      else: blankDesc

    # Empty unless the ops diverge: see ADR 0063.
    if not self.ops.hasKey(variant): return ""
    result = describe(self.ops[variant])
    for entry in self.ops.values:
      if describe(entry) != result: return
    result = ""

  method envSource(self: FlagArg[T]): Option[EnvSource] = self.env

  method configKey(self: FlagArg[T]): ConfigKey = self.cfgKey

  method aliases(self: FlagArg[T], a, b: string): bool =
    ## Returns whether `a` and `b` are FlagOp Aliases for `self`. `a`/`b`
    ## are guaranteed by every call site to both already be declared
    ## variants of `self` -- never a foreign string -- so `a == b` is
    ## answered directly rather than by a `self.aliases` lookup (that table
    ## only ever maps a variant to its *other* FlagOp Aliases, per its own
    ## construction). Otherwise, a variant is a FlagOp Alias of another if
    ## their `FlagOp` shares an op and an arg. The `FlagOp`'s desc does not
    ## matter.
    a == b or (self.aliases.hasKey(a) and b in self.aliases[a])

  method clear(self: FlagArg[T]) =
    ## Removes the `seenBy` provenance and restores the default value of `self`.
    procCall clear(Arg(self))
    self.value = self.default

template defineSetFlagArg*[E: enum](elemType: typedesc[E]): untyped =
  ## Registers flag support for `set[E]`. The machinery behind
  ## `argumint.nim`'s `defineSetFlag*`; see there for the user-facing docs
  ## and the meaning of each op.
  converter toSingletonSet(rawElem: string): set[elemType] =
    {parseEnum[elemType](rawElem)}

  defineFlagArg(set[elemType], ""):
    case op
    of "=": value = arg
    of "+=": value.incl(arg)
    of "-=": value.excl(arg)
    of "*=": value = value * arg
    else: raise newException(SpecDefect, "set flags only support =, +=, -=, and *= operations")

# ------------------------------------------------------------------------------
# The flag mini-language: `flag*`'s own bare `variants` string, `flagOp*`'s
# spellings, and `flag*`'s `ops: string` convenience overload.
# ------------------------------------------------------------------------------

proc splitFlagSpellings*(variants: string): seq[string] =
  ## Parses a comma-separated list of bare flag spellings (`-f`/`--flag`,
  ## no `<op><value>` suffix -- that's supplied explicitly via `flagOp*`'s
  ## own `op`/`value` params instead). Shared by `flag*`'s own implicit-op
  ## `variants` string and each `flagOp*` call's explicit-op spellings.
  if variants.len == 0: return @[]
  for rawName in variants.split(Comma):
    if rawName =~ FlagVariantFormat:
      result.add matches[0]
    else:
      let escapedRawName = strutils.escape(rawName)
      raise newException(SpecDefect, fmt"Cannot parse flag spelling {escapedRawName}: must be in the format '-f' or '--flag'")

proc parseFlagOpsString*[T](ops: string): seq[FlagOpGroup[T]] =
  ## Parses `flag*`'s convenience `ops: string` overload: each comma item
  ## is `<flag><op><value>`, becoming its own single-spelling explicit
  ## FlagOp Alias group -- sugar for, and equivalent to, the matching
  ## `flagOp*` call. Every item must carry an op/value; a bare spelling
  ## belongs in `flag*`'s own `variants` string instead, not here. See
  ## `flag*` and `docs/adr/0028-flag-ops-string-convenience.md`.
  for rawName in ops.split(Comma):
    var matches: array[3, string]
    if not rawName.match(FlagOpVariantFormat, matches) or matches[1].len == 0:
      let escapedRawName = strutils.escape(rawName)
      let helpText = strutils.dedent("""

        Flag ops entries must be in the format '<flag><op><value>', where:
          - '<flag>' is in the format '-f' or '--flag'
          - '<op>' is ':' or '=', optionally preceded by a non-word character
          - '<value>' is the value the flag represents
        Examples: '--foo=true' or '--bar+=1'. A bare spelling with no op
        belongs in flag*'s own `variants` string instead.""")
      raise newException(SpecDefect, fmt"Cannot parse flag ops entry {escapedRawName}:" & helpText)
    let op = matches[1]
    checkFlagOp[T](op)
    try:
      result.add (variants: @[matches[0]], op: op, value: fromString[T](matches[2]), help: "")
    except ValueError as e:
      raise newException(SpecDefect, fmt"unexpected flag value for {matches[0]}: {e.msg}")

# ------------------------------------------------------------------------------
# Constructors. `argumint.nim`'s `arg*`/`args*`/`opt*`/`opts*`/`flag*` are thin
# delegations to these -- they're generic, so `privateAccess` can't rescue them
# on the far side of the module boundary (see docs/gotchas.md).
# ------------------------------------------------------------------------------

template requireValueType(T: typedesc) =
  ## Stops compilation unless `fromString` can convert to `T`.
  when not isValueType(T):
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

proc initFlagArg*[T](variants: string, ops: openArray[FlagOpGroup[T]], default: T,
    help: HelpText, group: string, hidden: bool, clamp: FlagClamp[T],
    env: Option[EnvSource], cfgKey: ConfigKey): FlagArg[T] =
  ## Builds a `FlagArg[T]` in full -- the ops table, the FlagOp Alias
  ## groups, duplicate-variant detection, and the clamp-versus-default
  ## check -- behind `argumint.nim`'s `flag*`. Call it with named arguments,
  ## same as `initValueArg` above. Deliberately fat rather than
  ## a thin constructor plus exported `addOp`/`setAliases` mutators, which
  ## would let a caller build a `FlagArg` whose `ops` and `aliases` tables
  ## disagree.
  result = FlagArg[T](kind: Flag, variants: @[], value: default, default: default,
    help: help, group: group.groupOr(Flag), hidden: hidden, clamp: clamp, env: env, cfgKey: cfgKey,
    ops: newOrderedTable[string, FlagOp[T]](), aliases: newTable[string, seq[string]]())
  # Implicit (blank-op) group: every bare spelling in `variants` shares
  # (op: "", arg: default) and forms one alias group automatically, since
  # they can only ever share that one (op, arg) pair.
  let implicitVariants = splitFlagSpellings(variants)
  # `checkFlagOp`'s lookup, with a message that names the variant.
  if implicitVariants.len > 0 and "" notin getFlagOps(flagOpsKey(T)):
    raise newException(SpecDefect, fmt"{implicitVariants[0]} has no operation: {$typeOf(T)} flags have no blank operation; give it one with ops")
  if not clamp.isNil and clamp.apply(default) != default:
    let name =
      if implicitVariants.len > 0: implicitVariants[0]
      elif ops.len > 0 and ops[0].variants.len > 0: ops[0].variants[0]
      else: ""
    raise newException(SpecDefect, fmt"default {default} for flag {name} does not satisfy its own clamp")
  for name in implicitVariants:
    if result.ops.hasKeyOrPut(name, (op: "", arg: default, desc: "")):
      raise newException(SpecDefect, fmt"duplicate variant for {name}")
    result.variants.add name
  if implicitVariants.len > 1:
    for v in implicitVariants:
      result.aliases[v] = implicitVariants.filterIt(it != v)

  # Explicit groups: each flagOp's own spellings form their own
  # independent alias group -- no cross-group discovery, even if two
  # groups' (op, value) coincidentally match (see docs/adr/0027).
  for opGroup in ops:
    for name in opGroup.variants:
      if result.ops.hasKeyOrPut(name, (op: opGroup.op, arg: opGroup.value, desc: opGroup.help)):
        raise newException(SpecDefect, fmt"duplicate variant for {name}")
      result.variants.add name
    if opGroup.variants.len > 1:
      for v in opGroup.variants:
        result.aliases[v] = opGroup.variants.filterIt(it != v)

# ------------------------------------------------------------------------------
# Here is where we define the flag types supported out of the box. These call
# `defineFlagArg` directly rather than `argumint.nim`'s public templates, which
# sit on the far side of the import edge.
#
# Registering here rather than in the facade is also what guarantees `flag*`'s
# bare-bool overload sees a populated `flagOps`: import order, not the textual
# ordering rule that used to enforce it (see docs/gotchas.md).
# ------------------------------------------------------------------------------

defineFlagArg string, "":
  ## Builds a flag handler for a string.
  case op
  of "=": value = arg
  else: raise newException(SpecDefect, fmt"string flags only support = operations")

defineFlagArg bool, "Set to the opposite of the default":
  ## Handles a flag value for a bool. If `op` is blank, `arg` must be the
  ## default value of the flag, which will be inverted.
  case op
  of "": value = not arg
  of "=": value = arg
  else: raise newException(SpecDefect, fmt"boolean flags only support = operations")

defineFlagArg int, "Increment by 1":
  ## Builds a flag handler for an integer. If `op` is blank, the default
  ## is to increment the value.
  case op
  of "": value.inc
  of "=": value = arg
  of "+=": value.inc arg
  of "-=": value.dec arg
  else: raise newException(SpecDefect, "integer flags only support =, +=, and -= operations")

defineFlagArg float, "":
  case op
  of "=": value = arg
  of "+=": value += arg
  of "-=": value -= arg
  else: raise newException(SpecDefect, "float flags only support =, +=, and -= operations")

defineFlagArg char, "":
  case op
  of "=": value = arg
  else: raise newException(SpecDefect, "char flags only support = operations")

when isMainModule:
  ## Direct regression tests for the `defineFlagArg`/`defineSetFlagArg`
  ## macro machinery and `ValueArgBase`'s hooks above, one per hygiene
  ## workaround documented in `docs/gotchas.md` -- each instantiates `ValueArg`/`FlagArg`
  ## directly and drives the generated methods by hand, bypassing `Spec`/
  ## `parse*` entirely, so a regression here fails right at the template
  ## instead of three layers downstream at some other test's `spec.parse()`
  ## call. See `tests/test_argumint.nim`'s `Priority`/`Level`/`Speed`/`Color`
  ## for the complementary integration coverage (that these types work
  ## correctly *through* the full pipeline, via the facade's public
  ## `defineArg`/`defineFlag`/`defineSetFlag`) -- this suite is deliberately
  ## narrower and doesn't duplicate it.
  import std/unittest

  type Rank = enum
    rLow, rMid, rHigh

  converter toRank(value: string): Rank = parseEnum[Rank](value)

  type Grade = enum
    gPoor, gFair, gGood

  # Regression test for the template-hygiene gotcha in docs/gotchas.md --
  # exercises defineFlagArg; a corruption would fail to compile, not fail an
  # assertion.
  defineFlagArg(Rank, "Bump to the next rank"):
    case op
    of "": value = Rank((ord(value) + 1) mod 3)
    of "=": value = arg
    else: raise newException(SpecDefect, "rank flags only support blank or = operations")

  defineSetFlagArg(Rank)
  defineSetFlagArg(Grade)

  suite "the export boundary drawn in issue #27":
    test "`FlagOp` exists but is private to this module":
      # `tests/test_public_api.nim` asserts this name is unreachable from a
      # bare `import argumint`. Its mirroring positive lives here rather
      # than in `tests/test_argumint.nim` -- unlike the FSM plumbing types,
      # which `argumint/backend` exports and that file can name, `FlagOp`
      # is private to this module, so no importer can name it at all.
      # `FlagArg[T]` is nameable anyway, since `ops` is a private field.
      let op: FlagOp[int] = (op: "+=", arg: 1, desc: "bump")
      check op.arg == 1

    test "the `flagOps` registry and `getFlagOps` exist but are private to this module":
      # `checkFlagOp` is their only reader and it lives here, so neither
      # name needs a `*` -- they're private to this module rather than
      # merely withheld from the facade, which is why their negatives in
      # `tests/test_public_api.nim` mirror here and not in
      # `tests/test_argumint.nim`.
      const registeredInt = "int" in flagOps
      check registeredInt
      check "+=" in getFlagOps("int")

    test "`fromString` exists but is private to this module":
      # Same reasoning: `acceptImpl` and `parseFlagOpsString` are its only
      # callers.
      check fromString[int](" 5 ") == 5
      check fromString[Rank]("rMid") == rMid
      check fromString[Grade]("gFair") == gFair

    test "the string-to-scalar conversions exist but are private to this module":
      # `tests/test_public_api.nim` asserts a bare `import argumint` leaves
      # `let n: int = "5"` failing to compile. Their mirror lives here for
      # the same reason `FlagOp`'s does: they're private to this module, so
      # no importer can name them at all.
      check toInt(" 5 ") == 5
      check toFloat(" 2.5 ") == 2.5
      check toBool("yes")
      check toChar("c") == 'c'
      expect ValueError:
        discard toChar("cc")

  proc rankArgs(): ValuesArg[Rank] =
    initValuesArg[Rank](kind = Positional, variants = "<rank>", default = @[],
      help = "", group = "", hidden = false, validator = noValidator[Rank]())

  suite "ValueArgBase hooks and defineFlagArg machinery":
    test "a ValueArg's parse/defaultStr work when built directly, bypassing arg()":
      let a = initValueArg[Rank](kind = Positional, variants = "<rank>", default = rLow,
        help = "", group = "", hidden = false, validator = noValidator[Rank]())
      a.parse("rHigh")
      check a.value == some(rHigh)
      check a.defaultStr() == ""

    test "a FlagArg's generated parse()/variantDesc() are correct -- % (not fmt) inside a defineFlagArg-generated method, and defineFlagArg's blankDesc wiring":
      let f = FlagArg[Rank](kind: Flag, variants: @["-r", "-b"])
      f.ops = newOrderedTable[string, FlagOp[Rank]]()
      f.ops["-r"] = ("=", rHigh, "")
      f.ops["-b"] = ("", rLow, "")
      expect ParseError:
        f.parse("--unknown")
      try:
        f.parse("--unknown")
      except ParseError as e:
        check "--unknown" in e.msg
        check "-r" in e.msg
      check f.variantDesc("-b") == "Bump to the next rank"

    test "variantDesc is empty for every variant when the flag's ops are described alike (#154)":
      let f = FlagArg[Rank](kind: Flag, variants: @["-b", "--bump", "-r"])
      f.ops = newOrderedTable[string, FlagOp[Rank]]()
      f.ops["-b"] = ("", rLow, "")
      f.ops["--bump"] = ("", rLow, "")
      f.ops["-r"] = ("=", rHigh, "Bump to the next rank")
      check f.variantDesc("-b") == ""
      check f.variantDesc("--bump") == ""
      check f.variantDesc("-r") == ""

    test "defineSetFlagArg's =/+=/-=/*= ops all work on a directly-constructed FlagArg[set[T]]":
      let f = FlagArg[set[Rank]](kind: Flag, variants: @["-r"])
      f.ops = newOrderedTable[string, FlagOp[set[Rank]]]()
      f.ops["="] = ("=", {rLow}, "")
      f.ops["+="] = ("+=", {rMid}, "")
      f.ops["-="] = ("-=", {rLow}, "")
      f.ops["*="] = ("*=", {rMid}, "")

      f.parse("=")
      check f.value == {rLow}
      f.parse("+=")
      check f.value == {rLow, rMid}
      f.parse("-=")
      check f.value == {rMid}
      f.parse("*=")
      check f.value == {rMid}

    test "two distinct defineSetFlagArg(enum) instantiations don't cross-wire in the flagOps CacheTable":
      # Regression test for the repr-vs-$ CacheTable keying in
      # docs/gotchas.md -- reads both entries back out of the table
      # (`getFlagOps`, the read side `flagOp*` uses) and drives a real
      # `initFlagArg` build of each (the write side).
      const
        rankOps = getFlagOps("set[Rank]")
        gradeOps = getFlagOps("set[Grade]")
      check "*=" in rankOps
      check "*=" in gradeOps

      let rankFlag = initFlagArg[set[Rank]]("", [(variants: @["--rank"], op: "+=", value: {rHigh}, help: "")],
        default = {}, help = "", group = "", hidden = false, clamp = noClamp[set[Rank]](),
        env = none(EnvSource), cfgKey = noConfigKey())
      rankFlag.parse("--rank")
      check rankFlag.value == {rHigh}

      let gradeFlag = initFlagArg[set[Grade]]("", [(variants: @["--grade"], op: "+=", value: {gGood}, help: "")],
        default = {}, help = "", group = "", hidden = false, clamp = noClamp[set[Grade]](),
        env = none(EnvSource), cfgKey = noConfigKey())
      gradeFlag.parse("--grade")
      check gradeFlag.value == {gGood}
      check rankFlag.value == {rHigh} # unaffected by gradeFlag's own +=

    test "repeated parse() calls on a multi-value ValueArg don't corrupt earlier elements (ORC regression)":
      let a = rankArgs()
      a.parse("rLow")
      a.parse("rMid")
      a.parse("rHigh")
      check a.value == some(@[rLow, rMid, rHigh])
