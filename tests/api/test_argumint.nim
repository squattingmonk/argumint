# What `import argumint` alone puts in scope -- see README.md here and
# docs/adr/0030-core-types-exported-spec-opaque.md.
#
# It asserts what is public, not what isn't: no test checks that a name is
# withheld. The negatives below pin private fields and designed constraints.
# A `not compiles(...)` also passes for a field that no longer exists at all,
# so each private field's negative sits beside a `privateAccess` positive in
# the same test. Neither half means much alone.

import std/[importutils, macros, os, sequtils, strutils, unittest]
{.push warning[UnusedImport]: off.}
import std/[dirs, files, options]
  # Only to show `PathCompletion`'s values don't collide with them (#200).
{.pop.}

import argumint

template nameable(T: untyped): bool =
  ## Whether `T` can be written down as a type here.
  compiles(block:
    var x: T
    discard x)

macro privateAccessBase(T: typedesc) =
  ## `privateAccess` for the type `T` inherits from, which `import argumint`
  ## may not let this file name (e.g. `ValueArgBase`).
  var impl = getTypeInst(T)[1].getTypeImpl
  if impl.kind == nnkRefTy:
    impl = impl[0].getTypeImpl
  result = newCall(bindSym"privateAccess",
    nnkBracketExpr.newTree(ident"typedesc", impl[1][0]))

suite "Types nameable after a bare `import argumint`":
  test "the core vocabulary types are exported":
    check nameable(Spec)
    check nameable(SpecSettings)
    check nameable(Arg)
    check nameable(ArgKind)
    # pins: argumint.CommandArg
    check nameable(CommandArg)
    check nameable(MessageArg)
    check nameable(HelpArg)
    check nameable(EnvSource)
    # pins: argumint.HookInfo
    check nameable(HookInfo)
    check nameable(Shell)
    check nameable(ConfigKey)
    check nameable(ConfigSource)
    check nameable(PathCompletion)
    check nameable(Validator[int])
    check nameable(FlagClamp[int])
    check nameable(AnnotationText)
    # The return types of all five spec constructors -- see issue #27.
    # pins: argumint.ValueArg
    check nameable(ValueArg[string])
    # pins: argumint.ValuesArg
    check nameable(ValuesArg[string])
    # pins: argumint.FlagArg
    check nameable(FlagArg[bool])
    # `FlagArg`'s ops are private, so naming `FlagArg[T]` never requires
    # naming their element type; `FlagOp` is the public half.
    # pins: argumint.FlagOp
    check nameable(FlagOp[int])

  test "a `desc` converts from a string or an Option, but nothing else picks up the conversion":
    # `AnnotationText` is distinct so a user's own `Option[string]` parameter
    # doesn't accept a string -- see ADR 0029.
    check Option[string](toAnnotationText("x")) == some("x")
    check Option[string](toAnnotationText(some(""))) == some("")
    check choice([1, 2], desc = some("")).help() == ""
    check range(0..4, desc = "a small number").help() == "a small number"
    proc wantsOpt(o: Option[string]): bool = o.isSome
    check not compiles(wantsOpt("x"))

  test "`Option` itself is exported, not just `some`/`none`":
    # `opt*`/`opts*`/`flag*`'s `env` param is `Option[EnvSource]` and
    # `EnvSource.delim` is `Option[string]`, so a caller writing their own
    # helper needs the type, not only its constructors.
    check nameable(Option[string])
    check nameable(Option[EnvSource])

  test "the defaults `newSpecSettings`'s own signature names are spellable":
    check compiles(DefaultMaxVariantsWidth)
    check compiles(DefaultMaxWidth)
    check compiles(DefaultEnvDelim)
    # Settable with `-d:argumint.width`, so readable too (ADR 0053).
    check compiles(DefaultWidth)

  test "`appName`, the default `command` in `parse*`'s signatures, is spellable":
    check compiles(appName())

  test "`detectWidth`, in `newSpecSettings`'s default `width`, is spellable":
    check compiles(newSpecSettings(width = min(detectWidth(), 120)))

  test "spec construction's public half survives moving out of `argumint.nim`":
    # Issue #49 split `newSpec` into `argumint/grammar/specbuild` and the three
    # constructors that never read a usage string into `argumint/core/backend`.
    # `env`/`toEnvSource` resolved through another path before the move,
    # which made them no less public -- so assert all of them here.
    check compiles(newSpecSettings(width = 100))
    check compiles(env("PORT", ","))
    check compiles(toEnvSource("PORT"))
    check compiles(newSpec((verbose: flag("-v", help = ""),)))

  test "what a Spec is built from is read-only (#269)":
    # Readable for `HookInfo.matched`; written only while an Arg is built.
    let port = opt("--port=<n>", default = 0, help = "")
    let cmd = command("go", ())
    check port.variants == @["--port=<n>"]
    check port.kind == ArgKind.Optional
    check port.seenBy == byNone
    check cmd.spec != nil
    check not compiles(port.variants = @["--other"])
    check not compiles(port.variants.add "--other")
    check not compiles(port.kind = ArgKind.Flag)
    check not compiles(port.seenBy = byCli)
    check not compiles(cmd.spec = cmd.spec)

  test "no string-to-scalar converter comes into scope":
    # `fromString`'s conversions are private to `argumint/values/argtypes`.
    # Exporting them as converters would put `let n: int = "5"` in scope for
    # everyone who imports argumint.
    check not compiles(block:
      let n: int = "5"
      discard n)

