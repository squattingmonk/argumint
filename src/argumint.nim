import std/[macros, macrocache, os, options, pegs, sequtils, sets, sugar, strformat, strutils, tables, wordwrap]

import ./argumint/[backend, dot, fsm, parser, validators]

# Re-exported so `import argumint` alone is enough to catch everything
# `parse*`/`parseOrQuit*`/`newSpec` can raise, without also reaching into
# `argumint/backend`/`argumint/validators`/`argumint/lexer` by hand.
export ParseError, ValidationError, HelpError, MessageError, SpecDefect

type
  ValueArg[T: not seq, multi: static bool] = ref object of Arg
    value: Option[seq[T]]
    default: seq[T]
    validator: Validator[T]
    env: string

  FlagOp[T] = tuple[op: string, arg: T, desc: string]

  FlagArg[T] = ref object of Arg
    value: T
    ops: OrderedTableRef[string, FlagOp[T]]
    env: string

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
    # Allows you to capture [-f, =, val] / [--flag, =, val] in -f=val /
    # --flag=val, where = is any op in [=, +=, -=].
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
  let usage = spec.usage.formatUsage(command, spec.width) & "\n"

  var rawColWidth = 0
  for arg in spec.args:
    for vg in arg.variantGroups():
      rawColWidth = max(rawColWidth, vg.names.join(", ").len)
  let colWidth =
    if spec.maxVariantsWidth > 0: min(rawColWidth, spec.maxVariantsWidth)
    else: rawColWidth

  let continuationIndent = "    " # deeper than the "  " row margin, so a wrapped
                                   # variants continuation (or a divergent-op
                                   # sub-row) isn't mistaken for a new arg

  var lines: seq[string]
  for group in spec.groupOrder:
    var argLines: seq[string]
    for arg in spec.groups[group]:
      let groups = arg.variantGroups()
      for i, vg in groups:
        let variants = vg.names.join(", ")
        let margin = if i == 0: "  " else: continuationIndent
        let text =
          if i > 0: vg.desc
          else:
            var annotations: seq[string]
            if arg.validatorHelp.len > 0: annotations.add arg.validatorHelp
            if arg.defaultStr.len > 0: annotations.add "default: {arg.defaultStr}".fmt
            if arg.envName.len > 0: annotations.add "env: {arg.envName}".fmt
            if groups.len > 1 and vg.desc.len > 0: annotations.add "action: {vg.desc}".fmt
            let bracket = if annotations.len > 0: "[{annotations.join(\"; \")}]".fmt else: ""
            if bracket.len == 0: arg.help
            elif arg.help.len == 0: bracket
            else: "{arg.help} {bracket}".fmt
        let variantLines = variants.wrapWords(colWidth, splitLongWords = false).splitLines
        if text.len > 0:
          let helpWidth = max(spec.width - (2 + colWidth + 2), 20)
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
      self.validator.validate(tmp)
    when multi:
      # NOTE: appending via `self.value = some(self.value.get & @[tmp])`
      # corrupts earlier elements under ORC when `self` is a generic ref
      # object carrying a `static bool` param (as `ValueArg` does) -- copying
      # to a local var first avoids the miscompilation.
      if self.value.isSome:
        var s = self.value.get
        s.add(tmp)
        self.value = some(s)
      else:
        self.value = some(@[tmp])
    else:
      self.value = some(@[tmp])
  except ValidationError as e:
    raise newException(ValidationError, fmt"for {self.name(variant)}, {e.msg}")
  except ValueError:
    raise newException(ParseError, fmt"expected {$typeOf(T)} for {self.name(variant)} but got {value.escape}")

