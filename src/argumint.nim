## `argumint`'s public API: declare a spec as a tuple of `arg`/`args`/`opt`/
## `opts`/`flag`/`command`/`help`/`message`/`version` values, then build and
## parse it with `newSpec`/`parse*`/`parseOrQuit*`. A usage string (given
## explicitly or auto-filled from the declared args -- see `autoFillUsage`)
## is compiled into an FSM (`argumint/backend`, `argumint/lexer`,
## `argumint/parser`) that drives actual matching (`argumint/fsm`) --
## docopt-style patterns like `[-r] <src>... <dest>` or mutually exclusive
## options fall out of that FSM's grammar rather than hand-written
## validation code.
##
## See the README for a quickstart and `examples/naval_fate.nim` for a full
## worked example with subcommands. `CONTEXT.md` defines this library's
## vocabulary (Spec, Arg, Variant, Validator, Value Precedence, ...) and
## `docs/architecture.md` traces the spec-construction -> FSM-compilation ->
## runtime-matching -> value-conversion pipeline file by file.

{.experimental: "openSym".}

import std/[importutils, macros, macrocache, os, options, pegs, sequtils, sets, sugar, strformat, strutils, tables, terminal, wordwrap]

import ./argumint/[backend, completion, configsource, dot, flagclamp, fsm, fsmgraph, parser, validators]

privateAccess(Spec) ## Reaches `Spec`'s private fields (ADR 0030) from
  ## non-generic code only -- see `beginSpec`/`finishSpec` and docs/gotchas.md.

export completion.Shell

# Re-exported so `import argumint` alone is enough to catch everything
# `parse*`/`parseOrQuit*`/`newSpec` can raise, without also reaching into
# `argumint/backend`/`argumint/validators`/`argumint/lexer` by hand.
export ParseError, ValidationError, HelpError, MessageError, SpecDefect, CompletionError

# Ergonomics, and fixes an openSym resolution bug for custom Arg types --
# see docs/gotchas.md and docs/adr/0017-argumint-reexports-for-custom-arg-types.md.
export validators
export flagclamp
export configsource
export backend.name
export strutils.escape

# `clamp`/`adjust`'s `desc: Option[string]` param (argumint/flagclamp, see
# issue #12) makes `Option`-construction part of the public API surface --
# re-exported narrowly (not wholesale `std/options`, which would flood the
# namespace with `isSome`/`get`/`map`/... unrelated to spec construction),
# so `import argumint` alone is enough to write `desc = some("...")`.
export options.some, options.none

# `before`/`action`/`after` hooks' `info: HookInfo` parameter -- see
# docs/adr/0021-hook-info-matched-args.md.
export backend.HookInfo
export backend.showsMessage

# The core vocabulary types, so a spec can cross a proc or module boundary
# (`var built: Spec`, `proc buildCli(): Spec`) and `HookInfo.matched` can
# actually be inspected (`it of MessageArg`, `it.kind == Optional`).
# `State`/`Transition`/`Matcher`/`MatcherKind` are deliberately left out --
# they're FSM plumbing, not API. See
# docs/adr/0030-core-types-exported-spec-opaque.md.
export backend.Spec, backend.SpecSettings
export backend.Arg, backend.ArgKind, backend.CommandArg, backend.MessageArg, backend.HelpArg
export backend.EnvSource
export fsm.CompletionCandidate

# `Option` itself, not just `some`/`none` above: `opt*`/`opts*`/`flag*`'s
# `env` param and `EnvSource.delim` are both `Option`-typed, so writing a
# helper that returns one (or spelling `none(EnvSource)` explicitly)
# needs the type nameable.
export options.Option

# `newSpecSettings*`'s signature spells these three as its own defaults, so a
# reader of its docs needs to be able to resolve them. `DefaultWidth`
# deliberately isn't here -- it appears in no exported signature, and by
# `docs/adr/0029`'s rule an export with no demonstrated caller stays out
# until one shows up (adding it later is non-breaking).
export backend.DefaultMaxVariantsWidth, backend.DefaultEnvDelim,
  backend.DefaultStrictOptions

# The two operations on a built `Spec` that live in `argumint/fsm` rather
# than here. `parseOrQuit*(Spec)` was already reachable (it's defined
# below), so without these `newSpec` -> `parse` was the one broken half of
# an otherwise-complete pair. `completeArgs*` is what makes the exported
# `CompletionCandidate` usable.
export fsm.parse, fsm.completeArgs

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
    cfgKey: ConfigKey ## Not named `configKey` -- that's the base `Arg` method name; see `defineArg`.

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
    ops: OrderedTableRef[string, FlagOp[T]]
    aliases: TableRef[string, seq[string]]
    env: Option[EnvSource]
    clamp: FlagClamp[T]
    cfgKey: ConfigKey ## Not named `configKey` -- that's the base `Arg` method name; see `defineFlagArg`.

const flagOps = CacheTable"flagOps"

let
  Comma = peg"\s* ',' \s*"

  PositionalVariantFormat = peg"""
    # Allows you to capture <arg>
    argument <- ^ {'<' \w (\w / ('-' \w))* '>'} $
  """

  OptionalVariantFormat = peg"""
    # Allows you to capture [-o, var] / [--option, var] in -o=<var> / --option=<var>
    option <- ^ (shortOption / longOption) (equals helpVar)? $
    equals <- '=' / ':'
    shortOption <- {'-' \w}
    longOption <- {'--' \w (\w / ('-' \w))+}
    helpVar <- '<' {\w (\w / ('-' \w))*} '>'
  """

  FlagVariantFormat = peg"""
    # A bare flag spelling, no embedded <op><value> -- that's supplied
    # explicitly via flagOp's own op/value params instead (see flag*/
    # flagOp*).
    flag <- ^ (shortFlag / longFlag) $
    shortFlag <- {'-' \w}
    longFlag <- {'--' \w (\w / ('-' \w))+}
  """

  FlagOpVariantFormat = peg"""
    # A flag spelling with an optional embedded <op><value> suffix --
    # convenience sugar for flag*'s own `variants` string only (see
    # parseFlagVariants): a bare spelling keeps the implicit blank-op
    # behavior, a suffixed one becomes its own single-spelling explicit
    # FlagOp Alias group, equivalent to passing one `flagOp*` call via
    # `ops` instead. flagOp*'s own (multi-spelling) `variants` list never
    # allows this suffix -- see FlagVariantFormat.
    flag <- ^ (shortFlag / longFlag) (op value)? $
    shortFlag <- {'-' \w}
    longFlag <- {'--' \w (\w / ('-' \w))+}
    op <- {equals / (\W? equals)}
    equals <- '=' / ':'
    value <- {.*}
  """

# ------------------------------------------------------------------------------
# These converters allow the methods below to convert implicitly from strings to
# other data types.
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
# These functions create help messages.
# ------------------------------------------------------------------------------

const CanonicalGroups = ["Commands", "Arguments", "Options"]

proc groupOrder(spec: Spec): seq[string] =
  ## Returns `spec.groups`' keys ordered as `Commands`, `Arguments`,
  ## `Options`, then any other (e.g. user-defined) groups in the order they
  ## were first declared.
  for group in CanonicalGroups:
    if group in spec.groups:
      result.add group
  for group in spec.groups.keys:
    if group notin CanonicalGroups:
      result.add group

proc variantGroups(arg: Arg): seq[tuple[names: seq[string], desc: string]] =
  ## Groups `arg.variants` by their `variantDesc` text, preserving
  ## declaration order (both across groups and within one). Collapses to
  ## exactly one group (`desc` possibly `""`) whenever every variant shares
  ## the same description -- i.e. every arg that isn't a flag with
  ## genuinely divergent per-variant ops -- so callers that don't care
  ## about grouping still see a single group covering all of `arg.variants`.
  var byDesc = initOrderedTable[string, seq[string]]()
  for v in arg.variants:
    byDesc.mgetOrPut(arg.variantDesc(v), @[]).add v
  for desc, names in byDesc.pairs:
    result.add (names: names, desc: desc)