suite "`PathCompletion` values beside std modules (#200)":
  test "Files, Dirs and None compile unqualified":
    let spec = (
      a: arg("<a>", complete = Files),
      b: opt("--b=<b>", complete = Dirs),
      c: args("<c>", complete = None),
    )
    check $spec.a.Arg.complete == "Completer(fixed)"
    check $spec.b.Arg.complete == "Completer(fixed)"
    check $spec.c.Arg.complete == "Completer(fixed)"

suite "Completers (#215)":
  test "a proc converts, and its Offer is built with offer":
    let a = arg("<a>", complete = proc (ctx: CompletionContext): Offer =
      offer([("x", "An x")], paths = Files))
    check $a.Arg.complete == "Completer(proc)"
    check $arg("<b>").Arg.complete == "Completer(default)"

  test "an Offer's fields are opaque":
    let o = offer(["x"])
    check not compiles(o.values)
    check not compiles(o.paths)
    block:
      privateAccess(Offer)
      check compiles(o.values)
      check compiles(o.paths)

suite "`Spec` is an opaque handle":
  setup:
    let spec = newSpec((verbose: flag("-v", help = ""), help: help()))

  test "its bookkeeping fields are unreachable from outside the library":
    check not compiles(spec.fsm)
    check not compiles(spec.usage)
    check not compiles(spec.args)
    check not compiles(spec.commands)
    check not compiles(spec.arguments)
    check not compiles(spec.options)
    check not compiles(spec.groups)
    check not compiles(spec.prolog)
    check not compiles(spec.epilog)
    block:
      privateAccess(Spec)
      check compiles(spec.fsm)
      check compiles(spec.usage)
      check compiles(spec.args)
      check compiles(spec.commands)
      check compiles(spec.arguments)
      check compiles(spec.options)
      check compiles(spec.groups)
      check compiles(spec.prolog)
      check compiles(spec.epilog)

  test "a custom Arg can build `StyledText` for `validatorHelp`":
    # See ADR 0051's note (#209).
    check nameable(StyledText)
    check compiles(styled("a") & styled(srLiteral, "b"))

  test "`HelpContext` is nameable, but only `argumint/help` can use one":
    # Like `HelpFormatter`, whose signature names it: a formatter can be
    # declared from here, and written with the submodule (ADR 0057).
    check declared(HelpContext)
    # Its fields are private; `tests/test_help.nim` reads them through
    # `argumint/help`'s accessors.
    check not compiles(proc (ctx: HelpContext): string = ctx.command)
    check not compiles(proc (ctx: HelpContext): int = ctx.width)
    check not compiles(proc (ctx: HelpContext): Spec = ctx.spec)
    block:
      privateAccess(HelpContext)
      check compiles(proc (ctx: HelpContext): string = ctx.command)
      check compiles(proc (ctx: HelpContext): int = ctx.width)
      check compiles(proc (ctx: HelpContext): Spec = ctx.spec)
    check compiles(block:
      let f: HelpFormatter = proc (ctx: HelpContext): string = "help")

  test "styling is configurable from `import argumint` alone":
    # `markup` and the span model stay formatter-author names; see
    # `docs/adr/0051-help-and-error-styling.md`.
    var theme = defaultTheme
    theme[srOption] = TextStyle(fg: fgMagenta, attrs: {styleBright})
    theme[srInvalid] = TextStyle(fg: fgRed)
    let settings = newSpecSettings(style = ansiStyler(theme))
    check not settings.style.isNil
    check compiles(newSpecSettings(style = autoStyler))
    check compiles(newSpecSettings(theme = theme))
    check not compiles(newSpecSettings().theme)
    block:
      privateAccess(SpecSettings)
      check compiles(newSpecSettings().theme)
    # The colour rule is public so a custom `Styler` can follow it (#195).
    check wantsColor() is bool
    check compiles(block:
      let s = newSpecSettings()
      s.width = 0
      s.style = autoStyler
      discard s.width + 1
      discard s.style.isNil)
    check compiles(block:
      let s: Styler = proc (role: StyleRole, text: string): string = text)

  test "`settings` and the hooks stay public":
    # `block:` rather than a bare `spec.before = ...`, which `compiles`
    # would otherwise read as a named argument.
    check compiles(spec.settings.width)
    check compiles(block: spec.before = proc (info: HookInfo) = discard)
    check compiles(block: spec.action = proc (info: HookInfo) = discard)
    check compiles(block: spec.after = proc (info: HookInfo) = discard)

  test "mutating the shared settings still reaches the built spec":
    spec.settings.width = 42
    check spec.settings.width == 42

