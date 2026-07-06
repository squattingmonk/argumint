import std/[macros, macrocache, os, options, pegs, sequtils, sets, sugar, strformat, strutils, tables]

import ./argumint/[backend, dot, fsm, parser, validators]

type
  ValueArg[T: not seq, multi: static bool] = ref object of Arg
    value: Option[seq[T]]
    default: seq[T]
    validator: Validator[T]

  FlagOp[T] = tuple[op: string, arg: T]

  FlagArg[T] = ref object of Arg
    value: T
    ops: OrderedTableRef[string, FlagOp[T]]

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

proc genHelp(spec: Spec, command: string): string =
  let prolog = if spec.prolog.len > 0: spec.prolog & "\n\n" else: ""
  let epilog = if spec.epilog.len > 0: spec.epilog else: ""
  let usage = spec.usage.formatUsage(command) & "\n"

  var lines: seq[string]
  for group, args in spec.groups.pairs:
    var argLines: seq[string]
    for arg in args:
      argLines.add("  " & arg.variants.join(", ") & "  " & arg.help)
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

template defineArg*[T](typeName: typedesc[T], flagHandler: untyped): untyped =
  ## Defines parse methods for arguments with a value of type `T`.
  ## `flagHandler` is a code block that is executed to handle an operation on a
  ## `FlagArg[T]` value. Without this block, a `T` cannot be used for a flag.
  ## Within the scope of the handler, the following variables are defined:
  ## - `value: var T`: the flag's value, which can be modified by the handler
  ## - `op: string`: the operation to be performed on `value` (e.g., `+=`)
  ## - `arg: T`: an argument to the operation
  defineFlagOps typeName:
    flagHandler

  proc handleFlag(value {.inject.}: var T, op {.inject.}: string, arg {.inject.}: T) =
    flagHandler

  method parse*(self: FlagArg[T], _: string, variant = "") =
    let name = self.name(variant)
    if not self.ops.hasKey(name):
      raise newException(SpecDefect, "$# is not a known variant for the flag $#" % [name, self.name])
    let (op {.inject.}, arg {.inject.}) = self.ops[name]
    self.value.handleFlag(op, arg)

  defineArg typeName

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
  let usageLenBefore = spec.usage.len
  let reachable = spec.fsm.referencedArgs()
  let optionsUnreachable = spec.options.values.toSeq.deduplicate
    .anyIt(not (it of MessageArg) and it notin reachable)
  let prefix = if optionsUnreachable: "[options] " else: ""
  var prefixUsed = false

  for arg in spec.args.filterIt(it.kind == Command and it notin reachable):
    let variants = if arg.variants.len > 1: "(" & arg.variants.join(" | ") & ")" else: arg.variants[0]
    spec.usage.addSep("\n")
    spec.usage.add prefix & variants
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

proc newSpec(spec: tuple, usage = "", prolog = "", epilog = ""): Spec =
  ## Creates a new spec from a spec tuple and builds its FSM. See
  ## `autoFillUsage` for how gaps in `usage` are auto-filled.
  result = Spec(usage: usage, prolog: prolog, epilog: epilog)
  result.addArgs(spec)
  result.fsm = result.genFsm()
  result.autoFillUsage()

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

proc arg*[T: not seq](variants: string, default: seq[T], help = "", group = "Arguments", validator: Validator[T] = nil): ValueArg[T, true] =
  ## Creates a positional argument which takes multiple values of type `T`.
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
  ValueArg[T, true](kind: Positional, variants: variants.split(Comma), default: default, help: help, group: group, validator: validator)



proc opt*[T: not seq](variants: string, default: T = "", help = "", group = "Options", validator: Validator[T] = nil): ValueArg[T, false] =
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
  ValueArg[T, false](kind: Optional, variants: variants.split(Comma), default: @[default], help: help, group: group, validator: validator)

proc opt*[T: not seq](variants: string, default: seq[T], help = "", group = "Options", validator: Validator[T] = nil): ValueArg[T, true] =
  ## Creates an optional argument which takes multiple values of type `T`.
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
  ValueArg[T, true](kind: Optional, variants: variants.split(Comma), default: default, help: help, group: group, validator: validator)

macro getFlagOps(typeName: string): untyped =
  if $typeName notin flagOps:
    raise newException(Defect, fmt"{typeName} is not a supported type for flags")
  result = flagOps[$typeName]

proc flag*[T](variants: string, default: T = false, help = "", group = "Options"): FlagArg[T] =
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
  result = FlagArg[T](kind: Flag, variants: @[], value: default, help: help, group: group, ops: newOrderedTable[string, FlagOp[T]]())
  for rawName in variants.split(Comma):
    var matches: array[3, string]
    if rawName.match(FlagVariantFormat, matches):
      try:
        var arg: T = default
        if matches[2].len > 0:
          arg = matches[2]
        let op = matches[1]
        if op notin getFlagOps($T):
          raise newException(Defect, fmt"{op.escape} is not a supported operation for {$typeOf(T)} flags")

        if result.ops.hasKeyOrPut(matches[0], (op: matches[1], arg: arg)):
          raise newException(SpecDefect, fmt"duplicate variant for {matches[0]}")
        result.variants.add matches[0]
      except ValueError as e:
        raise newException(SpecDefect, fmt"unexpected flag value for {matches[0]}: {e.msg}")
    else:
      raise newException(SpecDefect, fmt"Cannot parse flag definition {rawName.escape}:" & """

        Flag arg variants must be in the format '<flag>[<op><value>]', where:
          - '<flag>' is in the format '-f' or '--flag'
          - '<op>' is ':' or '=', optionally preceded by a non-word character
          - '<value>' is the value the flag represents
        Examples: '--foo=true' or '--bar+=1'""".dedent)

proc command*[S](variants: string, spec: S, help = "", prolog = "", epilog = "", usage = "", group = "Commands", handler: proc(spec: S) = nil): CommandArg =
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

defineArg bool:
  ## Handles a flag value for a bool. If `op` is blank, `arg` must be the
  ## default value of the flag, which will be inverted.
  case op
  of "": value = not arg
  of "=": value = arg
  else: raise newException(SpecDefect, fmt"boolean flags only support = operations")

defineArg int:
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


proc parse*(spec: Spec, args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename())) =
  try:
    spec.parseSpec(args, command)
  except ParseError as e:
    quit("Parsing error: {e.msg}".fmt)
  except ValidationError as e:
    quit("Validation error: {e.msg}".fmt)
  except HelpError as e:
    quit(e.msg, QuitSuccess)
  except MessageError as e:
    quit(e.msg, QuitSuccess)

proc parse*(spec: tuple, usage = "", prolog = "", epilog = "", args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename())) =
  try:
    newSpec(spec, usage, prolog, epilog).parse(args, command)
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

when isMainModule:
  # let
  #   spec = (
  #     src: arg("<src>", default = @["foo"], help = "The source file(s) to copy"),
  #     dest: arg("<dest>", help = "The destination to copy to"),
  #     recursive: flag("-r, --recursive", help = "Whether to recurse into subdirectories"),
  #     help: help()
  #   )
  #
  # spec.parse(usage = "[-r] <src>... <dest>\n--help")
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
      help: help()
    )

  # echo ""
  # echo "Listing usage..."
  # echo spec.ship.spec.usage
  #
  # echo "Listing commands..."
  # for cmd in spec.ship.spec.commands.values:
  #   echo cmd.name

  spec.parse(prolog = "Naval Fate")

  echo fmt"{move.name=}"
  echo fmt"{move.x=}"
  echo fmt"{move.y=}"
  echo fmt"{move.speed=}"
