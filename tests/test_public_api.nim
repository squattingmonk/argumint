# Locks down what `import argumint` alone does and doesn't put in scope --
# see docs/adr/0030-core-types-exported-spec-opaque.md.
#
# This file must import *only* `argumint`. Adding `import argumint/backend`
# (or any other submodule) would make every negative assertion below pass
# vacuously, which is exactly the workaround the ADR exists to remove.
#
# A `not compiles(...)` also passes for a name that no longer exists at all,
# so every negative below is mirrored by a positive in `test_argumint.nim`'s
# "Library-internal names ... unreachable" suite, which does import the
# internals. Neither half means much alone; add to both together.

import std/[os, sequtils, unittest]

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
    check nameable(CompletionCandidate)
    check nameable(Validator[int])
    check nameable(FlagClamp[int])

  test "`Option` itself is exported, not just `some`/`none`":
    # `opt*`/`opts*`/`flag*`'s `env` param is `Option[EnvSource]` and
    # `EnvSource.delim` is `Option[string]`, so a caller writing their own
    # helper needs the type, not only its constructors.
    check nameable(Option[string])
    check nameable(Option[EnvSource])

  test "the defaults `newSpecSettings`'s own signature names are spellable":
    check compiles(DefaultMaxVariantsWidth)
    check compiles(DefaultEnvDelim)
    # `DefaultWidth` appears in no exported signature, so it stays internal
    # until something needs it -- see ADR 0030.
    check not compiles(DefaultWidth)

  test "the FSM plumbing types stay unexported":
    # Implementation, not API: their operations live in `argumint/fsmgraph`,
    # which isn't re-exported either.
    check not nameable(State)
    check not nameable(Transition)
    check not nameable(Matcher)
    check not nameable(MatcherKind)

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