proc genHelp(spec: Spec, command: string): string =
  let prolog = if spec.prolog.len > 0: spec.prolog & "\n\n" else: ""
  let epilog = if spec.epilog.len > 0: spec.epilog else: ""
  let usage = spec.usage.formatUsage(command, spec.settings.width) & "\n"

  var rawColWidth = 0
  for arg in spec.args:
    for vg in arg.variantGroups():
      rawColWidth = max(rawColWidth, vg.names.join(", ").len)
  let colWidth =
    if spec.settings.maxVariantsWidth > 0: min(rawColWidth, spec.settings.maxVariantsWidth)
    else: rawColWidth

  let continuationIndent = "    " # deeper than the "  " row margin, so a wrapped
                                   # variants continuation (or a divergent-op
                                   # sub-row) isn't mistaken for a new arg

  var lines: seq[string]
  for group in spec.groupOrder:
    var argLines: seq[string]
    for arg in spec.groups[group]:
      if arg.hidden:
        continue
      let groups = arg.variantGroups()
      for vg in groups:
        let variants = vg.names.join(", ")
        let margin = "  " # every group is a peer row, not a wrap continuation -- see
                           # continuationIndent's own use below for actual wrapping
        # Every group of a divergent flag repeats the arg's shared `help` and
        # arg-level annotations (validator/default/env/configKey), not just
        # the first-declared variant -- that repetition is what visually ties
        # the rows together as variants of the same value now that they're no
        # longer indented as a nested continuation of the first row.
        let divergent = groups.len > 1 and vg.desc.len > 0
        let primary = if arg.help.len > 0: arg.help elif divergent: vg.desc else: ""
        var annotations: seq[string]
        if arg.validatorHelp.len > 0: annotations.add arg.validatorHelp
        if arg.defaultStr.len > 0: annotations.add "default: {arg.defaultStr}".fmt
        if arg.envName.len > 0: annotations.add "env: {arg.envName}".fmt
        if arg.configKey.len > 0: annotations.add "configKey: {arg.configKey.join}".fmt
        if divergent and arg.help.len > 0: annotations.add "action: {vg.desc}".fmt
        let bracket = if annotations.len > 0: "[{annotations.join(\"; \")}]".fmt else: ""
        let text =
          if bracket.len == 0: primary
          elif primary.len == 0: bracket
          else: "{primary} {bracket}".fmt
        let variantLines = variants.wrapWords(colWidth, splitLongWords = false).splitLines
        if text.len > 0:
          let helpWidth = max(spec.settings.width - (2 + colWidth + 2), 20)
          let textLines = text.wrapWords(helpWidth, splitLongWords = false).splitLines
          for j in 0 ..< max(variantLines.len, textLines.len):
            let v = if j < variantLines.len: variantLines[j] else: ""
            let t = if j < textLines.len: textLines[j] else: ""
            if t.len > 0:
              let rowMargin = if j == 0: margin else: continuationIndent
              argLines.add(rowMargin & v.alignLeft(colWidth) & "  " & t)
            elif j > 0:
              argLines.add(continuationIndent & v)
            else:
              argLines.add(margin & v)
        else:
          for j, v in variantLines:
            if j > 0:
              argLines.add(continuationIndent & v)
            else:
              argLines.add(margin & v)
    if argLines.len > 0:
      lines.add("\n{group}".fmt)
      lines.add(argLines)

  let args = lines.join("\n")
  result = fmt"{prolog}{usage}{args}{epilog}"


# ------------------------------------------------------------------------------
# Parsing methods
# ------------------------------------------------------------------------------

proc parseImpl[T: not seq, multi: static bool](self: ValueArg[T, multi], value: string, variant: string) =
  ## Converts a string `value` into a `T` and validates it is an appropriate
  ## value for `self`. Raises a `ParseError` if `value` cannot be converted to a
  ## `T` or a `ValidationError` if the value does not pass `self`'s validator.
  ## We do this here because generic methods are deprecated, so we generate
  ## methods for each defined type and have them call this.
  try:
    let tmp: T = value
    if not self.validator.isNil:
      self.validator.validate(tmp, self.value)
    when multi:
      self.value.add(tmp)
    else:
      self.value = @[tmp]
  except ValidationError as e:
    raise newException(ValidationError, fmt"for {self.name(variant)}, {e.msg}")
  except ValueError:
    raise newException(ParseError, fmt"expected {$typeOf(T)} for {self.name(variant)} but got {value.escape}")

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

template defineArg*[T](typeName: typedesc[T]): untyped =
  ## Defines parse methods for arguments with a value of type `T`. Use this
  ## version if you want to write your own converter to parse a string into a
  ## `T`.
  method parse(self: ValueArg[T, false], value: string, variant = "") =
    self.parseImpl(value, variant)

  method parse(self: ValueArg[T, true], value: string, variant = "") =
    self.parseImpl(value, variant)

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

  method setFromEnv(self: ValueArg[T, false], values: seq[string]) =
    # multi=false's overwrite-on-each-call already gives last-value-wins.
    for value in values:
      self.parseImpl(value, self.envName)

  method setFromEnv(self: ValueArg[T, true], values: seq[string]) =
    # `multi = true`'s append-on-each-call behavior already gives the
    # usual multi-value Match Accumulation rule for free.
    for value in values:
      self.parseImpl(value, self.envName)

  method configKey(self: ValueArg[T, false]): ConfigKey = self.cfgKey

  method configKey(self: ValueArg[T, true]): ConfigKey = self.cfgKey

  method setFromConfig(self: ValueArg[T, false], values: seq[string]) =
    # multi=false's overwrite-on-each-call already gives last-value-wins.
    # `join` as the error-context string, so a failure names the path the
    # way help text does (`server.port`) -- see docs/adr/0029-config-key-distinct.md.
    for value in values:
      self.parseImpl(value, self.cfgKey.join)

  method setFromConfig(self: ValueArg[T, true], values: seq[string]) =
    # `multi = true`'s append-on-each-call behavior already gives the
    # usual multi-value Match Accumulation rule for free.
    for value in values:
      self.parseImpl(value, self.cfgKey.join)

template defineFlagArg[T](typeName: typedesc[T], blankDesc: string, flagHandler: untyped): untyped =
  ## Shared implementation for `defineArg`/`defineFlag` below -- kept as
  ## its own template (rather than an overload of either), and
  ## `variantDesc`'s locals below are named `vOp`/`vArg`/`vDesc` rather
  ## than `op`/`arg`, both for template-hygiene reasons documented in
  ## docs/gotchas.md.
  defineFlagOps typeName:
    flagHandler

  proc handleFlag(value {.inject.}: var T, op {.inject.}: string, arg {.inject.}: T) =
    flagHandler

  method parse(self: FlagArg[T], _: string, variant = "") =
    let name = self.name(variant)
    if not self.ops.hasKey(name):
      raise newException(SpecDefect, "$# is not a known variant for the flag $#" % [name, self.name])
    let (op {.inject.}, arg {.inject.}, _) = self.ops[name]
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

  method setFromEnv(self: FlagArg[T], values: seq[string]) =
    # Each value names a declared Variant and is applied via that Variant's
    # own Flag Operation -- see ADR 0005. Looked up against self.ops
    # directly (not self.name) so an empty value raises ParseError instead
    # of defaulting to self.variants[0]. Named variantName, not value --
    # handleFlag above already injects `value` into this scope. Uses `%`,
    # not `fmt` (see docs/gotchas.md).
    for variantName in values:
      if not self.ops.hasKey(variantName):
        raise newException(ParseError, "$# names no known variant of the flag $#" % [variantName.escape, self.name])
      let (op {.inject.}, arg {.inject.}, _) = self.ops[variantName]
      self.value.handleFlag(op, arg)
      if not self.clamp.isNil:
        self.value = self.clamp.apply(self.value)

  method configKey(self: FlagArg[T]): ConfigKey = self.cfgKey

  method setFromConfig(self: FlagArg[T], values: seq[string]) =
    # Identical body to setFromEnv* above -- see docs/adr/0018-config-source.md.
    for variantName in values:
      if not self.ops.hasKey(variantName):
        raise newException(ParseError, "$# names no known variant of the flag $#" % [variantName.escape, self.name])
      let (op {.inject.}, arg {.inject.}, _) = self.ops[variantName]
      self.value.handleFlag(op, arg)
      if not self.clamp.isNil:
        self.value = self.clamp.apply(self.value)

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

  defineArg typeName

template defineArg*[T](typeName: typedesc[T], flagHandler: untyped): untyped =
  ## Defines parse methods for arguments with a value of type `T`.
  ## `flagHandler` is a code block that is executed to handle an operation on a
  ## `FlagArg[T]` value. Without this block, a `T` cannot be used for a flag.
  ## Within the scope of the handler, the following variables are defined:
  ## - `value: var T`: the flag's value, which can be modified by the handler
  ## - `op: string`: the operation to be performed on `value` (e.g., `+=`)
  ## - `arg: T`: an argument to the operation
  ## Blank-op (`""`) variants show no auto-generated description in help
  ## text; use `defineFlag` to supply one.
  defineFlagArg(typeName, "", flagHandler)