macro defineFlagOps(typeName, body: untyped) =
  # echo "This is the input to our macro:"
  # echo body.treeRepr
  body.expectLen 1
  let caseBody = body.findChild(it.kind == nnkCaseStmt) or body.findChild(it.kind == nnkStmtList).findChild(it.kind == nnkCaseStmt)

  # echo "found ", caseBody.treeRepr
  caseBody.expectKind nnkCaseStmt
  caseBody.expectMinLen 3 # ident + at least 2 of branches

  var ops = nnkBracket.newTree()

  for op in caseBody[1..^1]:
    # echo op.treeRepr()
    op.expectKind {nnkOfBranch, nnkElse, nnkElifBranch}
    case op.kind
    of nnkOfBranch:
      for opStr in op[0..^2]:
        opStr.expectKind nnkStrLit
        ops.add opStr
      op[^1].expectKind nnkStmtList
    else:
      discard

  flagOps[$typeName] = ops

template defineArg*[T](typeName: typedesc[T]): untyped =
  ## Defines parse methods for arguments with a value of type `T`. Use this
  ## version if you want to write your own converter to parse a string into a
  ## `T`.
  method parse*(self: ValueArg[T, false], value: string, variant = "") =
    self.parseImpl(value, variant)

  method parse*(self: ValueArg[T, true], value: string, variant = "") =
    self.parseImpl(value, variant)

  method defaultStr*(self: ValueArg[T, false]): string =
    ## Returns `self`'s default value stringified, or "" if it's still `T`'s
    ## zero value (e.g. "", 0, or false) -- the fallback used when no
    ## default was given (see `arg*`). Requires `T` to support `default(T)`
    ## and `==`, which nearly every type does; a `{.requiresInit.}` object
    ## would be a rare exception that fails to compile here.
    if self.default.len > 0 and self.default[0] != default(T):
      $self.default[0]
    else:
      ""

  method defaultStr*(self: ValueArg[T, true]): string =
    ## Returns `self`'s default values comma-joined, or "" if there are none.
    if self.default.len > 0:
      self.default.mapIt($it).join(", ")
    else:
      ""

  method validatorHelp*(self: ValueArg[T, false]): string =
    if self.validator.isNil: "" else: self.validator.help()

  method validatorHelp*(self: ValueArg[T, true]): string =
    if self.validator.isNil: "" else: self.validator.help()

  method envName*(self: ValueArg[T, false]): string = self.env

  method envName*(self: ValueArg[T, true]): string = self.env

  method setFromEnv*(self: ValueArg[T, false], value: string) =
    self.parseImpl(value, self.env)

  method setFromEnv*(self: ValueArg[T, true], value: string) =
    self.parseImpl(value, self.env)

template defineFlagArg[T](typeName: typedesc[T], blankDesc: string, flagHandler: untyped): untyped =
  ## Shared implementation for `defineArg` and `defineFlag` below.
  ## **Gotcha**: this is deliberately its own template rather than having
  ## `defineArg`/`defineFlag` overload each other or call each other
  ## directly -- two generic templates sharing a name, each forwarding an
  ## `untyped` param down to a nested `{.inject.}` proc, corrupt each
  ## other's hygiene in this Nim version (`op`/`arg` end up undeclared
  ## inside `flagHandler`, even in the overload that resolves correctly).
  ## Distinct names sidestep it. Relatedly, `variantDesc`'s own locals below
  ## are named `vOp`/`vArg`/`vDesc`, not `op`/`arg` -- reusing those names
  ## collides with the `{.inject.}`ed `op`/`arg` from `parse*` below, which
  ## leak into this template's whole scope (that's the point of `inject`),
  ## not just into `flagHandler`.
  defineFlagOps typeName:
    flagHandler

  proc handleFlag(value {.inject.}: var T, op {.inject.}: string, arg {.inject.}: T) =
    flagHandler

  method parse*(self: FlagArg[T], _: string, variant = "") =
    let name = self.name(variant)
    if not self.ops.hasKey(name):
      raise newException(SpecDefect, "$# is not a known variant for the flag $#" % [name, self.name])
    let (op {.inject.}, arg {.inject.}, _) = self.ops[name]
    self.value.handleFlag(op, arg)

  method variantDesc*(self: FlagArg[T], variant: string): string =
    if not self.ops.hasKey(variant): return ""
    let (vOp, vArg, vDesc) = self.ops[variant]
    if vDesc.len > 0: return vDesc
    case vOp
    of "=": "Set to " & $vArg
    of "+=": "Increase by " & $vArg
    of "-=": "Decrease by " & $vArg
    else: blankDesc

  method envName*(self: FlagArg[T]): string = self.env

  method setFromEnv*(self: FlagArg[T], envValue: string) =
    # `envValue`, not `value` -- `value` is one of the names `{.inject.}`ed
    # by `handleFlag` above, and leaks into this whole template's scope.
    # Uses `%` rather than `fmt` -- `fmt` string interpolation can't
    # resolve identifiers (not even `self`/params) when the containing
    # method is generated inside a template like this one; `%`/`&` don't
    # have that problem, which is why the rest of this template uses them.
    try:
      let t: T = envValue
      self.value.handleFlag("=", t)
    except ValueError:
      raise newException(ParseError, "expected $# for $# but got $#" % [$typeOf(T), self.env, envValue.escape])

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

