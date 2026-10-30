# Locks down what `import argumint` alone does and doesn't put in scope --
# see docs/adr/0030-core-types-exported-spec-opaque.md.
#
# This file must import *only* `argumint`. Adding `import argumint/core/backend`
# (or any other submodule) would make every negative assertion below pass
# vacuously, which is exactly the workaround the ADR exists to remove.
#
# It asserts what is public, not what isn't: no test checks that a name is
# withheld. The negatives below pin private fields and designed constraints.
# A `not compiles(...)` also passes for a field that no longer exists at all,
# so each private field is mirrored by a positive in a suite that imports the
# internals: `test_argumint.nim`'s "Private fields ... unreachable"
# suite or `tests/test_help.nim`. Neither half means much alone; add to both
# together.

import std/[os, sequtils, unittest]
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

suite "Types nameable after a bare `import argumint`":
  test "the core vocabulary types are exported":
    check nameable(Spec)
    check nameable(SpecSettings)
    check nameable(Arg)
    check nameable(ArgKind)
    check nameable(CommandArg)
    check nameable(MessageArg)
    check nameable(HelpArg)
    check nameable(EnvSource)
    check nameable(HookInfo)
    check nameable(Shell)
    check nameable(ConfigKey)
    check nameable(ConfigSource)
    check nameable(PathCompletion)
    check nameable(Validator[int])
    check nameable(FlagClamp[int])
    check nameable(AnnotationText)
    # The return types of all five spec constructors -- see issue #27.
    check nameable(ValueArg[string])
    check nameable(ValuesArg[string])
    check nameable(FlagArg[bool])
    # `FlagArg`'s ops are private, so naming `FlagArg[T]` never requires
    # naming their element type; `FlagOp` is the public half.
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
    # Mirrored by `tests/test_argumint.nim`'s "Private fields ..."
    # suite.

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
    # A private field, mirrored by `tests/test_argumint.nim`.
    check not compiles(newSpecSettings().theme)
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
    check not compiles(verbose.aliases)
    check not compiles(verbose.clamp)

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
