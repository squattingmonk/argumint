import std/[hashes, os, pegs, sets, strformat, strutils, sugar, tables]

type
  ValidationError* = object of CatchableError
  SpecificationError* = object of Defect

  ArgKind* = enum
    akInvalid
    akPositional
    akOptional
    akCommand

  Arg* = ref object of RootObj
    ## Base class for args
    kind: ArgKind
    variants*: seq[string]
    count*: int
    help*: string
    group*: string
    env*: string
    setByEnv*: bool
    setByUser*: bool

  ValueArg* = ref object of Arg
    ## Base class for args that take a value
    helpVar: string ## A placeholder for the arg's value in help messages

  FlagArg* = ref object of Arg
    ## Base class for flags, options that do not take a value
    down: HashSet[string] ## Variants that count down or make the value false

  BoolFlagArg* = ref object of FlagArg
    ## A flag arg that can be true or false.
    value: bool ## `down` variants make this false, others make it true

  IntFlagArg* = ref object of FlagArg
    ## A flag arg that counts up or down
    value: int ## `down` variants decrement, others increment

  CommandArg* = ref object of Arg
    spec: Specification
    handler: proc()

  Specification = ref object
    prolog: string ## Intro to a help message
    epilog: string ## Outro to a help message
    usage: string ## Usage string
    options: seq[Arg] ## List of options
    arguments: seq[Arg] ## List of arguments
    commands: seq[CommandArg] ## List of subcommands
    variants: OrderedTableRef[string, Arg] ## Mapping of variants to args
    groups: OrderedTableRef[string, seq[Arg]] ## Mapping of group names to args

  ValidatorKind = enum
    vkChoice
    vkRange
    vkProc

  Validator*[T] = ref object
    ##
    case kind: ValidatorKind
    of vkChoice:
      choices: seq[T]
    of vkRange:
      range: Slice[T]
    of vkProc:
      check: (T -> bool)


let
  Comma = peg """
    # Allows splitting on comma while trimming whitespace
    comma <- \s*','\s*
  """

  OptionVariantFormat = peg"""
    # Allows you to capture the o / option in -o / --option
    option <- ^ (shortOption / longOption) $
    prefix <- '\-'
    shortOption <- prefix {\w}
    longOption <- prefix prefix {\w (\w / (prefix \w))+}
  """

  OptionVariantHelpVarFormat = peg"""
    # Allows you to capture the -o / --option & helpVar in -o=<helpVar> / --option=<helpVar>
    option <- ^ {(shortOption / longOption)} equals {helpVar} $
    prefix <- '\-'
    shortOption <- prefix \w
    longOption <- prefix prefix \w (\w / (prefix \w))+
    equals <- '=' / ':'
    helpVar <- '<' \w (\w / (prefix \w))* '>'
  """

  OptionVariantNoFormat = peg"""
    # Captures --[no]option and --[no-]option
    option <- ^ longOption $
    prefix <- '\-'
    no <- '\[' {'no' '-'?} '\]'
    longOption <- prefix prefix no {\w (\w / (prefix \w))+}
  """

  OptionVariantAltFormat = peg"""
    # Captures --yes / --no and -y / -n
    options <- ^ (longOptions / shortOptions) $
    shortOptions <- shortOption \s* '/' \s* shortOption
    shortOption <- {prefix \w}
    longOptions <- longOption \s* '/' \s* longOption
    longOption <- {prefix prefix \w (\w / (prefix \w))+}
    prefix <- '\-'
  """

  ArgumentVariantFormat = peg"""
    # Captures <arg>
    argument <- ^ '<' word '>' $
    word <- \w (\w / ('-' \w))*
  """

proc name*(arg: Arg, name = ""): string =
  assert arg.variants.len > 0
  result = if name.len > 0: name else: arg.variants[0]

proc hash*(arg: Arg): Hash =
  hash(arg.name)

proc kind*(arg: Arg): ArgKind {.inline.} =
  ## Returns whether `arg` is an optional, positional, or command arg.
  arg.kind

proc choice*[T](choices: openarray[T]): Validator[T] =
  ## Returns a new `Validator` that checks if a value is in `choices`.
  Validator[T](kind: vkChoice, choices: @choices)

proc range*[T](range: Slice[T]): Validator[T] =
  ## Returns a new `Validator` that checks if a value is in `range`.
  Validator[T](kind: vkRange, range: range)

proc check*[T](check: (T -> bool)): Validator[T] =
  ## Returns a new value that checks if the proc `check` returns `true`.
  Validator[T](kind: vkProc, check: check)

proc raiseValidationError(variant: string, msg: string) =
  raise newException(ValidationError, fmt"Unexpected value for {variant}: {msg}")

proc validate[T](validator: Validator[T], value: T, variant: string) =
  ## Raises a ValidationError if `value` is not a valid value for `validator`.
  ## `variant` is used for pretty error messages.
  case validator.kind
  of vkChoice:
    if value notin validator.choices:
      raiseValidationError(variant, fmt"got {escape($value)} but expected one of {$validator.choices}")
  of vkRange:
    if value notin validator.range:
      raiseValidationError(variant, fmt"got {escape($value)} but expected one of [{$validator.range.a}..{$validator.range.b}]")
  of vkProc:
    if not validator.check(value):
      raiseValidationError(variant, fmt"got {escape($value)}")