template defineFlag*[T](typeName: typedesc[T], blankDesc: string, flagHandler: untyped): untyped =
  ## Same as `defineArg` above, but also registers `blankDesc` as the
  ## auto-generated help-text description for blank-op (`""`) variants
  ## (e.g. `"Toggle the value"`), since that behavior is type-specific and
  ## can't be inferred from `(op, value)` alone the way `=`/`+=`/`-=` can.
  defineFlagArg(typeName, blankDesc, flagHandler)

template defineSetFlag*[E: enum](elemType: typedesc[E]): untyped =
  ## Registers flag support for `set[E]`. Call once per concrete enum `E`
  ## before declaring `flag[set[E]](...)`, the same way a custom scalar flag
  ## type opts in via `defineArg`/`defineFlag`. Each variant's value names a
  ## single element of `E`:
  ## - `=` sets the value to a set containing only the given element.
  ## - `+=` includes the given element in the set (union).
  ## - `-=` excludes the given element from the set (difference).
  ## - `*=` keeps the given element only if it's already present, dropping
  ##   everything else (intersection).
  converter toSingletonSet(rawElem: string): set[elemType] =
    {parseEnum[elemType](rawElem)}

  defineArg(set[elemType]):
    case op
    of "=": value = arg
    of "+=": value.incl(arg)
    of "-=": value.excl(arg)
    of "*=": value = value * arg
    else: raise newException(SpecDefect, "set flags only support =, +=, -=, and *= operations")

method parse(self: MessageArg, _: string, variant = "") =
  ## Raises `MessageError` with `self.message`, short-circuiting the rest
  ## of parsing so `parse*`/`parseOrQuit*` can deliver it directly (see
  ## `message*`/`version*`).
  raise newException(MessageError, self.message)

method parse(self: HelpArg, command: string, spec: Spec, variant = "") =
  ## Raises `HelpError` with `spec`'s generated help text for `command`,
  ## short-circuiting the rest of parsing so `parse*`/`parseOrQuit*` can
  ## deliver it directly (see `help*`).
  raise newException(HelpError, spec.genHelp(command))

# ------------------------------------------------------------------------------
# Convenience functions that allow easy unpacking of values from args.
# ------------------------------------------------------------------------------

converter toT*[T](arg: ValueArg[T, false]): T =
  ## Converts a `ValueArg[T, false]` to a `T`, substituting a default value if
  ## no value was set by the user.
  (if arg.value.len > 0: arg.value else: arg.default)[0]

converter toSeqT*[T](arg: ValueArg[T, true]): seq[T] =
  ## Converts a `ValueArg[T, true]` to a `seq[T]`, substituting a default
  ## value if no value was set by the user.
  if arg.value.len > 0: arg.value else: arg.default

converter toT*[T](arg: FlagArg[T]): T =
  ## Converts a `FlagArg[T]` to a `T`.
  arg.value

# ------------------------------------------------------------------------------
# Spec Construction
# ------------------------------------------------------------------------------

proc addArg(spec: Spec, arg: Arg, varName: string) =
  if arg.variants.len < 1:
    raise newException(SpecDefect, fmt"arg {varName} must have at least one variant")
  spec.args.add(arg)
  if spec.groups.hasKeyOrPut(arg.group, @[arg]):
    spec.groups[arg.group].add(arg)

  for variant in arg.variants:
    case arg.kind
    of Positional:
      # Matches `<arg>`
      if variant =~ PositionalVariantFormat:
        if spec.arguments.hasKeyOrPut(matches[0], arg):
          raise newException(SpecDefect, fmt"argument {matches[0]} already defined")
      else:
        raise newException(SpecDefect, fmt"invalid positional arg variant for {varName}: {variant}")
    of Optional, Flag:
      # Matches `-o[=<foo>]` or `--option[=<foo>]` but removes any help vars
      if variant =~ OptionalVariantFormat:
        if spec.options.hasKeyOrPut(matches[0], arg):
          raise newException(SpecDefect, fmt"option {matches[0]} already defined")
      else:
        raise newException(SpecDefect, fmt"invalid optional arg variant for {varName}: {variant}")
    of Command:
      if spec.commands.hasKeyOrPut(variant, CommandArg(arg)):
        raise newException(SpecDefect, fmt"command {variant} already defined")

proc addArgs(self: Spec, spec: tuple) =
  for varName, arg in spec.fieldPairs:
    when arg is Arg:
      self.addArg(arg, varName)
    elif arg is tuple:
      self.addArgs(arg)
    else:
      raise newException(SpecDefect, fmt"all members of a spec tuple must be args or tuples, but {varName} is {$typeof(arg)}")

proc autoFillUsage(spec: Spec) =
  ## Fills in usage lines for whatever's unreachable (commands, positional
  ## args, `[options]`) so callers only need to hand-write the parts they
  ## want to customize -- see architecture.md's "autoFillUsage" section for
  ## the exact per-category fill-in rules.
  var newLines: seq[string]

  proc addLine(line: string) =
    ## Appends `line` to both the human-readable `spec.usage` and the
    ## `newLines` list later spliced onto `spec.fsm` -- one call keeps the
    ## two in sync instead of relying on every call site to remember both.
    spec.usage.addSep("\n")
    spec.usage.add line
    newLines.add line

  let reachable = spec.fsm.referencedArgs()
  let optionsUnreachable = spec.options.values.toSeq.deduplicate
    .anyIt(not (it of MessageArg) and it notin reachable)
  let prefix = if optionsUnreachable: "[options] " else: ""
  var prefixUsed = false

  let unreachableCommands = spec.args.filterIt(it.kind == Command and it notin reachable)
  if unreachableCommands.len > 0:
    let variants = unreachableCommands.mapIt(it.variants).concat
    let combined = if variants.len > 1: "(" & variants.join(" | ") & ")" else: variants[0]
    addLine prefix & combined
    prefixUsed = prefixUsed or optionsUnreachable

  let positionals = spec.args.filterIt(it.kind == Positional)
  if positionals.len > 0 and positionals.allIt(it notin reachable):
    addLine prefix & positionals.mapIt(it.name).join(" ")
    prefixUsed = prefixUsed or optionsUnreachable

  for arg in spec.args.filterIt(it of MessageArg and it notin reachable):
    let variants = if arg.variants.len > 1: "(" & arg.variants.join(" | ") & ")" else: arg.variants[0]
    addLine variants

  if optionsUnreachable and not prefixUsed:
    addLine "[options]"

  if newLines.len > 0:
    spec.addUsageLines(spec.fsm, newLines)
    spec.fsm.prepare()

proc newSpecSettings*(width = terminalWidth(), maxVariantsWidth = DefaultMaxVariantsWidth,
    envDelim = DefaultEnvDelim, configSources: seq[ConfigSource] = @[],
    strictOptions = DefaultStrictOptions): SpecSettings =
  ## Creates a `SpecSettings` for `newSpec`/`parse*`/`parseOrQuit*`'s `settings`
  ## param.
  ## - `width` is the column width usage/help text wraps at. Defaults to the
  ##   caller's detected terminal width or 80 columns when none can be
  ##   detected (e.g., piped output with `COLUMNS` unset). Pass an explicit
  ##   width to opt out of auto-detection.
  ## - `maxVariantsWidth` caps the variants column's width before it wraps
  ##   onto extra indented lines (`0` for unlimited).
  ## - `envDelim` is the delimiter an env-configured Option/Flag's raw value
  ##   is split on to supply more than one value (`\x1e` is always tried
  ##   first, since that's how fish auto-joins a list variable) -- see
  ##   `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`. A
  ##   single Option/Flag can override this delimiter (or opt out of
  ##   splitting entirely) via `env*`'s two-arg form -- see
  ##   `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  ## - `configSources` is Value Precedence's Config Source tier -- an
  ##   ordered list of `ConfigSource`s (e.g. `iniConfigSource(path)`,
  ##   `jsonConfigSource(path)`, or a custom subclass), consulted in order
  ##   for any Option/Flag declaring a `configKey`. A later source's hit
  ##   fully replaces an earlier one's, never merged. See
  ##   `docs/adr/0018-config-source.md`.
  ##
  ## - `strictOptions` is Strict Option Checking: whether an option-shaped
  ##   token resolving against no declared option may be accepted as data.
  ##   On by default, and it governs two slots. In the common
  ##   `[options] <file>...` shape, off means a typo'd `--recrusive`
  ##   silently becomes a filename; and with any value-taking option, off
  ##   means `--name --help` sets `name` to `"--help"` rather than
  ##   reporting that `--name` has no value. A Non-Option Short -- one dash
  ##   whose second character isn't an ASCII letter (`-5`, `-3.5`,
  ##   `-0x1F`) -- is exempt either way, which is what keeps negative
  ##   numbers usable. Set `false` for a grammar that genuinely takes
  ##   dash-leading literal text, though a typed `--`, a usage-string
  ##   `[--]` marker, the leading-space form (`" -x"`), or the attached
  ##   form (`--name=--nope`) each force one token literally without
  ##   disabling the check everywhere. See
  ##   `docs/adr/0034-strict-option-checking.md`.
  ##
  ## Hold onto the returned `SpecSettings` and pass the same instance to
  ## `command()`'s enclosing `newSpec`/`parse*`/`parseOrQuit*` call to mutate
  ## it later (e.g. from a `before` hook) and have the change apply live to
  ## every not-yet-dispatched `Spec` in the tree -- see
  ## `docs/adr/0013-message-args-fire-after-before.md`.
  SpecSettings(width: width, maxVariantsWidth: maxVariantsWidth, envDelim: envDelim,
    configSources: configSources, strictOptions: strictOptions)