suite "`ValueArg`/`FlagArg` are opaque handles too":
  setup:
    let
      name = opt("-n, --name=<s>", default = "x", help = "")
      tags = opts("--tag=<t>", help = "")
      verbose = flag("-v", help = "")

  test "their state stays unreachable from outside the library":
    check not compiles(name.value)
    check not compiles(name.default)
    check not compiles(name.validator)
    check not compiles(name.cfgKey)
    check not compiles(tags.value)
    check not compiles(verbose.value)
    check not compiles(verbose.ops)
    check not compiles(verbose.clamp)
    block:
      privateAccess(ValueArg[string])
      privateAccess(ValuesArg[string])
      privateAccess(FlagArg[bool])
      # `cfgKey` and `ops` are declared on the unexported bases.
      privateAccessBase(ValueArg[string])
      privateAccessBase(FlagArg[bool])
      check compiles(name.value)
      check compiles(name.default)
      check compiles(name.validator)
      check compiles(name.cfgKey)
      check compiles(tags.value)
      check compiles(verbose.value)
      check compiles(verbose.ops)
      check compiles(verbose.clamp)

  test "the inherited `Arg` surface still works through them":
    # Exporting the subtypes must not shadow what ADR 0030 already opened
    # up on the base type.
    check name.kind == ArgKind.Optional
    check verbose.kind == ArgKind.Flag
    check name.help == ""

suite "What naming the core types buys a caller":
  test "a Spec can cross a proc boundary":
    # The motivating case: without `Spec` in scope, only `let`-inference
    # works, so a spec has to be built at its point of use.
    proc buildCli(): Spec =
      newSpec((name: arg("<name>", help = ""), help: help()))

    let spec = buildCli()
    spec.parse(args = @["Ada"], command = "prog")
    check spec != nil

  test "a SpecSettings can be held in a typed object field":
    # `newSpecSettings`'s doc comment tells callers to hold onto the
    # returned value and mutate it later -- which needs the type nameable.
    type App = object
      settings: SpecSettings

    var app = App(settings: newSpecSettings(width = 60))
    app.settings.width = 70
    check app.settings.width == 70

  test "a caller can write their own `Option[EnvSource]` helper":
    # `env*`'s two-arg form returns `Option[EnvSource]`, so factoring out a
    # house style ("all my env vars split on a comma") needs both names.
    proc devEnv(name: string): Option[EnvSource] =
      env(name, ",")

    putEnv("ARGUMINT_TEST_PUBLIC_API_TAGS", "a,b")
    defer: delEnv("ARGUMINT_TEST_PUBLIC_API_TAGS")
    let spec = (
      tags: opts("--tag=<t>", env = devEnv("ARGUMINT_TEST_PUBLIC_API_TAGS"), help = ""),
    )
    spec.parse(usage = "[--tag=<t>]...", args = @[], command = "prog")
    check spec.tags == @["a", "b"]

  test "`HookInfo.matched` can be inspected, not just passed to `showsMessage`":
    # `matched` is `seq[Arg]`; before this, `Arg`/`ArgKind`/`MessageArg`
    # were unnameable, so `showsMessage` was the only thing a caller could
    # do with it.
    var sawMessageArg, sawFlag: bool

    proc onAction(spec: tuple, info: HookInfo) =
      sawMessageArg = info.matched.anyIt(it of MessageArg)
      sawFlag = info.matched.anyIt(it.kind == ArgKind.Flag)

    let spec = (verbose: flag("-v", help = ""), help: help())
    spec.parse(args = @["-v"], command = "prog", action = onAction)
    check not sawMessageArg
    check sawFlag

  test "a house-style `opt`/`flag` factory can be written":
    # The `EnvSource` case ADR 0030 accepted, one level up: these are the
    # *return* types of all five constructors -- see issue #27.
    proc appOpt(variants, help: string): ValueArg[string] =
      opt(variants, help = help, group = "App")

    proc appFlag(variants, help: string): FlagArg[bool] =
      flag(variants, help = help, group = "App")

    proc appPort(variants, help: string): ValueArg[int] =
      opt[int](variants, help = help, group = "App")

    proc appPorts(variants, help: string): ValuesArg[int] =
      opts[int](variants, help = help, group = "App")

    let spec = (name: appOpt("--name=<s>", "who"), loud: appFlag("-l", "loud"),
                port: appPort("--port=<n>", "port"), extra: appPorts("--extra=<n>", "extra"))
    spec.parse(usage = "[options]",
               args = @["--name", "Ada", "-l", "--port", "80", "--extra", "81"], command = "prog")
    check spec.name == "Ada"
    check spec.loud
    check spec.port.get == 80
    check spec.extra.get == @[81]

  test "an arg can be forward-declared and assigned later":
    var pending: ValueArg[string]
    check pending.isNil
    pending = opt("--late=<s>", default = "d", help = "")
    check not pending.isNil

  test "args can be collected in a typed seq built conditionally":
    # Inference covers this only when the seq is initialized in one
    # statement, which rules out building it in pieces.
    var common: seq[ValueArg[string]]
    common.add opt("-a=<a>", help = "a")
    if true:
      common.add opt("-b=<b>", help = "b")
    check common.len == 2

  test "a generic helper can take an arg as a parameter":
    proc describe[T](a: ValueArg[T]): string = a.help.short
    check describe(opt("-x=<x>", help = "ex")) == "ex"

