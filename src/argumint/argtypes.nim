## The `ValueArg`/`FlagArg` data model and every piece of machinery that
## touches their private fields: the method-generating `defineValueArg`/
## `defineFlagArg`/`defineSetFlagArg` templates, the `flagOps` registry
## they write, the `initValueArg`/`initFlagArg` constructors, and the
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

import std/[macros, macrocache, options, pegs, sequtils, strformat, strutils, tables]

import ./[backend, configsource, errors, flagclamp, validators]

type
  ValueArg*[T: not seq, multi: static bool] = ref object of Arg
    ## What `arg*`/`args*`/`opt*`/`opts*` return. `multi` is `false` for the
    ## scalar arity and `true` for the multi-value one, making them distinct
    ## concrete types. Nameable so an arg can cross a proc or module
    ## boundary; its fields stay private, same shape as `Spec` -- see
    ## `docs/adr/0033-value-arg-flag-arg-exported.md`.
    value: seq[T] ## Empty until `parseImpl` writes to it; see `toT`/`toSeqT`.
    default: seq[T]
    validator: Validator[T]
    env: Option[EnvSource]
    cfgKey: ConfigKey ## Not named `configKey` -- that's the base `Arg` method name; see `defineValueArg`.

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
    cfgKey: ConfigKey ## Not named `configKey` -- that's the base `Arg` method name; see `defineFlagArg`.

const flagOps = CacheTable"flagOps"
  ## Compile-time registry of the Flag Operations each type supports,
  ## written by `defineFlagOps` (below) and read by `getFlagOps`. Crosses
  ## the module boundary in both directions: the built-in registrations at
  ## the bottom of this file write it, and so does a user's own `defineArg`
  ## call in their own module.

# ------------------------------------------------------------------------------
# These converters allow the methods below to convert implicitly from strings to
# other data types. They stay private: their only consumers are `parseImpl` and
# `parseFlagOpsString` below, and exporting them would put `let n: int = "5"`
# in scope for anyone who imports argumint.
# ------------------------------------------------------------------------------

converter toInt(value: string): int =
  ## Parses a string value into an int. Negative numbers may be passed as
  ## arguments by prefixing them with a space, so whitespace characters are
  ## stripped to allow this.
  value.strip.parseInt

converter toFloat(value: string): float =
  ## Parses a string value into a float. Negative numbers may be passed as
  ## arguments by prefixing them with a space, so whitespace characters are
  ## stripped to allow this.
  value.strip.parseFloat

converter toBool(value: string): bool =
  ## Parses a string value into a bool. Supports on/off, yes/no, y/n, YES/NO,
  ## Y/N, true/false, TRUE/FALSE, and 1/0.
  value.parseBool

converter toChar(value: string): char =
  ## Converts a string value to a char. The value must be 1 character long.
  if value.len != 1:
    raise newException(ValueError, fmt"cannot convert {value} to char")
  value[0]

# ------------------------------------------------------------------------------
# Read accessors. `argumint.nim`'s `get*`/`toT*`/`toSeqT*` are written against
# these: a template rather than a proc so reading a multi-value `ValueArg`
# doesn't copy the seq, and so `get*` stays the lazy template ADR 0040 needs.
# Reads only -- writes go through `initValueArg`/`initFlagArg` below, which
# can't leave `ops` and `aliases` disagreeing the way an exported mutator
# could.
# ------------------------------------------------------------------------------

template rawValue*[T; multi: static bool](arg: ValueArg[T, multi]): untyped =
  ## `arg`'s stored values, with no default substitution. Empty until a
  ## Value Precedence tier supplies one.
  arg.value

template rawDefault*[T; multi: static bool](arg: ValueArg[T, multi]): untyped =
  ## `arg`'s coded default values.
  arg.default

template rawValue*[T](arg: FlagArg[T]): untyped =
  ## `arg`'s current value, already carrying its coded default.
  arg.value

template rawDefault*[T](arg: FlagArg[T]): untyped =
  ## `arg`'s coded default value.
  arg.default

# ------------------------------------------------------------------------------
# Parsing methods
# ------------------------------------------------------------------------------