proc cascadeSpecSettings(spec: Spec, settings: SpecSettings) =
  ## Shares `settings` by reference with `spec` and every nested subcommand's
  ## spec, so a value given to the top-level `newSpec`/`parse*` call --  or a
  ## later mutation of that same `SpecSettings` instance -- applies uniformly
  ## throughout the whole command tree without needing to be repeated at
  ## each `command()` call.
  spec.settings = settings
  for cmd in spec.commands.values:
    cmd.spec.cascadeSpecSettings(settings)

converter toEnvSource*(name: string): Option[EnvSource] =
  ## Lets `opt*`/`opts*`/`flag*`'s `env` param be given a plain env var
  ## name (`env = "PORT"`), same as before -- see `env*` for the two-arg
  ## form that also overrides the delimiter.
  some(EnvSource(name: name))

proc env*(name: string, delim: string): Option[EnvSource] =
  ## Names an environment variable to supply an arg's value, overriding
  ## the delimiter its raw value is split on for this arg only, instead of
  ## inheriting `Spec.settings.envDelim`. `delim = ""` means never split this
  ## arg's env value at all, even on `\x1e` -- see
  ## `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  some(EnvSource(name: name, delim: some(delim)))

proc beginSpec(usage, prolog, epilog: string): Spec =
  ## Creates an argless `Spec` for `newSpec*` to populate. Non-generic
  ## bookend, with `finishSpec` -- see docs/gotchas.md.
  Spec(usage: usage, prolog: prolog, epilog: epilog)

proc finishSpec(spec: Spec, settings: SpecSettings) =
  ## Compiles `spec`'s FSM, fills in the usage gaps, and cascades
  ## `settings`. Non-generic bookend, with `beginSpec` -- see docs/gotchas.md.
  spec.fsm = spec.genFsm()
  spec.autoFillUsage()
  spec.cascadeSpecSettings(settings)

proc newSpec*(spec: tuple, usage = "", prolog = "", epilog = "",
    settings = newSpecSettings()): Spec =
  ## Creates a new spec from a spec tuple and builds its FSM.
  ## - `usage` is the usage string used to build the FSM. See `autoFillUsage`
  ##   for how gaps in `usage` are auto-filled.
  ## - `prolog` is the front matter for help messages generated from this spec.
  ## - `epilog` is the end matter for help messages generated from this spec.
  ## - `settings` holds `width`/`maxVariantsWidth`/`envDelim` -- see
  ##   `newSpecSettings`. Shared by reference with every nested subcommand's
  ##   spec (see `cascadeSpecSettings`); mutating it later (e.g. from a
  ##   `before` hook) applies live throughout the tree.
  ##
  ## Unlike `parseOrQuit*`, this doesn't catch `SpecDefect` (construction)
  ## or `ParseError`/`ValidationError`/`HelpError`/`MessageError` (if you
  ## call `result.parse(args, command)` yourself) -- use it when you need
  ## to handle those yourself, or just call `parse*` on the spec tuple
  ## directly for the same `newSpec` + parse in one step, still raising on
  ## failure.
  ##
  ## `spec` is **single-use**: parsing more than once accumulates into the
  ## same Args rather than starting fresh. Use `parsed*`/`parsedOrQuit*` to
  ## parse a fresh spec per call -- see
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  result = beginSpec(usage, prolog, epilog)
  result.addArgs(spec)
  result.finishSpec(settings)

# ------------------------------------------------------------------------------
# Arg constructors
# ------------------------------------------------------------------------------

proc arg*[T: not seq](variants: string, default: T = default(T), help = "", group = "Arguments", hidden = false, validator: Validator[T] = noValidator[T]()): ValueArg[T, false] =
  ## Creates a positional argument with a value of type `T`. If given, `default`
  ## can be used to infer `T`; otherwise, `T` defaults to `string` (see the
  ## bare-call overload below) unless set explicitly -- e.g. `arg[int]("<n>")`.
  ## - `variants` is a comma-separated list of names by which the argument is
  ##   presented to the user. These must take the form `<arg>`.
  ## - `default` is the default value of the argument if not given by the
  ##   user; defaults to `T`'s zero value (`default(T)`, e.g. `""`, `0`, or
  ##   `false`).
  ## - `help` is a short description of the argument used in help messages.
  ## - `group` determines how arguments are grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
  ValueArg[T, false](kind: Positional, variants: variants.split(Comma), default: @[default], help: help, group: group, hidden: hidden, validator: validator)

proc arg*(variants: string, default: string = "", help = "", group = "Arguments", hidden = false, validator: Validator[string] = noValidator[string]()): ValueArg[string, false] =
  ## Bare-call convenience for `arg[string]` -- lets `T` default to `string`
  ## without an explicit bracket (e.g. `arg("<name>")`). See `arg[T]` above
  ## for full parameter docs.
  arg[string](variants, default, help, group, hidden, validator)

proc args*[T: not seq](variants: string, default: seq[T] = newSeq[T](), help = "", group = "Arguments", hidden = false, validator: Validator[T] = noValidator[T]()): ValueArg[T, true] =
  ## Creates a positional argument which takes multiple values of type `T`.
  ## If given, `default` can be used to infer `T`; otherwise, `T` defaults to
  ## `string` (see the bare-call overload below) unless set explicitly.
  ## - `variants` is a comma-separated list of names by which the argument is
  ##   presented to the user. These must take the form `<arg>`.
  ## - `default` is the default value(s) of the argument if not given by the
  ##   user; defaults to an empty seq.
  ## - `help` is a short description of the argument used in help messages.
  ## - `group` determines how arguments are grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
  ValueArg[T, true](kind: Positional, variants: variants.split(Comma), default: default, help: help, group: group, hidden: hidden, validator: validator)

proc args*(variants: string, default: seq[string] = @[], help = "", group = "Arguments", hidden = false, validator: Validator[string] = noValidator[string]()): ValueArg[string, true] =
  ## Bare-call convenience for `args[string]` -- lets `T` default to `string`
  ## without an explicit bracket (e.g. `args("<src>")`). See `args[T]` above
  ## for full parameter docs.
  args[string](variants, default, help, group, hidden, validator)