template defineArg*[T](typeName: untyped, constructor: untyped, valType: typedesc[T], valName: string, default: T, parser: proc (value: string): T = nil): untyped {.dirty.} =
  ## Allows you to define your own `ValueArg` type by providing a `proc` that
  ## can parse a string into a `T`.
  ##
  ## - `T`: The type of the parsed value
  ## - `typeName`: The name of your `ValueArg` type
  ## - `constructor`: The name of the constructor for your new type
  ## - `valType`: The type of the value (i.e. same as `T`)
  ## - `valName`: What to call this type in help messages i.e. ``Expected a <name> but got ...``
  ## - `default`: The default value to use if none is provided (`default(T)` is often a good bet,
  ##   but is not defined for all types.)
  ## - `parser`: A proc that parses a value into a `T`, raising `ValueError` or `ParserError`
  ##   on failure
  ##
  ## Notes:
  ## - If `parser` fails by raising a `ValueError` an error message will be written for you. To
  ##   provide a custom error message, raise a `ParseError`
  type
    typeName* = ref object of ValueArg
      values*: seq[valType]
      defaultValue*: valType
      validator: Validator[valType]

  proc value*(arg: typeName): valType {.inline.} =
    ## Returns the most recently added value for `arg`; if no value was added,
    ## returns the arg's default value.
    if arg.values.len > 0:
      arg.values[^1]
    else:
      arg.defaultValue

  proc parse*(arg: typeName, value: string, variant = ""): valType =
    ## Parses `value` into the type expected by `arg` and validates it. Raises a
    ## `ValueError` if `value` cannot be parsed. Raises a `ValidationError` if
    ## validation failed. `variant` is the seen variant of `arg` and is used for
    ## pretty error messages.
    when parser.isNil:
      assert valType is string
      result = value
      arg.validator.validate(value, variant)
    else:
      try:
        when valType is bool:
          if value == "":
            result = not arg.defaultValue
          else:
            result = parser(value)
        else:
          result = parser(value)
        arg.validator.validate(result, variant)
      except ValueError:
        raise newException(ValueError, "Expected $# for $# but got: '$#'" % [valName, arg.name(variant), value])

  proc constructor*(variants: seq[string], help: string = "", defaultValue = default, env = "", group = "", validator: Validator[valType] = nil): typeName =
    ## Creates a new Arg.
    ##
    ## - `variants` determines how the argument is displayed to the user and
    ##   whether the arg is a positional argument or an option
    ##   - positional arguments take the form `<variant>`
    ##   - options take the form `-o` or `--option`
    ## - `help` is a message to show what the arg does
    ## - `defaultValue` is a defaultValue
    ## - `validator` is used to check if a supplied value is valid for the arg.
    result = new typeName
    result.variants = variants
    result.help = help
    result.group = group
    result.env = env
    result.defaultValue = defaultValue
    result.validator = validator
    if env.len > 0 and existsEnv(env):
      result.values = @[result.parse(getEnv(env), env)]
      result.setByEnv = true
    else:
      result.values = @[]
      result.setByEnv = false

  proc constructor*(variants: string, help: string = "", defaultValue = default, env = "", group = "", validator: Validator[valType] = nil): typeName =
    ## Convenience proc where `variants` is a comma-separated string.
    constructor(variants.split(Comma), help, defaultValue, env, group, validator)

defineArg(StringArg, newStringArg, string, "string", "")
defineArg(IntArg, newIntArg, int, "integer", 0, parseInt)
defineArg(FloatArg, newFloatArg, float, "float", 0.0, parseFloat)
defineArg(BoolArg, newBoolArg, bool, "boolean", false, parseBool)

proc initFlagArg*[A, T](arg: var A, variants: seq[string], help: string, defaultValue: T, env: string, group: string) =
  ## Initializes FlagArg using the given values.
  arg.variants = variants
  arg.help = help
  arg.group = group
  arg.env = env
  arg.value = defaultValue

proc newBoolFlagArg*(variants: seq[string], help = "", defaultValue = false, env = "", group = ""): BoolFlagArg =
  result = new BoolFlagArg
  result.initFlagArg(variants, help, defaultValue, env, group)

proc newBoolFlagArg*(variants: string, help = "", defaultValue = false, env = "", group = ""): BoolFlagArg =
  newBoolFlagArg(variants.split(Comma), help, defaultValue, env, group)

iterator getArgs(spec: tuple): tuple[variable: string, arg: Arg] =
  for variable, arg in spec.fieldPairs:
    when arg is tuple:
      for (v, a) in arg.getArgs:
        yield (v, a)
    elif arg is Arg:
      yield (variable, arg)
    else:
      {.fatal: "All members of a spec must be args or specs".}