method parse*(self: CommandArg, _: string, variant = "") =
  # echo fmt"Entering {self.name(variant)}"
  if not self.handler.isNil:
    self.handler()

method parse*(self: MessageArg, _: string, variant = "") =
  raise newException(MessageError, self.message)

method parse*(self: HelpArg, command: string, spec: Spec, variant = "") =
  raise newException(HelpError, spec.genHelp(command))

# ------------------------------------------------------------------------------
# Convenience functions that allow easy unpacking of values from args.
# ------------------------------------------------------------------------------

converter toT*[T](arg: ValueArg[T, false]): T =
  ## Converts a `ValueArg[T, false]` to a `T`, substituting a default value if
  ## no value was set by the user.
  arg.value.get(otherwise = arg.default)[0]

converter toSeqT*[T](arg: ValueArg[T, true]): seq[T] =
  ## Converts a `ValueArg[T, true]` to a `seq[T]`, substituting a default
  ## value if no value was set by the user.
  arg.value.get(otherwise = arg.default)

converter toT*[T](arg: FlagArg[T]): T =
  ## Converts a `FlagArg[T]` to a `T`.
  arg.value

# ------------------------------------------------------------------------------
# Spec Construction
# ------------------------------------------------------------------------------

proc addArg(spec: Spec, arg: Arg, varName: string) =
  if arg.variants.len < 1:
    raise newException(SpecDefect, fmt"Error: arg {varName} must have at least one variant")
  spec.args.add(arg)
  if spec.groups.hasKeyOrPut(arg.group, @[arg]):
    spec.groups[arg.group].add(arg)

  for variant in arg.variants:
    case arg.kind
    of Positional:
      # Matches `<arg>`
      if variant =~ PositionalVariantFormat:
        if spec.arguments.hasKeyOrPut(matches[0], arg):
          raise newException(SpecDefect, fmt"Error: argument {matches[0]} already defined")
      else:
        raise newException(SpecDefect, fmt"Error: invalid positional arg variant for {varName}: {variant}")
    of Optional, Flag:
      # Matches `-o[=<foo>]` or `--option[=<foo>]` but removes any help vars
      if variant =~ OptionalVariantFormat:
        if spec.options.hasKeyOrPut(matches[0], arg):
          raise newException(SpecDefect, fmt"Error: option {matches[0]} already defined")
      else:
        raise newException(SpecDefect, fmt"Error: invalid optional arg variant for {varName}: {variant}")
    of Command:
      if spec.commands.hasKeyOrPut(variant, CommandArg(arg)):
        raise newException(SpecDefect, fmt"Error: command {variant} already defined")

proc addArgs(self: Spec, spec: tuple) =
  for varName, arg in spec.fieldPairs:
    when arg is Arg:
      self.addArg(arg, varName)
    elif arg is tuple:
      self.addArgs(arg)
    else:
      raise newException(SpecDefect, fmt"Error: all members of a spec tuple must be args or tuples, but {varName} is {$typeof(arg)}")