proc opt*[T: not seq](variants: string, default: T = default(T), help = "", group = "Options", hidden = false, validator: Validator[T] = noValidator[T](), env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): ValueArg[T, false] =
  ## Creates an optional argument with a value of type `T`. If given, `default`
  ## can be used to infer `T`; otherwise, `T` defaults to `string` (see the
  ## bare-call overload below) unless set explicitly -- e.g. `opt[int]("-n")`.
  ## - `variants` is a comma-separated list of names by which the option is
  ##   presented to the user. These must take the form `-o` or `--option` and
  ##   may optionally include a help var (e.g., `--option=<value>`).
  ## - `default` is the default value of the option if not given by the
  ##   user; defaults to `T`'s zero value (`default(T)`, e.g. `""`, `0`, or
  ##   `false`).
  ## - `help` is a short description of the option used in help messages.
  ## - `group` determines how options are grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
  ## - `env` optionally names an environment variable supplying this
  ##   option's value when none is given on the command line (a CLI value
  ##   always wins), converted/validated the same way. Applies whether the
  ##   option is required or optional. An option matched more than once
  ##   can take multiple env values, split on `Spec.settings.envDelim` -- see
  ##   `docs/adr/0004-required-options-env-fallback.md` and
  ##   `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`. A
  ##   plain string names the env var alone; `env("NAME", delim)` also
  ##   overrides the delimiter for this option only (`delim = ""` disables
  ##   splitting entirely) -- see
  ##   `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  ## - `configKey` optionally names a structured path (e.g. `configKey("Package",
  ##   "name")`, or a bare string for a 1-segment path) supplying this
  ##   option's value from a registered Config Source when neither a CLI
  ##   nor an env value is given -- consulted below env in Value Precedence,
  ##   above the coded default. See `docs/adr/0018-config-source.md`.
  ValueArg[T, false](kind: Optional, variants: variants.split(Comma), default: @[default], help: help, group: group, hidden: hidden, validator: validator, env: env, cfgKey: configKey)

proc opt*(variants: string, default: string = "", help = "", group = "Options", hidden = false, validator: Validator[string] = noValidator[string](), env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): ValueArg[string, false] =
  ## Bare-call convenience for `opt[string]` -- lets `T` default to `string`
  ## without an explicit bracket (e.g. `opt("--name")`). See `opt[T]` above
  ## for full parameter docs.
  opt[string](variants, default, help, group, hidden, validator, env, configKey)

proc opts*[T: not seq](variants: string, default: seq[T] = newSeq[T](), help = "", group = "Options", hidden = false, validator: Validator[T] = noValidator[T](), env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): ValueArg[T, true] =
  ## Creates an optional argument which takes multiple values of type `T`.
  ## If given, `default` can be used to infer `T`; otherwise, `T` defaults to
  ## `string` (see the bare-call overload below) unless set explicitly.
  ## - `variants` is a comma-separated list of names by which the option is
  ##   presented to the user. These must take the form `-o` or `--option` and
  ##   may optionally include a help var (e.g., `--option=<value>`).
  ## - `default` is the default value(s) of the option if not given by the
  ##   user; defaults to an empty seq.
  ## - `help` is a short description of the option used in help messages.
  ## - `group` determines how options are grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
  ## - `env` optionally names an environment variable supplying this
  ##   option's value(s) when none are given on the command line (a CLI
  ##   value always wins), converted/validated the same way. The raw value
  ##   is split on `Spec.settings.envDelim` into as many values as this option's
  ##   position(s) can consume -- see
  ##   `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`. A
  ##   plain string names the env var alone; `env("NAME", delim)` also
  ##   overrides the delimiter for this option only (`delim = ""` disables
  ##   splitting entirely) -- see
  ##   `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  ## - `configKey` optionally names a structured path supplying this
  ##   option's value(s) from a registered Config Source when none are
  ##   given on the command line or via env -- consulted below env in
  ##   Value Precedence, above the coded default. See
  ##   `docs/adr/0018-config-source.md`.
  ValueArg[T, true](kind: Optional, variants: variants.split(Comma), default: default, help: help, group: group, hidden: hidden, validator: validator, env: env, cfgKey: configKey)

proc opts*(variants: string, default: seq[string] = @[], help = "", group = "Options", hidden = false, validator: Validator[string] = noValidator[string](), env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): ValueArg[string, true] =
  ## Bare-call convenience for `opts[string]` -- lets `T` default to `string`
  ## without an explicit bracket (e.g. `opts("--src")`). See `opts[T]` above
  ## for full parameter docs.
  opts[string](variants, default, help, group, hidden, validator, env, configKey)

macro getFlagOps(typeName: string): untyped =
  if $typeName notin flagOps:
    raise newException(SpecDefect, fmt"{typeName} is not a supported type for flags")
  result = flagOps[$typeName]

proc splitFlagSpellings(variants: string): seq[string] =
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

proc parseFlagOpsString[T](ops: string): seq[FlagOpGroup[T]] =
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
    if op notin getFlagOps($T):
      let escapedOp = strutils.escape(op)
      raise newException(SpecDefect, fmt"{escapedOp} is not a supported operation for {$typeOf(T)} flags")
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

proc flagOp*[T](variants: string, op: string, value: T, help = ""): FlagOpGroup[T] =
  ## Declares one explicit FlagOp Alias group for `flag*`'s `ops` param --
  ## every spelling in `variants` shares this exact Flag Operation
  ## (`op`/`value`) and `help` override. Unlike `flag*`'s own bare
  ## `variants` string (always the type's implicit/blank-op behavior --
  ## see `flag*`), `op` and `value` are mandatory here: a `flagOp` can
  ## never represent a blank operation.
  ## - `variants` is a comma-separated list of bare spellings (`-f`/
  ##   `--flag`).
  ## - `op` is one of the operations registered for `T` via `defineFlag`/
  ##   `defineArg` (e.g. `"="`, `"+="`, `"-="` for the built-in numeric
  ##   types) -- an unsupported op raises `SpecDefect`.
  ## - `value` is the value the operation applies.
  ## - `help` optionally overrides the auto-generated description shown in
  ##   help text (e.g. "Increase by 5") for every spelling in this group.
  if op notin getFlagOps($T):
    let escapedOp = strutils.escape(op)
    raise newException(SpecDefect, fmt"{escapedOp} is not a supported operation for {$typeOf(T)} flags")
  result = (variants: splitFlagSpellings(variants), op: op, value: value, help: help)