# ------------------------------------------------------------------------------
# Pins for the rest of the facade's Public Surface lines (ADR 0090), one call
# per overload.

suite "Spec construction":
  test "each Arg constructor, by overload":
    # pins: argumint.arg,string,string,HelpText,string,Validator[string]
    check arg("<a>") is ValueArg[string]
    # pins: argumint.arg,string,T,HelpText,string,Validator[T: not seq]
    check arg("<n>", default = 1) is ValueArg[int]
    # pins: argumint.args,string,seq[string],HelpText,string,Validator[string]
    check args("<a>") is ValuesArg[string]
    # pins: argumint.args,string,seq[T],HelpText,string,Validator[T: not seq]
    check args("<n>", default = @[1]) is ValuesArg[int]
    # pins: argumint.opt,string,string,HelpText,string,Validator[string],Option[EnvSource],ConfigKey
    check opt("--a=<a>") is ValueArg[string]
    # pins: argumint.opt,string,T,HelpText,string,Validator[T: not seq],Option[EnvSource],ConfigKey
    check opt("--n=<n>", default = 1) is ValueArg[int]
    # pins: argumint.opts,string,seq[string],HelpText,string,Validator[string],Option[EnvSource],ConfigKey
    check opts("--a=<a>") is ValuesArg[string]
    # pins: argumint.opts,string,seq[T],HelpText,string,Validator[T: not seq],Option[EnvSource],ConfigKey
    check opts("--n=<n>", default = @[1]) is ValuesArg[int]
    # pins: argumint.message,string,string,HelpText,string
    check message("--info", "text") is MessageArg
    # pins: argumint.version,string,string,HelpText,string
    check version("--version", "1.0") is MessageArg
    # pins: argumint.help,string,HelpText,string,HelpFormatter
    check help() is HelpArg
    # pins: argumint.completion,string,HelpText,string,string
    check completion() is CommandArg
    # pins: argumint.command,string,S,HelpText,string,string,string,string,proc(S,HookInfo),proc(S,HookInfo),proc(S,HookInfo)
    check command("go", (a: flag("-a"))) is CommandArg
    # pins: argumint.command,string,S,O,HelpText,string,string,string,string,proc(S,O,HookInfo),proc(S,O,HookInfo),proc(S,O,HookInfo)
    check command("go", (a: flag("-a")), (b: flag("-b"))) is CommandArg

  test "each flag constructor, by overload":
    # pins: argumint.flag,string,varargs[FlagOp[bool]],bool,HelpText,string,FlagClamp[bool],Option[EnvSource],ConfigKey
    check flag("-v") is FlagArg[bool]
    # pins: argumint.flag,string,string,bool,HelpText,string,FlagClamp[bool],Option[EnvSource],ConfigKey
    check flag(ops = "--on=true, --off=false") is FlagArg[bool]
    # pins: argumint.flag,string,varargs[FlagOp[T]],T,HelpText,string,FlagClamp[T],Option[EnvSource],ConfigKey
    check flag[int]("-v") is FlagArg[int]
    # pins: argumint.flag,string,string,T,HelpText,string,FlagClamp[T],Option[EnvSource],ConfigKey
    check flag[int](ops = "--quiet=0, --loud+=1") is FlagArg[int]
    # pins: argumint.flag,string,varargs[FlagOp[T]],T,HelpText,string,FlagClamp[T],Option[EnvSource],ConfigKey,Validator[T]
    check flag[int]("-v", validator = range(0..3)) is FlagArg[int]
    # pins: argumint.flag,string,string,T,HelpText,string,FlagClamp[T],Option[EnvSource],ConfigKey,Validator[T]
    check flag[int](ops = "--quiet=0", validator = range(0..3)) is FlagArg[int]
    # pins: argumint.flagOp,string,staticstring,T,string
    check flagOp("--loud", "+=", 5) is FlagOp[int]
    # pins: argumint.flagOp,string,proc(T),string
    check flagOp("--twice", proc (v: var int) = v *= 2) is FlagOp[int]
    # pins: argumint.flagOpIt.t,string,untyped,string
    check flagOpIt[int]("--next", it + 1) is FlagOp[int]
    # pins: argumint.FlagClamp
    # pins: argumint.clamp,Slice[T],AnnotationText
    check clamp(0..3) is FlagClamp[int]
    # pins: argumint.adjust,proc(T),AnnotationText
    check adjust(proc (v: int): int = v div 2) is FlagClamp[int]
    # pins: argumint.noClamp
    check noClamp[int]() is FlagClamp[int]
    # pins: argumint.help,FlagClamp[T]
    check clamp(0..3).help() == "clamp: 0..3"

  test "a spec built by `specTuple`, `newSpec` and the conversions its fields take":
    # pins: argumint.specTuple.m,varargs[untyped]
    let spec = specTuple:
      port: opt("--port=<n>", default = 0, env = "ARGUMINT_TEST_PIN_PORT", configKey = "port")
      name: arg("<name>", help = "who", complete = Files)
    # pins: argumint.toEnvSource.c,string
    # pins: argumint.toConfigKey.c,string
    # pins: argumint.toHelpText.c,string
    # pins: argumint.toCompleter.c,PathCompletion
    check spec.name.Arg.help.short == "who"
    # pins: argumint.newSpec,,string,string,string
    check newSpec(spec, usage = "<name>") is Spec

  test "`eachArg` visits a spec's Args":
    var names: seq[string]
    # pins: argumint.eachArg.t,,untyped,untyped,untyped
    (a: flag("-a"), b: flag("-b")).eachArg(name, arg):
      names.add name
    check names == @["a", "b"]

  test "an Arg's read-only state":
    let port = opt("-p, --port=<n>", default = 0, help = ("port", "the port"))
    let cmd = command("go", ())
    # pins: argumint.Arg
    # pins: argumint.kind,Arg
    # pins: argumint.ArgKind
    # pins: argumint.ArgKind.Optional
    check port.kind == ArgKind.Optional
    # pins: argumint.ArgKind.Command
    check cmd.kind == ArgKind.Command
    # pins: argumint.ArgKind.Positional
    check arg("<a>").kind == ArgKind.Positional
    # pins: argumint.ArgKind.Flag
    check flag("-v").kind == ArgKind.Flag
    # pins: argumint.variants,Arg
    check port.variants == @["-p", "--port=<n>"]
    # pins: argumint.name,Arg,string
    check port.name == "-p"
    check port.name("--port") == "--port"
    # pins: argumint.spec,CommandArg
    check cmd.spec != nil
    # pins: argumint.HelpText
    # pins: argumint.HelpText.short
    # pins: argumint.HelpText.long
    # pins: argumint.Arg.help
    check port.help == (short: "port", long: "the port")
    # pins: argumint.Arg.group
    # pins: argumint.Arg.hidden
    check opt("--g=<g>", group = "G", hidden = true).Arg.group == "G"
    check opt("--g=<g>", hidden = true).Arg.hidden
    # pins: argumint.Arg.complete
    # pins: argumint.$,Completer
    check $port.Arg.complete == "Completer(default)"
    # pins: argumint.MessageArg
    # pins: argumint.MessageArg.message
    check version("--version", "1.0").message == "1.0"
    # pins: argumint.HelpArg
    # pins: argumint.HelpArg.formatter
    # pins: argumint.formatParagraph,HelpContext
    check not help(formatter = formatParagraph).formatter.isNil