proc autoFillUsage(spec: Spec) =
  ## Appends a usage line for any declared command or MessageArg (e.g. one
  ## created by `help()`) that ends up unreachable, and for positional args
  ## or a `[options]` catch-all when the *entire* category is unreachable --
  ## so callers only need to hand-write the parts of the grammar they want
  ## to customize. Rebuilds the FSM if anything was appended. This can't
  ## safely fill in a *partially*-mentioned positional-arg sequence (which
  ## one is missing, and where would it go?), nor weave `[options]` into an
  ## arbitrary hand-written line that's missing it -- only the case where
  ## nothing else was generated falls back to a standalone `[options]` line.
  ## All unreachable commands are joined into a single `(cmd1 | cmd2)`
  ## alternation line (rather than one line per command) so a shared
  ## `[options]` prefix isn't repeated for each one; MessageArgs still get
  ## their own line each, since they never carry that prefix to begin with.
  let usageLenBefore = spec.usage.len
  let reachable = spec.fsm.referencedArgs()
  let optionsUnreachable = spec.options.values.toSeq.deduplicate
    .anyIt(not (it of MessageArg) and it notin reachable)
  let prefix = if optionsUnreachable: "[options] " else: ""
  var prefixUsed = false

  let unreachableCommands = spec.args.filterIt(it.kind == Command and it notin reachable)
  if unreachableCommands.len > 0:
    let variants = unreachableCommands.mapIt(it.variants).concat
    let combined = if variants.len > 1: "(" & variants.join(" | ") & ")" else: variants[0]
    spec.usage.addSep("\n")
    spec.usage.add prefix & combined
    prefixUsed = prefixUsed or optionsUnreachable

  let positionals = spec.args.filterIt(it.kind == Positional)
  if positionals.len > 0 and positionals.allIt(it notin reachable):
    spec.usage.addSep("\n")
    spec.usage.add prefix & positionals.mapIt(it.name).join(" ")
    prefixUsed = prefixUsed or optionsUnreachable

  for arg in spec.args.filterIt(it of MessageArg and it notin reachable):
    let variants = if arg.variants.len > 1: "(" & arg.variants.join(" | ") & ")" else: arg.variants[0]
    spec.usage.addSep("\n")
    spec.usage.add variants

  if optionsUnreachable and not prefixUsed:
    spec.usage.addSep("\n")
    spec.usage.add "[options]"

  if spec.usage.len > usageLenBefore:
    spec.fsm = spec.genFsm()

proc setWidth(spec: Spec, width, maxVariantsWidth: int) =
  ## Sets `width`/`maxVariantsWidth` on `spec` and cascades them into every
  ## nested subcommand's spec too, so values given to the top-level
  ## `newSpec`/`parse*` call apply uniformly throughout the whole command
  ## tree without needing to be repeated at each `command()` call.
  spec.width = width
  spec.maxVariantsWidth = maxVariantsWidth
  for cmd in spec.commands.values:
    cmd.spec.setWidth(width, maxVariantsWidth)

proc newSpec*(spec: tuple, usage = "", prolog = "", epilog = "", width = DefaultWidth,
    maxVariantsWidth = DefaultMaxVariantsWidth): Spec =
  ## Creates a new spec from a spec tuple and builds its FSM. See
  ## `autoFillUsage` for how gaps in `usage` are auto-filled. `width` is the
  ## column width usage/help text is wrapped at; `maxVariantsWidth` is the
  ## max width of the help text's variants column before it wraps onto
  ## additional indented lines (`0` means unlimited). Both cascade to every
  ## nested subcommand's spec (see `setWidth`).
  ##
  ## Unlike `parseOrQuit*`, this does not catch any exceptions raised during
  ## spec construction (`SpecDefect`) or -- if you go on to call
  ## `result.parse(args, command)` yourself -- during parsing
  ## (`ParseError`/`ValidationError`/`HelpError`/`MessageError`). Use this
  ## when you need to handle those errors yourself instead of letting
  ## `parseOrQuit*` print a message and `quit()` (or just call `parse*`
  ## directly on the spec tuple, which does the same `newSpec` + parse in one
  ## step while still raising on failure).
  result = Spec(usage: usage, prolog: prolog, epilog: epilog)
  result.addArgs(spec)
  result.fsm = result.genFsm()
  result.autoFillUsage()
  result.setWidth(width, maxVariantsWidth)