proc flag*[T](variants: string = "", ops: varargs[FlagOpGroup[T]] = @[], default: T = default(T), help = "", group = "Options",
    hidden = false, clamp: FlagClamp[T] = noClamp[T](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): FlagArg[T] =
  ## Constructs a new flag, an optional argument that does not take a value and
  ## instead changes value based on the seen variant. If given, `default` can
  ## be used to infer `T`; otherwise, `T` defaults to `bool` (see the bare-call
  ## overload below) unless set explicitly -- e.g. `flag[int]("--boost")`.
  ## - `variants` is a comma-separated list of bare spellings (`-f`/
  ##   `--flag`) that all share the type's implicit/blank-op behavior:
  ##   flipping `default` for bool flags, or incrementing the existing
  ##   value by 1 for int flags. Every spelling here is automatically a
  ##   FlagOp Alias of every other, since they can only ever share one
  ##   `(op, value)` pair.
  ## - `ops` optionally declares one or more explicit FlagOp Alias groups,
  ##   built with `flagOp*` -- each names its own spellings, `op`, `value`,
  ##   and `help`, e.g. `ops = [flagOp("-b, --boost", "+=", 5, "Boost by
  ##   5")]`. Two different `flagOp` groups are always independently
  ##   reachable, even if their `(op, value)` coincidentally match -- see
  ##   `docs/adr/0027-flag-op-declarations.md`.
  ## - `default` is the default value of the flag if not given by the user;
  ##   defaults to `T`'s zero value (`default(T)`, e.g. `false` or `0`).
  ## - `group` determines how flags are grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  ## - `clamp` optionally attaches a `FlagClamp` (`argumint/flagclamp`),
  ##   silently adjusting this flag's value after every Flag Operation --
  ##   never raises, unlike a `Validator` (which never applies to a Flag in
  ##   the first place). `default` must already satisfy `clamp`, or spec
  ##   construction raises `SpecDefect` -- see
  ##   `docs/adr/0016-flag-clamp.md`.
  ## - `env` optionally names an environment variable supplying this
  ##   flag's value when none is given on the command line (a CLI flag
  ##   always wins). Each env value must name one of the flag's own
  ##   declared Variants (e.g. `--verbose`); an unrecognized name raises
  ##   `ParseError`. A flag matched more than once can take multiple env
  ##   values, split on `Spec.settings.envDelim` -- see
  ##   `docs/adr/0004-required-options-env-fallback.md` and
  ##   `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`. A
  ##   plain string names the env var alone; `env("NAME", delim)` also
  ##   overrides the delimiter for this flag only (`delim = ""` disables
  ##   splitting entirely) -- see
  ##   `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  ## - `configKey` optionally names a structured path supplying this
  ##   flag's value from a registered Config Source when none is given on
  ##   the command line or via env -- each value must name one of the
  ##   flag's own declared Variants, same as `env`. Consulted below env in
  ##   Value Precedence, above the coded default. See
  ##   `docs/adr/0018-config-source.md`.
  result = FlagArg[T](kind: Flag, variants: @[], value: default, help: help,
    group: group, hidden: hidden, clamp: clamp, env: env, cfgKey: configKey,
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

proc flag*[T](variants: string = "", ops: string, default: T = default(T), help = "", group = "Options",
    hidden = false, clamp: FlagClamp[T] = noClamp[T](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): FlagArg[T] =
  ## Convenience overload: `ops` as a comma-separated string of
  ## `<flag><op><value>` entries (e.g. `"--quiet=0, --boost+=5,
  ## --dampen-=2"`), each becoming its own single-spelling explicit FlagOp
  ## Alias group -- sugar for, and parsed into, the equivalent array of
  ## `flagOp*` calls. A multi-spelling explicit group, or a value with no
  ## string spelling, still needs the array form directly. See `flag[T]`
  ## above for full parameter docs, and
  ## `docs/adr/0028-flag-ops-string-convenience.md` for why this is a
  ## separate overload rather than folded into `variants` itself.
  flag[T](variants, parseFlagOpsString[T](ops), default, help, group, hidden, clamp, env, configKey)

proc command*[S](variants: string, spec: S, help = "", prolog = "", epilog = "", usage = "", group = "Commands", hidden = false,
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil): CommandArg =
  ## - `variants` is a comma-separated list of names by which the command can be
  ##   called by the user.
  ## - `spec` is a spec tuple representing all possible args this command takes.
  ## - `help` is a short description of the command used in help messages.
  ## - `prolog` is the front matter for help messages generated for this
  ##   command. Use this to provide a detailed description of the command's
  ##   purpose.
  ## - `epilog` is the end matter for help messages generated for this command.
  ## - `usage` is the usage string that controls how the command's args can be
  ##   invoked.
  ## - `group` determines how this command is grouped in help messages.
  ## - `hidden`, if `true`, prevents the command from appearing in help messages
  ## - `before` fires once this command's own `spec`'s values are parsed
  ## - `action` fires after `before`, but only if this command is the dynamic
  ##   leaf (no nested command was also matched)
  ## - `after` fires after this command's own `before`/`action`/nested dispatch.
  ## - Each hook receives `info: HookInfo`, a view of every Arg matched
  ##   during this whole invocation (not just this command's own level) --
  ##   e.g. `info.showsMessage` to skip expensive hook work for a
  ##   `--help`/`--version`/message request. See
  ##   `docs/adr/0021-hook-info-matched-args.md`.
  ##
  ## For more information on how before/action/after hooks are used, see
  ## `docs/adr/0009-command-before-action-after-hooks.md`.
  ##
  ## Note: `config` is deliberately not a parameter here: it cascades down
  ## by reference from whatever the top-level `newSpec`/`parse*` call is
  ## given (see `cascadeSpecSettings`), so it only needs to be specified once
  ## regardless of how deeply nested this command is.
  result = CommandArg(kind: ArgKind.Command, variants: variants.split(Comma), help: help, group: group, hidden: hidden)
  result.spec = newSpec(spec, usage, prolog, epilog)
  if not before.isNil:
    result.spec.before = (info: HookInfo) => before(spec, info)
  if not action.isNil:
    result.spec.action = (info: HookInfo) => action(spec, info)
  if not after.isNil:
    result.spec.after = (info: HookInfo) => after(spec, info)

proc command*[S, O](variants: string, spec: S, options: O, help = "", prolog = "", epilog = "", usage = "", group = "Commands", hidden = false,
    before: proc(spec: S, opts: O, info: HookInfo) = nil,
    action: proc(spec: S, opts: O, info: HookInfo) = nil,
    after: proc(spec: S, opts: O, info: HookInfo) = nil): CommandArg =
  ## - `variants` is a comma-separated list of names by which the command can be
  ##   called by the user.
  ## - `spec` is a spec tuple representing all possible args this command takes.
  ## - `options` is a generic extra-context passthrough, not necessarily
  ##   CLI-options-shaped data -- typically the caller's enclosing/parent spec
  ##   tuple (or any other context object), so a nested command's hooks can
  ##   read outer/global state that `spec: S` alone -- scoped to just this
  ##   command's own tuple -- wouldn't otherwise expose.
  ## - `help` is a short description of the command used in help messages.
  ## - `prolog` is the front matter for help messages generated for this
  ##   command. Use this to provide a detailed description of the command's
  ##   purpose.
  ## - `epilog` is the end matter for help messages generated for this command.
  ## - `usage` is the usage string that controls how the command's args can be
  ##   invoked.
  ## - `group` determines how this command is grouped in help messages.
  ## - `hidden`, if `true`, prevents the command from appearing in help messages
  ## - `before` fires once this command's own `spec`'s values are parsed
  ## - `action` fires after `before`, but only if this command is the dynamic
  ##   leaf (no nested command was also matched)
  ## - `after` fires after this command's own `before`/`action`/nested dispatch.
  ## - Each hook receives `info: HookInfo`, a view of every Arg matched
  ##   during this whole invocation (not just this command's own level) --
  ##   e.g. `info.showsMessage` to skip expensive hook work for a
  ##   `--help`/`--version`/message request. See
  ##   `docs/adr/0021-hook-info-matched-args.md`.
  ##
  ## For more information on how before/action/after hooks are used, see
  ## `docs/adr/0009-command-before-action-after-hooks.md`.
  ##
  ## Note: `config` is deliberately not a parameter here: it cascades down
  ## by reference from whatever the top-level `newSpec`/`parse*` call is
  ## given (see `cascadeSpecSettings`), so it only needs to be specified once
  ## regardless of how deeply nested this command is.
  command(variants, spec, help, prolog, epilog, usage, group, hidden,
    before = if before.isNil: nil else: (proc(cmdSpec: S, info: HookInfo) = before(spec, options, info)),
    action = if action.isNil: nil else: (proc(cmdSpec: S, info: HookInfo) = action(spec, options, info)),
    after = if after.isNil: nil else: (proc(cmdSpec: S, info: HookInfo) = after(spec, options, info)))

proc help*(variants = "-h, --help", help = "Display this help message", group = "Options", hidden = false): HelpArg =
  ## Creates a flag which, when matched, displays an auto-generated help message
  ## for the spec in whose context it was called.
  ## - `variants` is a comma-separated list of names by which the flag is
  ##   presented to the user. These must take the form `-o` or `--option`.
  ## - `help` is a short description of the flag used in help messages.
  ## - `group` determines how the flag is grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  HelpArg(kind: Flag, variants: variants.split(Comma), help: help, group: group, hidden: hidden)

proc message*(variants: string, text: string, help = "", group = "Options", hidden = false): MessageArg =
  ## Creates a flag which, when matched, displays `text` and exits
  ## successfully instead of parsing further arguments.
  ## - `variants` is a comma-separated list of names by which the flag is
  ##   presented to the user. These must take the form `-o` or `--option`.
  ## - `text` is the message to display when the flag is matched.
  ## - `help` is a short description of the flag used in help messages.
  ## - `group` determines how the flag is grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  MessageArg(kind: Flag, variants: variants.split(Comma), message: text, help: help, group: group, hidden: hidden)

proc version*(variants: string, version: string, help = "Display version information", group = "Options", hidden = false): MessageArg =
  ## Thin wrapper around `message` for the common case of a version flag.
  ## - `variants` is a comma-separated list of names by which the flag is
  ##   presented to the user. These must take the form `-v` or `--version`.
  ## - `version` is the message to display when the flag is matched.
  ## - `help` is a short description of the flag used in help messages.
  ## - `group` determines how the flag is grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  message(variants, version, help, group, hidden)

# ------------------------------------------------------------------------------
# Here is where we define the datatypes supported out of the box.
# ------------------------------------------------------------------------------

defineArg string:
  ## Builds a flag handler for a string.
  case op
  of "=": value = arg
  else: raise newException(SpecDefect, fmt"string flags only support = operations")

defineFlag bool, "Toggle the value":
  ## Handles a flag value for a bool. If `op` is blank, `arg` must be the
  ## default value of the flag, which will be inverted.
  case op
  of "": value = not arg
  of "=": value = arg
  else: raise newException(SpecDefect, fmt"boolean flags only support = operations")

# flag*(bool) lives here, not beside flag*[T] above, because its body calls
# flag[bool](...) eagerly -- that instantiation needs "bool" already
# registered in flagOps by the defineFlag call just above (see
# docs/gotchas.md).
proc flag*(variants: string = "", ops: varargs[FlagOpGroup[bool]] = @[], default: bool = false, help = "", group = "Options",
    hidden = false, clamp: FlagClamp[bool] = noClamp[bool](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): FlagArg[bool] =
  ## Bare-call convenience for `flag[bool]` -- lets `T` default to `bool`
  ## without an explicit bracket (e.g. `flag("--verbose")`). See `flag[T]`
  ## above for full parameter docs.
  flag[bool](variants, ops, default, help, group, hidden, clamp, env, configKey)

proc flag*(variants: string = "", ops: string, default: bool = false, help = "", group = "Options",
    hidden = false, clamp: FlagClamp[bool] = noClamp[bool](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): FlagArg[bool] =
  ## Bare-call convenience for `flag[bool]`'s `ops: string` overload --
  ## lets `T` default to `bool` without an explicit bracket. See `flag[T]`
  ## above for full parameter docs.
  flag[bool](variants, ops, default, help, group, hidden, clamp, env, configKey)

defineFlag int, "Increment by 1":
  ## Builds a flag handler for an integer. If `op` is blank, the default
  ## is to increment the value.
  case op
  of "": value.inc
  of "=": value = arg
  of "+=": value.inc arg
  of "-=": value.dec arg
  else: raise newException(SpecDefect, "integer flags only support =, +=, and -= operations")

defineArg float64:
  case op
  of "=": value = arg
  of "+=": value += arg
  of "-=": value -= arg
  else: raise newException(SpecDefect, "float flags only support =, +=, and -= operations")

defineArg char:
  case op
  of "=": value = arg
  else: raise newException(SpecDefect, "char flags only support = operations")

# ------------------------------------------------------------------------------
# These are the functions that handle shell completion and initiate parsing.
# ------------------------------------------------------------------------------

proc isCompletionRequest*(args: seq[string] = commandLineParams()): bool =
  ## Returns whether `args` is a shell-completion request (see
  ## `docs/adr/0012-fsm-driven-shell-completion.md`) -- i.e. whether calling
  ## `parse*`/`parseOrQuit*` with these same `args` would short-circuit into
  ## completion handling rather than a real run.
  ##
  ## Each completion request re-invokes the binary as a fresh process, so
  ## setup code run *before* `parse*`/`parseOrQuit*` (config loading, a DB
  ## connection) reruns on every keystroke, not just real invocations --
  ## unlike `before`/`action`/`after` hooks, which are already skipped
  ## during completion. Guard expensive pre-parse setup with this:
  ## ```nim
  ## when isMainModule:
  ##   if isCompletionRequest():
  ##     spec.parse(...)          # skip straight past expensive setup
  ##   else:
  ##     setupDatabaseConnection()
  ##     spec.parse(...)
  ## ```
  args.len > 0 and args[0] == "__complete"

proc parseOrQuit*(spec: Spec, args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename())) =
  ## Like `parse*(Spec)`, but prints a message and `quit()`s instead of
  ## raising on failure -- intended for a bare CLI `main()`, not for
  ## embedding in a larger program.
  ##
  ## `spec` is **single-use**, same as `parse*(Spec)` -- and, being a built
  ## `Spec` rather than a spec tuple, it has no `parsed*` counterpart. Build
  ## a fresh one per parse. See
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  try:
    spec.parse(args, command)
  except ParseError as e:
    quit("Parsing error: {e.msg}".fmt)
  except ValidationError as e:
    quit("Validation error: {e.msg}".fmt)
  except HelpError as e:
    quit(e.msg, QuitSuccess)
  except CompletionError as e:
    # Must land on stdout, not stderr like quit() -- see docs/gotchas.md.
    echo e.msg
    quit(QuitSuccess)
  except MessageError as e:
    quit(e.msg, QuitSuccess)

proc buildAndBind[S: tuple](spec: S, usage, prolog, epilog: string, settings: SpecSettings,
    before, action, after: proc(spec: S, info: HookInfo)): Spec =
  ## Builds `spec` and binds whichever hooks were given, each closing over
  ## `spec` itself. Shared by all four tuple entry points so a hook can
  ## never be bound to a different tuple than the one its caller returns --
  ## see docs/adr/0031-parsed-fresh-spec-per-parse.md.
  result = newSpec(spec, usage, prolog, epilog, settings)
  if not before.isNil: result.before = (info: HookInfo) => before(spec, info)
  if not action.isNil: result.action = (info: HookInfo) => action(spec, info)
  if not after.isNil: result.after = (info: HookInfo) => after(spec, info)

proc parseOrQuit*[S: tuple](spec: S, usage = "", prolog = "", epilog = "",
    settings = newSpecSettings(),
    args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename()),
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil) =
  ## Like `parse*(tuple)`, but prints a message and `quit()`s instead of
  ## raising on failure -- intended for a bare CLI `main()`, not for
  ## embedding in a larger program.
  ## - `usage` is the usage string used to build the FSM. See `autoFillUsage`
  ##   for how gaps in `usage` are auto-filled.
  ## - `prolog` is the front matter for help messages generated from this spec.
  ## - `epilog` is the end matter for help messages generated from this spec.
  ## - `settings` holds `width`/`maxVariantsWidth`/`envDelim` -- see
  ##   `newSpecSettings`. Shared by reference with every nested subcommand's
  ##   spec; mutating it later (e.g. from a `before` hook) applies live
  ##   throughout the tree.
  ## - `args` is the command-line arguments to parse using the spec.
  ## - `command` is the name of the binary to use in help messages.
  ## - `before` fires once this `spec`'s own values are parsed
  ## - `action` fires after `before`, but only if this spec is the dynamic leaf
  ##   (no nested command was matched)
  ## - `after` fires after this spec's own `before`/`action`/nested dispatch.
  ## - Each hook receives `info: HookInfo`, a view of every Arg matched
  ##   during this whole invocation -- e.g. `info.showsMessage` to skip
  ##   expensive hook work for a `--help`/`--version`/message request. See
  ##   `docs/adr/0021-hook-info-matched-args.md`.
  ##
  ## `before`/`action`/`after` are app-level hooks around the
  ## whole parse -- see `docs/adr/0009-command-before-action-after-hooks.md`.
  ##
  ## `spec` is **single-use**: parsing more than once accumulates into the
  ## same Args rather than starting fresh. Use `parsedOrQuit*` to parse a
  ## fresh spec per call -- see
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  try:
    spec.buildAndBind(usage, prolog, epilog, settings, before, action, after)
      .parseOrQuit(args, command)
  except SpecDefect as e:
    quit(fmt"Error constructing spec: {e.msg}")

proc parse*[S: tuple](spec: S, usage = "", prolog = "", epilog = "",
    settings = newSpecSettings(),
    args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename()),
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil) =
  ## Builds `spec` into a `Spec` via `newSpec` and parses `args` against it in
  ## one step. Raises `SpecDefect` (malformed spec), or `ParseError`/
  ## `ValidationError`/`HelpError`/`MessageError` (parse failure) -- use
  ## `parseOrQuit*` if you want those to print a message and `quit()` instead.
  ## - `usage` is the usage string used to build the FSM. See `autoFillUsage`
  ##   for how gaps in `usage` are auto-filled.
  ## - `prolog` is the front matter for help messages generated from this spec.
  ## - `epilog` is the end matter for help messages generated from this spec.
  ## - `settings` holds `width`/`maxVariantsWidth`/`envDelim` -- see
  ##   `newSpecSettings`. Shared by reference with every nested subcommand's
  ##   spec; mutating it later (e.g. from a `before` hook) applies live
  ##   throughout the tree.
  ## - `args` is the command-line arguments to parse using the spec.
  ## - `command` is the name of the binary to use in help messages.
  ## - `before` fires once this `spec`'s own values are parsed
  ## - `action` fires after `before`, but only if this spec is the dynamic leaf
  ##   (no nested command was matched)
  ## - `after` fires after this spec's own `before`/`action`/nested dispatch.
  ## - Each hook receives `info: HookInfo`, a view of every Arg matched
  ##   during this whole invocation -- e.g. `info.showsMessage` to skip
  ##   expensive hook work for a `--help`/`--version`/message request. See
  ##   `docs/adr/0021-hook-info-matched-args.md`.
  ##
  ## `before`/`action`/`after` are app-level hooks around the
  ## whole parse -- see `docs/adr/0009-command-before-action-after-hooks.md`.
  ##
  ## `spec` is **single-use**: parsing more than once accumulates into the
  ## same Args rather than starting fresh -- a repeated `opts` appends, a
  ## `flag` keeps applying its Flag Operation, and an `opt` retains an
  ## earlier value into a later parse that never mentioned it. Use `parsed*`
  ## to parse a fresh spec per call -- see
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  spec.buildAndBind(usage, prolog, epilog, settings, before, action, after)
    .parse(args, command)

# ------------------------------------------------------------------------------
# `parsed*`/`parsedOrQuit*`: parse a *fresh* spec and return it, leaving the
# caller's own untouched -- see docs/adr/0031-parsed-fresh-spec-per-parse.md.
# ------------------------------------------------------------------------------

proc parsed*[S: tuple](build: proc (): S, usage = "", prolog = "", epilog = "",
    settings = newSpecSettings(),
    args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename()),
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil): S =
  ## Calls `build` for a brand-new spec tuple, parses `args` into it, and
  ## returns it. Every other parameter behaves exactly as on `parse*(tuple)`,
  ## which this raises like.
  ##
  ## Unlike `parse*`/`parseOrQuit*`, which accumulate into the Args they're
  ## given, this makes a parse a pure function of `args` -- so the same
  ## `build` can be parsed any number of times, each result independent:
  ## ```nim
  ## proc buildCli(): auto =
  ##   (name: arg("<name>"), times: opt("-t=<n>", default = 1), help: help())
  ##
  ## for line in stdin.lines:
  ##   let cli = parsed(buildCli, args = line.splitWhitespace, command = "repl")
  ##   echo cli.name
  ## ```
  ## Values for a Command's own nested spec are reachable only through that
  ## Command's `before`/`action`/`after` hooks, not off the returned tuple:
  ## a spec tuple holds a `CommandArg`, not the nested tuple itself.
  ##
  ## Takes a builder rather than a spec tuple deliberately -- copying an
  ## already-built tuple can't be made correct, see
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  result = build()
  result.buildAndBind(usage, prolog, epilog, settings, before, action, after)
    .parse(args, command)

proc parsedOrQuit*[S: tuple](build: proc (): S, usage = "", prolog = "", epilog = "",
    settings = newSpecSettings(),
    args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename()),
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil): S =
  ## Like `parsed*`, but prints a message and `quit()`s instead of raising
  ## on failure -- the `parseOrQuit*`/`parse*` distinction, unchanged.
  try:
    result = build()
    result.buildAndBind(usage, prolog, epilog, settings, before, action, after)
      .parseOrQuit(args, command)
  except SpecDefect as e:
    quit(fmt"Error constructing spec: {e.msg}")