proc addToGroup(spec: Specification, arg: Arg, defaultGroup: string) =
  let group = if arg.group.len > 0: arg.group else: defaultGroup
  if spec.groups.hasKeyOrPut(group, @[arg]):
    spec.groups[group].add(arg)

proc raiseSpecificationError(variable: string, message: string) =
  raise newException(SpecificationError, fmt"Error generating {variable}: {message}")

proc addVariant(spec: Specification, arg: Arg, variant: string, variable: string) =
  if spec.variants.hasKeyOrPut(variant, arg) and spec.variants[variant] != arg:
    raiseSpecificationError(variable, fmt"{variant} is already defined")

proc newSpecification(args: tuple, prolog = "", epilog = "", usage = ""): Specification =
  result = new Specification
  result.prolog = prolog
  result.epilog = epilog
  result.usage = usage
  result.variants = newOrderedTable[string, Arg]()
  result.groups = newOrderedTable[string, seq[Arg]]()
  result.groups["Commands"] = @[]
  result.groups["Arguments"] = @[]
  result.groups["Options"] = @[]

  for (variable, arg) in args.getArgs:
    echo variable, " -> ", arg.name
    if arg.variants.len < 1:
      raiseSpecificationError(variable, "all args must have at least one variant")

    let first = arg.variants[0]
    if first.startsWith('-'):
      arg.kind = akOptional
      result.options.add(arg)
      result.addToGroup(arg, "Options")
      var
        helpVar = ""
        matches: array[2, string]
      for variant in arg.variants:
        if variant.match(OptionVariantFormat, matches):
          result.addVariant(arg, variant, variable)
          if matches[0].len > helpVar.len:
            helpVar = matches[0]
        elif variant.match(OptionVariantHelpVarFormat, matches):
          if not (arg of ValueArg):
            raiseSpecificationError(variable, fmt"option format {variant} is only supported for ValueArgs")
          result.addVariant(arg, matches[0], variant)
          ValueArg(arg).helpVar = matches[1]
        elif variant.match(OptionVariantNoFormat, matches):
          if not (arg of FlagArg):
            raiseSpecificationError(variable, fmt"option format {variant} is only supported for FlagArgs")
          let (up, down) = (fmt"--{matches[1]}", fmt"--{matches[0]}{matches[1]}")
          result.addVariant(arg, up, variable)
          result.addVariant(arg, down, variable)
          FlagArg(arg).down.incl(down)
        elif variant.match(OptionVariantAltFormat, matches):
          if not (arg of FlagArg):
            raiseSpecificationError(variable, fmt"option format {variant} is only supported for FlagArgs")
          let (up, down) = (matches[0], matches[1])
          result.addVariant(arg, up, variable)
          result.addVariant(arg, down, variable)
          FlagArg(arg).down.incl(down)
        else:
          raiseSpecificationError(variable,
            fmt"got {variant}, but options must be in the format -o, --option, --[no-]option, --[no]option, -y/-n, or --yes/--no")
      if arg of ValueArg and ValueArg(arg).helpVar.len == 0:
          ValueArg(arg).helpVar = fmt"<{helpVar}>"
    elif first =~ ArgumentVariantFormat:
      if not (arg of ValueArg):
        raiseSpecificationError(variable, fmt"argument format {first} is only supported for ValueArgs")
      arg.kind = akPositional
      result.arguments.add(arg)
      result.addToGroup(arg, "Arguments")
      ValueArg(arg).helpVar = first
      for variant in arg.variants:
        if variant =~ ArgumentVariantFormat:
          result.addVariant(arg, variant, variable)
        else:
          raiseSpecificationError(variable, fmt"got {variant}, but arguments must be in the form <argument>")
    elif arg of CommandArg:
      arg.kind = akCommand
      result.commands.add(CommandArg(arg))
      result.addToGroup(arg, "Commands")
      for variant in arg.variants:
        result.addVariant(arg, variant, variable)
    else:
      raiseSpecificationError(variable, fmt"could not determine arg type from {first}")







when isMainModule:
  let
    args = (
      foo: newStringArg("<foo-bar>", help = "A foo that bars", defaultValue = "foo", validator = choice(["foo", "bar", "baz"])),
      bar: newIntArg(@["--bar=<n>"], help = "A number of bars to hum", validator = range(0..5)),
      baz: newFloatArg(@["<foo>"], help = "The time to hum for", validator = check((n: float) => n > 0)),
      qux: newBoolFlagArg(@["--[no-]foo-bar"], help = "A flag", env = "FOOBAR"),
      quux: (
        foobar: newBoolFlagArg("--yes/--no, -y / -n", help = "Another flag arg"),
      )
    )

  # echo args.qux is Arg
  # echo args.qux is ValueArg
  # echo args.qux is BoolArg
  echo args.qux is FlagArg

  echo args.foo.parse("foo")
  echo args.bar.parse("5")
  echo args.baz.parse("1")
  # echo args.qux.parse("")
  # echo args.qux.value

  let spec = newSpecification(args)
  for variant in spec.variants.keys:
    echo variant

  for (variable, arg) in args.getArgs:
    if arg of ValueArg:
      echo arg.name, " -> ", arg.ValueArg.helpVar