# ------------------------------------------------------------------------------
# Arg constructors
# ------------------------------------------------------------------------------

proc arg*[T: not seq](variants: string, default: T = "", help = "", group = "Arguments", validator: Validator[T] = nil): ValueArg[T, false] =
  ## Creates a positional argument with a value of type `T`.
  ## - `variants` is a comma-separated list of names by which the argument is
  ##   presented to the user. These must take the form `<arg>`.
  ## - `default` is the default value of the argument if not given by the user.
  ## - `help` is a short description of the argument used in help messages.
  ## - `group` determines how arguments are grouped in help messages.
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
  ValueArg[T, false](kind: Positional, variants: variants.split(Comma), default: @[default], help: help, group: group, validator: validator)

proc args*[T: not seq](variants: string, default: seq[T] = newSeq[T](), help = "", group = "Arguments", validator: Validator[T] = nil): ValueArg[T, true] =
  ## Creates a positional argument which takes multiple values of type `T`.
  ## - `variants` is a comma-separated list of names by which the argument is
  ##   presented to the user. These must take the form `<arg>`.
  ## - `default` is the default value(s) of the argument if not given by the
  ##   user; defaults to empty, so `args[string]("<src>", ...)` alone is
  ##   enough -- unlike a bare `@[]`, which has no element type for Nim to
  ##   infer `T` from, `newSeq[T]()` here is tied to `T` directly.
  ## - `help` is a short description of the argument used in help messages.
  ## - `group` determines how arguments are grouped in help messages.
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
  ValueArg[T, true](kind: Positional, variants: variants.split(Comma), default: default, help: help, group: group, validator: validator)



proc opt*[T: not seq](variants: string, default: T = "", help = "", group = "Options", validator: Validator[T] = nil, env = ""): ValueArg[T, false] =
  ## Creates an optional argument with a value of type `T`.
  ## - `variants` is a comma-separated list of names by which the option is
  ##   presented to the user. These must take the form `-o` or `--option` and
  ##   may optionally include a help var (e.g., `--option=<value>`).
  ## - `default` is the default value of the option if not given by the user.
  ## - `help` is a short description of the option used in help messages.
  ## - `group` determines how options are grouped in help messages.
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
  ## - `env` optionally names an environment variable that supplies this
  ##   option's value when it isn't given on the command line (an explicit
  ##   command-line value always wins), going through the same
  ##   conversion/validation as a command-line value would. **Only takes
  ##   effect if this option is already optional in the usage grammar** --
  ##   e.g. `[--port=<port>]`, not a bare `--port=<port>`. A required
  ##   option's absence from the command line still fails parsing
  ##   regardless of `env`, exactly like a coded `default` is never reached
  ##   for a required option either.
  ValueArg[T, false](kind: Optional, variants: variants.split(Comma), default: @[default], help: help, group: group, validator: validator, env: env)

proc opts*[T: not seq](variants: string, default: seq[T] = newSeq[T](), help = "", group = "Options", validator: Validator[T] = nil): ValueArg[T, true] =
  ## Creates an optional argument which takes multiple values of type `T`.
  ## - `variants` is a comma-separated list of names by which the option is
  ##   presented to the user. These must take the form `-o` or `--option` and
  ##   may optionally include a help var (e.g., `--option=<value>`).
  ## - `default` is the default value(s) of the option if not given by the
  ##   user; defaults to empty, so `opts[string]("--src", ...)` alone is
  ##   enough -- unlike a bare `@[]`, which has no element type for Nim to
  ##   infer `T` from, `newSeq[T]()` here is tied to `T` directly.
  ## - `help` is a short description of the option used in help messages.
  ## - `group` determines how options are grouped in help messages.
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
  ValueArg[T, true](kind: Optional, variants: variants.split(Comma), default: default, help: help, group: group, validator: validator)