suite "Parsing":
  test "each parse entry point":
    let spec = (port: opt("--port=<n>", default = 0), help: help())
    # pins: argumint.parse,S,string,string,string,seq[string],proc(S,HookInfo),proc(S,HookInfo),proc(S,HookInfo)
    spec.parse(args = @["--port", "1"], command = "prog")
    check spec.port == 1
    # pins: argumint.parseOrQuit,S,string,string,string,seq[string],proc(S,HookInfo),proc(S,HookInfo),proc(S,HookInfo)
    spec.parseOrQuit(args = @["--port", "2"], command = "prog")
    check spec.port == 2
    let built = newSpec((port: opt("--port=<n>", default = 0),))
    # pins: argumint.parse,Spec,seq[string]
    built.parse(@["--port", "3"])
    # pins: argumint.parseOrQuit,Spec,seq[string]
    built.parseOrQuit(@["--port", "4"], command = "prog")
    proc build(): auto = (port: opt("--port=<n>", default = 0),)
    # pins: argumint.parsed,proc),string,string,string,seq[string],proc(S,HookInfo),proc(S,HookInfo),proc(S,HookInfo)
    check parsed(build, args = @["--port", "5"], command = "prog").port == 5
    # pins: argumint.parsedOrQuit,proc),string,string,string,seq[string],proc(S,HookInfo),proc(S,HookInfo),proc(S,HookInfo)
    check parsedOrQuit(build, args = @["--port", "6"], command = "prog").port == 6

  test "reading a value, by overload":
    let spec = (port: opt("--port=<n>", default = 0), tags: opts("--tag=<t>"),
                loud: flag[int]("-l"), name: opt("--name=<s>"))
    spec.parse(args = @["--port", "1", "--tag", "a", "-l"], command = "prog")
    # pins: argumint.get,ValueArg[T]
    check spec.port.get == 1
    # pins: argumint.get,ValuesArg[T]
    check spec.tags.get == @["a"]
    # pins: argumint.get,FlagArg[T]
    check spec.loud.get == 1
    # pins: argumint.get.t,ValueArg[T],T
    check spec.name.get("x") == "x"
    # pins: argumint.get.t,ValuesArg[T],seq[T]
    check opts("--t=<t>").get(@["y"]) == @["y"]
    # pins: argumint.get.t,FlagArg[T],T
    check flag[int]("-q").get(7) == 7
    # pins: argumint.toT.c,ValueArg[T]
    let port: int = spec.port
    check port == 1
    # pins: argumint.toSeqT.c,ValuesArg[T]
    let tags: seq[string] = spec.tags
    check tags == @["a"]
    # pins: argumint.toT.c,FlagArg[T]
    let loud: int = spec.loud
    check loud == 1

  test "provenance":
    let spec = (port: opt("--port=<n>", default = 0),)
    spec.parse(args = @["--port", "1"], command = "prog")
    # pins: argumint.seen,Arg
    check spec.port.seen
    # pins: argumint.seenBy,Arg
    # pins: argumint.SeenBy
    # pins: argumint.SeenBy.byCli
    check spec.port.seenBy == byCli
    # pins: argumint.SeenBy.byNone
    # pins: argumint.SeenBy.byEnv
    # pins: argumint.SeenBy.byConfig
    # Weakest to strongest, which ADR 0039 makes part of the contract.
    check byNone < byConfig and byConfig < byEnv and byEnv < byCli

  test "the write side":
    let port = opt("--port=<n>", default = 0)
    let tags = opts("--tag=<t>")
    let loud = flag[int]("-l")
    # pins: argumint.put,,T,Option[SeenBy]
    port.put(8)
    check port == 8
    # pins: argumint.put,FlagArg[T],T,Option[SeenBy]
    loud.put(2, seenBy = some(byEnv))
    check loud.seenBy == byEnv
    # pins: argumint.replace,ValuesArg[T: not seq],seq[T],Option[SeenBy]
    tags.replace(@["a", "b"])
    check tags == @["a", "b"]
    # pins: argumint.parse,Arg,string,string,Option[SeenBy]
    port.parse("9")
    check port == 9
    # pins: argumint.clear.e,Arg
    port.clear()
    check not port.seen

  test "hooks":
    var program, sub: string
    var matched: int
    var showed, hasSpec: bool
    proc onAction(spec: tuple, info: HookInfo) =
      # pins: argumint.HookInfo.root
      # pins: argumint.Level.command
      program = info.root.command
      # pins: argumint.HookInfo.here
      # pins: argumint.Level.spec
      hasSpec = info.here.spec != nil
      # pins: argumint.HookInfo.matched
      matched = info.matched.len
      # pins: argumint.showsMessage,HookInfo
      showed = info.showsMessage
    let spec = (verbose: flag("-v"),)
    spec.parse(args = @["-v"], command = "prog", action = onAction)
    check program == "prog"
    check hasSpec
    check matched == 1
    check not showed
    let built = newSpec((go: command("go", ()),))
    # pins: argumint.Spec.before
    built.before = proc (info: HookInfo) = sub.add "before "
    # pins: argumint.Spec.after
    built.after = proc (info: HookInfo) = sub.add "after"
    built.parse(@["go"])
    check sub == "before after"
    let leaf = newSpec((v: flag("-v"),))
    var acted = false
    # pins: argumint.Spec.action
    leaf.action = proc (info: HookInfo) = acted = true
    leaf.parse(@[])
    check acted

  test "a hook can show its level's help":
    let spec = (verbose: flag("-v"),)
    var caught = false
    try:
      # pins: argumint.showHelp,HookInfo
      spec.parse(args = @[], command = "prog", settings = newSpecSettings(style = nil),
        action = proc (spec: tuple, info: HookInfo) = showHelp(info))
    # pins: argumint.HelpError
    # pins: argumint.MessageError
    # pins: argumint.MessageError.styledMsg
    except HelpError as e:
      caught = e.styledMsg.len > 0
    check caught

  test "each failure type":
    # pins: argumint.ParseError
    # pins: argumint.ParseError.styledMsg
    # pins: argumint.UsageError
    var caught = ""
    try:
      (a: flag("-a"),).parse(args = @["-b"], command = "prog",
        settings = newSpecSettings(style = nil))
    except UsageError as e:
      caught = (ref ParseError)(e).styledMsg
    check caught == "  - unrecognized option: -b\n\nUsage:\n  prog [options]"
    # pins: argumint.ConversionError
    expect ConversionError:
      (n: opt("-n=<n>", default = 0),).parse(args = @["-n", "x"], command = "prog",
        settings = newSpecSettings(style = nil))
    # pins: argumint.ValidationError
    expect ValidationError:
      (n: opt("-n=<n>", default = 0, validator = range(1..2)),).parse(
        args = @["-n", "5"], command = "prog", settings = newSpecSettings(style = nil))
    # pins: argumint.SpecDefect
    expect SpecDefect:
      discard newSpec((a: flag("-a"), b: flag("-a")))
    # pins: argumint.CompletionError
    check CompletionError is MessageError