proc putImpl*[T: not seq, multi: static bool](self: ValueArg[T, multi], value: T, variant: string, seenBy: options.Option[SeenBy], validate: bool) =
  ## Sets (or, for a multi Arg, appends) `self`'s value to `value`, running
  ## `self`'s Validator first unless `validate` is false. Raises a
  ## `ValidationError` if the value doesn't pass. `arbitrate` decides whether
  ## this contribution applies at all, and runs the Validator against the right
  ## history for the branch it takes -- with `self.value` when extending, with
  ## none when replacing, since those values are about to be discarded. See
  ## `backend.arbitrate*`. Backs both `put` (`argumint.nim`) and `parseImpl`
  ## below, which delegates here once it has a `T` in hand. `variant` is
  ## error-message context only, passed to `subject` on the failure path --
  ## `parseImpl` hands it the real matched token; `put*` always passes `""`,
  ## since a programmatic write has no matched token, letting `subject`
  ## fall back to `self.variants[0]`.
  try:
    self.arbitrate(seenBy):
      if validate and not self.validator.isNil:
        self.validator.validate(value, self.value)
    do:
      if validate and not self.validator.isNil:
        self.validator.validate(value)
    when multi:
      self.value.add(value)
    else:
      self.value = @[value]
  except ValidationError as e:
    raise newException(ValidationError, fmt"for {self.subject(variant, seenBy)}, {e.msg}")

proc parseImpl[T: not seq, multi: static bool](self: ValueArg[T, multi], value: string, variant: string, seenBy: options.Option[SeenBy]) =
  ## Converts a string `value` into a `T`, then delegates to `putImpl` for
  ## everything else -- arbitration, validation, storage. Raises `ParseError` if
  ## `value` can't convert to a `T`; a `ValidationError` from `putImpl` passes
  ## through unchanged. We do this here because generic methods are deprecated,
  ## so we generate methods for each defined type and have them call this.
  try:
    let tmp: T = value
    self.putImpl(value = tmp, variant = variant, seenBy = seenBy, validate = true)
  except ValueError:
    raise newException(ParseError, fmt"expected {$typeOf(T)} for {self.subject(variant, seenBy)} but got {value.escape}")

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

proc checkFlagOp*[T](op: string) =
  ## Raises `SpecDefect` unless `op` is one of the Flag Operations `T`
  ## registered via `defineArg`/`defineFlag`. Both ways of declaring an
  ## explicit FlagOp Alias group make this check -- `argumint.nim`'s
  ## `flagOp*` on its `op` param, and `parseFlagOpsString` below on each
  ## parsed `<op>` -- and they must reject the same ops with the same
  ## message, so they share one implementation rather than two copies on
  ## either side of the module seam.
  if op notin getFlagOps($T):
    let escapedOp = strutils.escape(op)
    raise newException(SpecDefect, fmt"{escapedOp} is not a supported operation for {$typeOf(T)} flags")

template defineValueArg*[T](typeName: typedesc[T]): untyped =
  ## Generates the `ValueArg[T, false]`/`ValueArg[T, true]` methods for `T`.
  ## The machinery behind `argumint.nim`'s one-argument `defineArg*`; see
  ## there for the user-facing docs.
  method parse(self: ValueArg[T, false], value: string, variant = "", seenBy: options.Option[SeenBy] = none(SeenBy)) =
    self.parseImpl(value, variant, seenBy)

  method parse(self: ValueArg[T, true], value: string, variant = "", seenBy: options.Option[SeenBy] = none(SeenBy)) =
    self.parseImpl(value, variant, seenBy)

  method defaultStr(self: ValueArg[T, false]): string =
    ## Returns `self`'s default value stringified, or "" if it's still `T`'s
    ## zero value (e.g. "", 0, or false) -- the fallback used when no
    ## default was given (see `arg*`). Requires `T` to support `default(T)`
    ## and `==`, which nearly every type does; a `{.requiresInit.}` object
    ## would be a rare exception that fails to compile here.
    if self.default.len > 0 and self.default[0] != default(T):
      $self.default[0]
    else:
      ""

  method defaultStr(self: ValueArg[T, true]): string =
    ## Returns `self`'s default values comma-joined, or "" if there are none.
    if self.default.len > 0:
      self.default.mapIt($it).join(", ")
    else:
      ""

  method validatorHelp(self: ValueArg[T, false]): string =
    if self.validator.isNil: "" else: self.validator.help()

  method validatorHelp(self: ValueArg[T, true]): string =
    if self.validator.isNil: "" else: self.validator.help()

  method completions(self: ValueArg[T, false]): seq[string] =
    if self.validator.isNil: @[] else: self.validator.completions()

  method completions(self: ValueArg[T, true]): seq[string] =
    if self.validator.isNil: @[] else: self.validator.completions()

  method envName(self: ValueArg[T, false]): string =
    if self.env.isSome: self.env.get.name else: ""

  method envName(self: ValueArg[T, true]): string =
    if self.env.isSome: self.env.get.name else: ""

  method envDelim(self: ValueArg[T, false]): Option[string] =
    if self.env.isSome: self.env.get.delim else: none(string)

  method envDelim(self: ValueArg[T, true]): Option[string] =
    if self.env.isSome: self.env.get.delim else: none(string)

  method configKey(self: ValueArg[T, false]): ConfigKey = self.cfgKey

  method configKey(self: ValueArg[T, true]): ConfigKey = self.cfgKey

  method clear(self: ValueArg[T, true]) =
    ## Empties `self`'s value and its `seenBy` provenance. Empty *is* the
    ## coded default's state -- it's substituted at read time, never stored
    ## (see `docs/adr/0008-validators-dont-run-against-defaults.md`).
    procCall clear(Arg(self))
    self.value.setLen 0

  method clear(self: ValueArg[T, false]) =
    ## Empties `self`'s value and its `seenBy` provenance. Empty *is* the
    ## coded default's state -- it's substituted at read time, never stored
    ## (see `docs/adr/0008-validators-dont-run-against-defaults.md`).
    procCall clear(Arg(self))
    self.value.setLen 0