macro getFlagOps(typeName: string): untyped =
  if $typeName notin flagOps:
    raise newException(Defect, fmt"{typeName} is not a supported type for flags")
  result = flagOps[$typeName]

proc flag*[T](variants: string, default: T = false, help = "", group = "Options",
    variantHelp: Table[string, string] = initTable[string, string](), env = ""): FlagArg[T] =
  ## Constructs a new flag, an optional argument that does not take a value and
  ## instead changes value based on the seen variant.
  ## - `variants` is a comma-separated list where each item takes the form
  ##   `<flag>[<op><value>]`, where:
  ##   - `<flag>` is in the format `-f` or `--flag`. This will be what the user
  ##     passes in.
  ##   - `<op>` is `=` or `:`, optionally preceded by a non-word character.  If
  ##     `<op><value>` is not present, the default behavior is to flip the
  ##     default value in bool flags and to increment any existing value by 1
  ##     for int flags. Out of the box ops supported:
  ##     - `=`: for all flags, sets the value to `<value>`
  ##     - `+=`: for int flags only, increments any existing value by `<value>`.
  ##     - `-=`: for int flags only, decrements any existing value by `<value>`.
  ##   - `<value>` is the value the flag represents
  ## - `default` is the default value of the flag if not given by the user.
  ## - `group` determines how flags are grouped in help messages.
  ## - `variantHelp` optionally overrides the auto-generated per-variant
  ##   description shown in help text (e.g. "Increase by 5") for specific
  ##   variants, keyed by the bare flag name as written in `variants` (e.g.
  ##   `"--quiet"`, not `"--quiet=0"`). Variants not present here fall back
  ##   to the auto-generated description. Every key must match a declared
  ##   variant, or spec construction raises `SpecDefect`.
  ## - `env` optionally names an environment variable that supplies this
  ##   flag's value when it isn't given on the command line (an explicit
  ##   command-line flag always wins). Since a flag has no runtime-supplied
  ##   value on the command line to fall back to (its `<op><value>` is baked
  ##   into `variants` above, not typed by the user), the env var's value is
  ##   instead converted to `T` and applied via the `=` op specifically --
  ##   raises `SpecDefect` here if `T`'s flag handler doesn't support `=`.
  ##   **Only takes effect if this flag is already optional in the usage
  ##   grammar** -- a required flag's absence from the command line still
  ##   fails parsing regardless of `env`, exactly like a coded `default` is
  ##   never reached for a required flag either.
  if env.len > 0 and "=" notin getFlagOps($T):
    raise newException(SpecDefect, fmt"env requires {$typeOf(T)} flags to support the = operation, but they don't")
  result = FlagArg[T](kind: Flag, variants: @[], value: default, help: help, group: group, ops: newOrderedTable[string, FlagOp[T]](), env: env)
  for rawName in variants.split(Comma):
    var matches: array[3, string]
    if rawName.match(FlagVariantFormat, matches):
      try:
        var arg: T = default
        if matches[2].len > 0:
          # The built-in types are converted here explicitly (rather than
          # relying on the implicit `arg = matches[2]` conversion below) so
          # that `flag[T]` compiles for callers outside this module: this
          # generic proc is instantiated at its call site, and an implicit
          # `converter string -> T` is only found there if it's visible in
          # the *caller's* scope, not just here. Our own built-in
          # converters are private (unlike a public `converter`, calling
          # them by name can't silently hijack unrelated overload
          # resolution -- e.g. a plain `"x" in someString` -- in a
          # consumer module that doesn't import `std/strutils` itself), so
          # we call them explicitly instead of exporting them. Any other
          # `T` falls through to the implicit conversion, which still
          # works for a user's own type as long as *they* define
          # `converter toMyType(value: string): MyType` somewhere visible
          # at their own `flag[MyType](...)` call site -- exactly the
          # extension mechanism `defineArg` documents for `arg`/`opt`.
          when T is string: arg = matches[2]
          elif T is int: arg = toInt(matches[2])
          elif T is float64: arg = toFloat(matches[2])
          elif T is bool: arg = toBool(matches[2])
          elif T is char: arg = toChar(matches[2])
          else: arg = matches[2]
        let op = matches[1]
        if op notin getFlagOps($T):
          let escapedOp = strutils.escape(op)
          raise newException(Defect, fmt"{escapedOp} is not a supported operation for {$typeOf(T)} flags")

        let desc = variantHelp.getOrDefault(matches[0], "")
        if result.ops.hasKeyOrPut(matches[0], (op: matches[1], arg: arg, desc: desc)):
          raise newException(SpecDefect, fmt"duplicate variant for {matches[0]}")
        result.variants.add matches[0]
      except ValueError as e:
        raise newException(SpecDefect, fmt"unexpected flag value for {matches[0]}: {e.msg}")
    else:
      let escapedRawName = strutils.escape(rawName)
      let helpText = strutils.dedent("""

        Flag arg variants must be in the format '<flag>[<op><value>]', where:
          - '<flag>' is in the format '-f' or '--flag'
          - '<op>' is ':' or '=', optionally preceded by a non-word character
          - '<value>' is the value the flag represents
        Examples: '--foo=true' or '--bar+=1'""")
      raise newException(SpecDefect, fmt"Cannot parse flag definition {escapedRawName}:" & helpText)
  for key in variantHelp.keys:
    if key notin result.ops:
      let escapedKey = strutils.escape(key)
      raise newException(SpecDefect, fmt"variantHelp key {escapedKey} does not match any declared variant of this flag")