suite "Validators":
  test "each validator constructor, by overload":
    # pins: argumint.Validator
    # pins: argumint.range,Slice[T],AnnotationText
    # pins: argumint.help,Validator[T]
    check range(1..3).help() == "range: 1..3"
    # pins: argumint.choice,openArray[T],AnnotationText
    check choice(["a", "b"]) is Validator[string]
    # pins: argumint.check,proc(T),AnnotationText
    check check(proc (v: int): bool = v > 0, "positive") is Validator[int]
    # pins: argumint.checkIt.t,untyped,AnnotationText
    check checkIt[int](it > 0, "positive") is Validator[int]
    # pins: argumint.checkSeen,proc(T,openArray[T]),AnnotationText
    check checkSeen(proc (v: int, seen: openArray[int]): bool = v notin seen) is Validator[int]
    # pins: argumint.checkSeenIt.t,untyped,AnnotationText
    check checkSeenIt[int](it notin seen) is Validator[int]
    # pins: argumint.unique,AnnotationText
    check unique[int]() is Validator[int]
    # pins: argumint.noValidator
    check noValidator[int]() is Validator[int]
    # pins: argumint.all,varargs[Validator[T]]
    check all(range(1..9), unique[int]()) is Validator[int]
    # pins: argumint.all,varargs[Validator[T]],AnnotationText
    check all([range(1..9), unique[int]()], "small and new") is Validator[int]
    # pins: argumint.any,varargs[Validator[T]]
    check any(range(1..2), range(8..9)) is Validator[int]
    # pins: argumint.any,varargs[Validator[T]],AnnotationText
    check any([range(1..2), range(8..9)], "low or high") is Validator[int]

  test "a `desc` converts from a string or an Option":
    # pins: argumint.AnnotationText
    # pins: argumint.toAnnotationText.c,string
    # pins: argumint.toAnnotationText.c,Option[string]
    check range(0..4, desc = "small").help() == "small"
    check range(0..4, desc = some("")).help() == ""