proc dot*(spec: Spec): string =
  ## Renders `spec`'s FSM as a Graphviz dot graph, useful for debugging or
  ## visualizing how a usage string is parsed. For a subcommand, use
  ## `cmdArg.spec.dot`.
  spec.fsm.dot

proc dot*(spec: tuple, usage = "", prolog = "", epilog = ""): string =
  ## Compiles `spec` and renders its FSM as a Graphviz dot graph. See
  ## `dot(Spec)` for details.
  try:
    newSpec(spec, usage, prolog, epilog).dot
  except SpecDefect as e:
    quit(fmt"Error constructing spec: {e.msg}")

proc completionScript*(spec: Spec, shell: Shell, binaryName = extractFilename(getAppFilename())): string =
  ## Returns a shell-completion script for `shell` that completes
  ## `binaryName` by shelling out to it (`<binaryName> __complete
  ## <words...>`) -- see `docs/adr/0012-fsm-driven-shell-completion.md`.
  ## Author-driven, like `dot*`: install the result however your packaging
  ## needs (write it to a file, expose a `completion` subcommand, etc.) --
  ## argumint doesn't wire this up automatically.
  spec.genCompletionScript(shell, binaryName)

when isMainModule:
  ## Direct regression tests for the `defineArg`/`defineFlag`/`defineFlagArg`/
  ## `defineSetFlag` macro machinery above, one per hygiene workaround
  ## documented in `docs/gotchas.md` -- each instantiates `ValueArg`/`FlagArg`
  ## directly and drives the generated methods by hand, bypassing `Spec`/
  ## `parse*` entirely (one test also uses the real `flag*` constructor,
  ## since the CacheTable it reads from can only be exercised that way), so
  ## a regression here fails right at the template instead of three layers
  ## downstream at some other test's `spec.parse()` call. See
  ## `tests/test_argumint.nim`'s `Priority`/`Level`/`Speed`/`Color` for the
  ## complementary integration coverage (that these types work correctly
  ## *through* the full pipeline) -- this suite is deliberately narrower and
  ## doesn't duplicate it.
  import std/unittest

  type Rank = enum
    rLow, rMid, rHigh

  converter toRank(value: string): Rank = parseEnum[Rank](value)

  type Grade = enum
    gPoor, gFair, gGood

  # Regression test for the template-hygiene gotcha in docs/gotchas.md --
  # exercises defineFlag/defineFlagArg/defineArg together; a corruption
  # would fail to compile, not fail an assertion.
  defineFlag(Rank, "Bump to the next rank"):
    case op
    of "": value = Rank((ord(value) + 1) mod 3)
    of "=": value = arg
    else: raise newException(SpecDefect, "rank flags only support blank or = operations")

  defineSetFlag(Rank)
  defineSetFlag(Grade)

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

  suite "defineArg/defineFlag macro machinery":
    test "a ValueArg's generated parse/defaultStr work when constructed directly, bypassing arg()":
      let a = ValueArg[Rank, false](kind: Positional, variants: @["<rank>"])
      a.parse("rHigh")
      check a.value[0] == rHigh
      check a.defaultStr() == ""

    test "a FlagArg's generated parse()/variantDesc() are correct -- % (not fmt) inside a defineFlagArg-generated method, and defineFlag's blankDesc wiring":
      let f = FlagArg[Rank](kind: Flag, variants: @["-r", "-b"])
      f.ops = newOrderedTable[string, FlagOp[Rank]]()
      f.ops["-r"] = ("=", rHigh, "")
      f.ops["-b"] = ("", rLow, "")
      expect SpecDefect:
        f.parse("", "--unknown")
      try:
        f.parse("", "--unknown")
      except SpecDefect as e:
        check "--unknown" in e.msg
        check "-r" in e.msg
      check f.variantDesc("-b") == "Bump to the next rank"

    test "defineSetFlag's =/+=/-=/*= ops all work on a directly-constructed FlagArg[set[T]]":
      let f = FlagArg[set[Rank]](kind: Flag, variants: @["-r"])
      f.ops = newOrderedTable[string, FlagOp[set[Rank]]]()
      f.ops["="] = ("=", {rLow}, "")
      f.ops["+="] = ("+=", {rMid}, "")
      f.ops["-="] = ("-=", {rLow}, "")
      f.ops["*="] = ("*=", {rMid}, "")

      f.parse("", "=")
      check f.value == {rLow}
      f.parse("", "+=")
      check f.value == {rLow, rMid}
      f.parse("", "-=")
      check f.value == {rMid}
      f.parse("", "*=")
      check f.value == {rMid}

    test "two distinct defineSetFlag(enum) instantiations don't cross-wire in the flagOps CacheTable":
      # Regression test for the repr-vs-$ CacheTable keying in
      # docs/gotchas.md -- calls the real flag[set[Rank]]/flag[set[Grade]]
      # constructors to exercise both the write and read side.
      let rankFlag = flag[set[Rank]](ops = [flagOp("--rank", "+=", {rHigh})], default = {})
      rankFlag.parse("", "--rank")
      check rankFlag.value == {rHigh}

      let gradeFlag = flag[set[Grade]](ops = [flagOp("--grade", "+=", {gGood})], default = {})
      gradeFlag.parse("", "--grade")
      check gradeFlag.value == {gGood}
      check rankFlag.value == {rHigh} # unaffected by gradeFlag's own +=

    test "repeated parse() calls on a multi-value ValueArg don't corrupt earlier elements (ORC regression)":
      let a = ValueArg[Rank, true](kind: Positional, variants: @["<rank>"])
      a.parse("rLow")
      a.parse("rMid")
      a.parse("rHigh")
      check a.value == @[rLow, rMid, rHigh]