proc command*[S](variants: string, spec: S, help = "", prolog = "", epilog = "", usage = "", group = "Commands", handler: proc(spec: S) = nil): CommandArg =
  ## `width`/`maxVariantsWidth` are deliberately not parameters here: they
  ## cascade down from whatever the top-level `newSpec`/`parse*` call is
  ## given (see `setWidth`), so they only need to be specified once
  ## regardless of how deeply nested this command is.
  result = CommandArg(kind: Command, variants: variants.split(Comma), help: help, group: group)
  result.spec = newSpec(spec, usage, prolog, epilog)
  if not handler.isNil:
    result.handler = () => handler(spec)

proc command*[S, O](variants: string, spec: S, options: O, help = "", prolog = "", epilog = "", usage = "", group = "Commands", handler: proc(spec: S, opts: O) = nil): CommandArg =
  command(variants, spec, help, prolog, epilog, usage, group, handler = (cmdSpec: S) => handler(spec, options))

proc help*(variants = "-h, --help", help = "Display this help message", group = "Options"): HelpArg =
  HelpArg(kind: Flag, variants: variants.split(Comma), help: help, group: group)

proc message*(text: string, variants: string, help = "", group = "Options"): MessageArg =
  ## Creates a flag which, when matched, displays `text` and exits
  ## successfully instead of parsing further arguments.
  ## - `text` is the message to display when the flag is matched.
  ## - `variants` is a comma-separated list of names by which the flag is
  ##   presented to the user. These must take the form `-o` or `--option`.
  ## - `help` is a short description of the flag used in help messages.
  ## - `group` determines how the flag is grouped in help messages.
  MessageArg(kind: Flag, variants: variants.split(Comma), message: text, help: help, group: group)

proc version*(version: string, variants = "-v, --version", help = "Display version information", group = "Options"): MessageArg =
  ## Creates a flag which, when matched, displays `version` and exits
  ## successfully instead of parsing further arguments.
  message(version, variants, help, group)

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

# static:
#   for typeName, ops in flagOps:
#     echo typeName, " -> ", ops.treeRepr
# import ./argumint/dot