# As docs/guide/precedence.md's "Your Own Config Format" writes one; a
# method can't be declared inside a test.
type TableSource = ref object of ConfigSource
  path: string

method lookup(self: TableSource, key: ConfigKey): Option[seq[string]] =
  self.path = key.join(".")
  some(@["9000"])

suite "Environment and config":
  test "an env var source":
    # pins: argumint.env,string,string
    # pins: argumint.EnvSource
    # pins: argumint.EnvSource.name
    # pins: argumint.EnvSource.delim
    let source = env("PORTS", ",").get
    check source.name == "PORTS"
    check source.delim == some(",")
    # pins: argumint.DefaultEnvDelim
    check DefaultEnvDelim is string

  test "a Config Source of your own, written from `import argumint` alone":
    # pins: argumint.ConfigSource
    # pins: argumint.lookup.e,ConfigSource,ConfigKey
    let source = TableSource()
    let spec = (port: opt("--port=<n>", default = 0, configKey = configKey("server", "port")),)
    # pins: argumint.SpecSettings.configSources
    spec.parse(args = @[], command = "prog",
      settings = newSpecSettings(configSources = @[ConfigSource(source)]))
    check spec.port == 9000
    check source.path == "server.port"

  test "a ConfigKey reads like a seq[string]":
    # pins: argumint.ConfigKey
    # pins: argumint.configKey,varargs[string]
    let key = configKey("server", "port")
    # pins: argumint.len,ConfigKey
    check key.len == 2
    # pins: argumint.[],ConfigKey,int
    check key[1] == "port"
    var parts: seq[string]
    # pins: argumint.items.i,ConfigKey
    for part in key: parts.add part
    check parts == @["server", "port"]
    # pins: argumint.join,ConfigKey,string
    check key.join("/") == "server/port"
    # pins: argumint.segments,ConfigKey
    check key.segments == @["server", "port"]
    # pins: argumint.$,ConfigKey
    check $key == "@[\"server\", \"port\"]"
    # pins: argumint.==,ConfigKey,ConfigKey
    check key == configKey("server", "port")
    # pins: argumint.noConfigKey
    check noConfigKey().len == 0