proc putImpl*[T](self: FlagArg[T], value: T, seenBy: options.Option[SeenBy]) =
  ## Sets the value of `self` directly, arbitrating against `seenBy` like
  ## every other write, then clamping -- unconditionally and with no
  ## Validator, since a `FlagArg` has neither. No `variant`/`validate`
  ## params: nothing here can raise, so there's no message to give context
  ## to and no check to opt out of. See
  ## `docs/adr/0044-put-typed-write-accessor.md`.
  self.arbitrate(seenBy)
  self.value = value
  if not self.clamp.isNil:
    self.value = self.clamp.apply(self.value)

template defineFlagArg*[T](typeName: typedesc[T], blankDesc: string, flagHandler: untyped): untyped =
  ## Generates the `FlagArg[T]` methods for `T` (and, via `defineValueArg`,
  ## its `ValueArg` ones). The machinery behind `argumint.nim`'s
  ## two-argument `defineArg*` and its `defineFlag*`; see there for the
  ## user-facing docs.
  ##
  ## `variantDesc`'s locals below are named `vOp`/`vArg`/`vDesc` rather than
  ## `op`/`arg` for template-hygiene reasons documented in
  ## `docs/gotchas.md`.
  defineFlagOps typeName:
    flagHandler

  proc handleFlag(value {.inject.}: var T, op {.inject.}: string, arg {.inject.}: T) =
    flagHandler

  method parse(self: FlagArg[T], variantValue: string, variantName: string, seenBy: options.Option[SeenBy] = none(SeenBy)) =
    ## Flag args pass the seen variant as both the value and the variant in the
    ## general case. In the case of values sourced from env vars or config keys,
    ## the seen variant is passed as the value while the env/configKey is the
    ## variant. We thus re-name the parameters here to make clear what they
    ## actually do.
    if not self.ops.hasKey(variantValue):
      raise newException(ParseError, "$# is not a known variant for the flag $#" % [variantValue.escape, self.subject(variantName, seenBy)])
    self.arbitrate(seenBy)
    let (op {.inject.}, arg {.inject.}, _) = self.ops[variantValue]
    self.value.handleFlag(op, arg)
    if not self.clamp.isNil:
      self.value = self.clamp.apply(self.value)

  method validatorHelp(self: FlagArg[T]): string =
    if self.clamp.isNil: "" else: self.clamp.help()

  method variantDesc(self: FlagArg[T], variant: string): string =
    if not self.ops.hasKey(variant): return ""
    let (vOp, vArg, vDesc) = self.ops[variant]
    if vDesc.len > 0: return vDesc
    case vOp
    of "=": "Set to " & $vArg
    of "+=": "Increase by " & $vArg
    of "-=": "Decrease by " & $vArg
    else: blankDesc

  method envName(self: FlagArg[T]): string =
    if self.env.isSome: self.env.get.name else: ""

  method envDelim(self: FlagArg[T]): Option[string] =
    if self.env.isSome: self.env.get.delim else: none(string)

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

  defineValueArg typeName

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
      var arg: T
      # Built-in types call our converters explicitly rather than relying
      # on implicit conversion -- see docs/gotchas.md.
      when T is string: arg = matches[2]
      elif T is int: arg = toInt(matches[2])
      elif T is float64: arg = toFloat(matches[2])
      elif T is bool: arg = toBool(matches[2])
      elif T is char: arg = toChar(matches[2])
      else: arg = matches[2]
      result.add (variants: @[matches[0]], op: op, value: arg, help: "")
    except ValueError as e:
      raise newException(SpecDefect, fmt"unexpected flag value for {matches[0]}: {e.msg}")