proc parseOrQuit*(spec: Spec, args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename())) =
  ## Like `parse*(Spec)`, but prints a message and `quit()`s instead of
  ## raising on failure -- intended for a bare CLI `main()`, not for
  ## embedding in a larger program.
  try:
    spec.parse(args, command)
  except ParseError as e:
    quit("Parsing error: {e.msg}".fmt)
  except ValidationError as e:
    quit("Validation error: {e.msg}".fmt)
  except HelpError as e:
    quit(e.msg, QuitSuccess)
  except MessageError as e:
    quit(e.msg, QuitSuccess)

proc parseOrQuit*(spec: tuple, usage = "", prolog = "", epilog = "", width = DefaultWidth,
    maxVariantsWidth = DefaultMaxVariantsWidth, args: seq[string] = commandLineParams(),
    command = extractFilename(getAppFilename())) =
  ## Like `parse*(tuple)`, but prints a message and `quit()`s instead of
  ## raising on failure -- intended for a bare CLI `main()`, not for
  ## embedding in a larger program.
  try:
    newSpec(spec, usage, prolog, epilog, width, maxVariantsWidth).parseOrQuit(args, command)
  except SpecDefect as e:
    quit(fmt"Error constructing spec: {e.msg}")

proc parse*(spec: tuple, usage = "", prolog = "", epilog = "", width = DefaultWidth,
    maxVariantsWidth = DefaultMaxVariantsWidth, args: seq[string] = commandLineParams(),
    command = extractFilename(getAppFilename())) =
  ## Builds `spec` into a `Spec` via `newSpec` and parses `args` against it in
  ## one step. Raises `SpecDefect` (malformed spec), or
  ## `ParseError`/`ValidationError`/`HelpError`/`MessageError` (parse
  ## failure) -- use `parseOrQuit*` if you want those to print a message and
  ## `quit()` instead.
  newSpec(spec, usage, prolog, epilog, width, maxVariantsWidth).parse(args, command)

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

when isMainModule:
  # let
  #   spec = (
  #     src: args("<src>", default = @["foo"], help = "The source file(s) to copy"),
  #     dest: arg("<dest>", help = "The destination to copy to"),
  #     recursive: flag("-r, --recursive", help = "Whether to recurse into subdirectories"),
  #     help: help()
  #   )
  #
  # spec.parseOrQuit(usage = "[-r] <src>... <dest>\n--help")
  # for file in spec.src:
  #   echo fmt"Copying {file} to {spec.dest} (recursive: {spec.recursive})"

  proc cmdMove(spec: tuple) =
    echo fmt"Moving ship {spec.name} to ({spec.x}, {spec.y}) at {spec.speed} knots"

  let
    coords = (
      x: arg("<x>", default = 0, help = "x grid reference"),
      y: arg("<y>", default = 0, help = "y grid reference"),
    )

    move = (
      name: arg("<name>", help = "The name of the ship to move"),
      x: coords.x,
      y: coords.y,
      speed: opt("--speed=<speed>", default = 10, validator = range(1..100), help = "Speed in knots"),
      help: help()
    )

    ship = (
      move: command("move", move, handler = cmdMove, usage = "<name> <x> <y> [--speed=<speed>]", help = "Move a ship to a point"),
      help: help()
    )

    mine = (
      action: arg("<action>", help = "Action to perform", validator = choice(["set", "remove"])),
      x: coords.x,
      y: coords.y,
      moored: flag("--moored", help = "Moored (anchored) mine"),
      drifting: flag("--drifting", help = "Drifting mine"),
      help: help()
    )

    spec = (
      ship: command("ship", ship, help = "Ship commands"),
      mine: command("mine", mine, usage = "<action> <x> <y> [--moored | --drifting]", help = "Mine commands"),
      help: help(),
      version: version("Naval Fate 1.0.0")
    )

  # echo ""
  # echo "Listing usage..."
  # echo spec.ship.spec.usage
  #
  # echo "Listing commands..."
  # for cmd in spec.ship.spec.commands.values:
  #   echo cmd.name

  spec.parseOrQuit(prolog = "Naval Fate")

  echo fmt"{move.name=}"
  echo fmt"{move.x=}"
  echo fmt"{move.y=}"
  echo fmt"{move.speed=}"