suite "Settings and styling":
  test "SpecSettings":
    # pins: argumint.SpecSettings
    # pins: argumint.newSpecSettings,int,seq[ConfigSource],Styler
    let s = newSpecSettings(width = 60)
    # pins: argumint.width,SpecSettings
    # pins: argumint.width=,SpecSettings,int
    s.width = s.width + 1
    check s.width == 61
    # pins: argumint.style,SpecSettings
    # pins: argumint.style=,SpecSettings,Styler
    s.style = nil
    check s.style.isNil
    # pins: argumint.SpecSettings.maxVariantsWidth
    # pins: argumint.DefaultMaxVariantsWidth
    check s.maxVariantsWidth == DefaultMaxVariantsWidth
    # pins: argumint.SpecSettings.envDelim
    check s.envDelim == DefaultEnvDelim
    # pins: argumint.SpecSettings.strictOptions
    # pins: argumint.DefaultStrictOptions
    check s.strictOptions == DefaultStrictOptions
    # pins: argumint.Spec
    # pins: argumint.Spec.settings
    check newSpec((a: flag("-a"),), settings = s).settings.width == 61
    # pins: argumint.DefaultWidth
    # pins: argumint.DefaultMaxWidth
    check DefaultWidth is int and DefaultMaxWidth is int
    # pins: argumint.detectWidth
    check detectWidth() > 0
    # pins: argumint.appName
    check appName().len > 0

  test "a theme, a Styler and Styled Text":
    # pins: argumint.Theme
    # pins: argumint.defaultTheme
    var theme: Theme = defaultTheme
    # pins: argumint.TextStyle
    # pins: argumint.TextStyle.fg
    # pins: argumint.TextStyle.attrs
    # pins: argumint.ForegroundColor
    # pins: argumint.Style
    # pins: argumint.StyleRole
    # pins: argumint.StyleRole.srOption
    theme[srOption] = TextStyle(fg: fgMagenta, attrs: {styleBright})
    check theme[srOption].fg == fgMagenta
    # pins: argumint.Styler
    # pins: argumint.ansiStyler,Theme
    let styler: Styler = ansiStyler(theme)
    check styler(srOption, "x") == "\e[1m\e[35mx\e[0m"
    # pins: argumint.autoStyler,StyleRole,string
    check newSpecSettings(style = autoStyler) is SpecSettings
    # pins: argumint.wantsColor
    check wantsColor() is bool
    # pins: argumint.StyledText
    # pins: argumint.styled,string
    # pins: argumint.styled,StyleRole,string
    # pins: argumint.&,StyledText,StyledText
    # pins: argumint.StyledText.spans
    # pins: argumint.Span.role
    # pins: argumint.Span.text
    let joined = styled("a") & styled(srLiteral, "b")
    check joined.spans[1].role == srLiteral
    check joined.spans[1].text == "b"

  test "every Style Role":
    # pins: argumint.StyleRole.srAnnotation
    # pins: argumint.StyleRole.srCommand
    # pins: argumint.StyleRole.srEnv
    # pins: argumint.StyleRole.srError
    # pins: argumint.StyleRole.srHeader
    # pins: argumint.StyleRole.srInvalid
    # pins: argumint.StyleRole.srLiteral
    # pins: argumint.StyleRole.srMetavar
    # pins: argumint.StyleRole.srPlain
    # pins: argumint.StyleRole.srPositional
    # pins: argumint.StyleRole.srProgram
    # pins: argumint.StyleRole.srTick
    # pins: argumint.StyleRole.srUrl
    check {srAnnotation, srCommand, srEnv, srError, srHeader, srInvalid,
      srLiteral, srMetavar, srOption, srPlain, srPositional, srProgram, srTick,
      srUrl}.len == 14

  test "a formatter is declared from here":
    # pins: argumint.HelpFormatter
    # pins: argumint.HelpContext
    # pins: argumint.formatColumn,HelpContext
    let f: HelpFormatter = formatColumn
    check not f.isNil

suite "Completion":
  test "completers and offers":
    # pins: argumint.CompletionContext
    # pins: argumint.CompletionContext.word
    # pins: argumint.Offer
    # pins: argumint.offer,openArray[string],openArray[string]
    # pins: argumint.CompleterProc
    let fn: CompleterProc = proc (ctx: CompletionContext): Offer = offer([ctx.word])
    # pins: argumint.Completer
    # pins: argumint.toCompleter.c,P
    let c: Completer = fn
    check $c == "Completer(proc)"
    # pins: argumint.offer,openArray[],openArray[string]
    check offer([("x", "An x")]) is Offer
    # pins: argumint.files,varargs[string]
    check $files("*.toml") == "Completer(fixed)"
    # pins: argumint.PathCompletion
    # pins: argumint.PathCompletion.Files
    # pins: argumint.PathCompletion.Dirs
    # pins: argumint.PathCompletion.None
    check PathCompletion.Files != PathCompletion.Dirs and Dirs != PathCompletion.None

  test "a completion script":
    # pins: argumint.completionScript,Spec,Shell
    # pins: argumint.Shell
    # pins: argumint.Shell.bash
    # pins: argumint.Shell.fish
    # pins: argumint.Shell.zsh
    let spec = newSpec((a: flag("-a"),))
    # A line that registers the script for `prog`; the rest of each script
    # is tested in tests/test_completion_scripts.nim.
    for (shell, registers) in [(Shell.bash, "complete -F _prog_complete prog"),
        (Shell.fish, "complete -c prog -f -a '(__prog_complete)'"),
        (Shell.zsh, "compdef _prog_complete prog")]:
      check registers in spec.completionScript(shell, "prog").splitLines
    # pins: argumint.isCompletionRequest,seq[string]
    check not isCompletionRequest(@["-a"])

  test "a usage string as a dot graph":
    # pins: argumint.dot,,string,string,string
    check (a: flag("-a"),).dot(usage = "[-a]") == """digraph G {
    rankdir=LR

    S1 [peripheries=2] [label="S1"]
    S1 -> S2 [label="Opt(-a)"]

    S2 [peripheries=2] [label="S2"]
}"""
    # pins: argumint.dot,Spec
    check newSpec((a: flag("-a"),)).dot() == """digraph G {
    rankdir=LR

    S1 [peripheries=2] [label="S1"]
    S1 -> S2 [label="Opts(-a)"]
    S1 -> S2 [label="Opts(-a)"]

    S2 [peripheries=2] [label="S2"]
    S2 -> S2 [label="Opts(-a)"]
}"""

suite "Re-exported from std":
  test "Option and its constructors":
    # pins: argumint.Option
    # pins: argumint.some
    # pins: argumint.none
    # pins: argumint.isSome
    # pins: argumint.isNone
    # pins: argumint.get
    let o: Option[int] = some(1)
    check o.isSome and none(int).isNone and o.get == 1