# ------------------------------------------------------------------------------
# Constructors. `argumint.nim`'s `arg*`/`args*`/`opt*`/`opts*`/`flag*` are thin
# delegations to these -- they're generic, so `privateAccess` can't rescue them
# on the far side of the module boundary (see docs/gotchas.md).
# ------------------------------------------------------------------------------

proc initValueArg*[T: not seq; multi: static bool](kind: ArgKind, variants: string, default: seq[T],
    help, group: string, hidden: bool, validator: Validator[T],
    env = none(EnvSource), cfgKey = noConfigKey()): ValueArg[T, multi] =
  ## Builds a `ValueArg[T, multi]`, splitting `variants` on commas. Behind
  ## `arg*`/`args*` (`kind = Positional`, no `env`/`cfgKey`) and
  ## `opt*`/`opts*` (`kind = Optional`). Call it with named arguments: the
  ## object constructor this replaced named every field, and `help`/`group`
  ## are adjacent same-typed parameters that a positional call could swap
  ## silently.
  ValueArg[T, multi](kind: kind, variants: variants.split(Comma), default: default,
    help: help, group: group, hidden: hidden, validator: validator, env: env, cfgKey: cfgKey)

proc initFlagArg*[T](variants: string, ops: openArray[FlagOpGroup[T]], default: T,
    help, group: string, hidden: bool, clamp: FlagClamp[T],
    env: Option[EnvSource], cfgKey: ConfigKey): FlagArg[T] =
  ## Builds a `FlagArg[T]` in full -- the ops table, the FlagOp Alias
  ## groups, duplicate-variant detection, and the clamp-versus-default
  ## check -- behind `argumint.nim`'s `flag*`. Call it with named arguments,
  ## same as `initValueArg` above. Deliberately fat rather than
  ## a thin constructor plus exported `addOp`/`setAliases` mutators, which
  ## would let a caller build a `FlagArg` whose `ops` and `aliases` tables
  ## disagree.
  result = FlagArg[T](kind: Flag, variants: @[], value: default, default: default, help: help,
    group: group, hidden: hidden, clamp: clamp, env: env, cfgKey: cfgKey,
    ops: newOrderedTable[string, FlagOp[T]](), aliases: newTable[string, seq[string]]())
  if not clamp.isNil and clamp.apply(default) != default:
    raise newException(SpecDefect, fmt"default {default} for flag {variants} does not satisfy its own clamp")

  # Implicit (blank-op) group: every bare spelling in `variants` shares
  # (op: "", arg: default) and forms one alias group automatically, since
  # they can only ever share that one (op, arg) pair.
  let implicitVariants = splitFlagSpellings(variants)
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
# Here is where we define the datatypes supported out of the box. These call
# `defineValueArg`/`defineFlagArg` directly rather than `argumint.nim`'s public
# templates, which sit on the far side of the import edge.
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

defineFlagArg bool, "Toggle the value":
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

defineFlagArg float64, "":
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
  ## Direct regression tests for the `defineValueArg`/`defineFlagArg`/
  ## `defineSetFlagArg` macro machinery above, one per hygiene workaround
  ## documented in `docs/gotchas.md` -- each instantiates `ValueArg`/`FlagArg`
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
  # exercises defineFlagArg/defineValueArg together; a corruption would fail
  # to compile, not fail an assertion.
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

    test "the string-to-scalar converters exist but are private to this module":
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

  suite "defineValueArg/defineFlagArg macro machinery":
    test "a ValueArg's generated parse/defaultStr work when constructed directly, bypassing arg()":
      let a = ValueArg[Rank, false](kind: Positional, variants: @["<rank>"])
      a.parse("rHigh")
      check a.value[0] == rHigh
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
        default = {}, help = "", group = "Options", hidden = false, clamp = noClamp[set[Rank]](),
        env = none(EnvSource), cfgKey = noConfigKey())
      rankFlag.parse("--rank")
      check rankFlag.value == {rHigh}

      let gradeFlag = initFlagArg[set[Grade]]("", [(variants: @["--grade"], op: "+=", value: {gGood}, help: "")],
        default = {}, help = "", group = "Options", hidden = false, clamp = noClamp[set[Grade]](),
        env = none(EnvSource), cfgKey = noConfigKey())
      gradeFlag.parse("--grade")
      check gradeFlag.value == {gGood}
      check rankFlag.value == {rHigh} # unaffected by gradeFlag's own +=

    test "repeated parse() calls on a multi-value ValueArg don't corrupt earlier elements (ORC regression)":
      let a = ValueArg[Rank, true](kind: Positional, variants: @["<rank>"])
      a.parse("rLow")
      a.parse("rMid")
      a.parse("rHigh")
      check a.value == @[rLow, rMid, rHigh]
