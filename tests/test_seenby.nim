# Tests for per-Arg provenance -- `Arg.seenBy` and `seen` (Seen Arg in
# CONTEXT.md). See `docs/adr/0039-per-arg-provenance.md`.

import std/[options, os, strutils, unittest]

import argumint

type
  MemSource = ref object of ConfigSource
    data: seq[(ConfigKey, seq[string])]

method lookup(self: MemSource, key: ConfigKey): Option[seq[string]] =
  for (k, v) in self.data:
    if k == key:
      return some(v)
  none(seq[string])

proc withConfig(pairs: openArray[(string, seq[string])]): SpecSettings =
  var data: seq[(ConfigKey, seq[string])]
  for (k, v) in pairs:
    data.add (configKey(k), v)
  result = newSpecSettings(configSources = @[ConfigSource MemSource(data: data)])

suite "SeenBy is precedence-ordered":
  test "members are declared weakest-to-strongest":
    # Ordinal comparison is part of the public contract -- ADR 0039.
    check byNone < byConfig
    check byConfig < byEnv
    check byEnv < byCli
    check ord(byNone) == 0

suite "an option's four provenance cases":
  test "supplied on the command line reports byCli":
    let spec = (port: opt("--port=<n>", default = 80, help = ""))
    spec.parse(usage = "[--port=<n>]", args = @["--port", "99"], command = "app")
    check spec.port.seenBy == byCli
    check spec.port.seen
    check spec.port == 99

  test "supplied by an environment variable reports byEnv":
    let spec = (port: opt("--port=<n>", default = 80, env = "ARGUMINT_SEENBY_PORT",
                          help = ""))
    putEnv("ARGUMINT_SEENBY_PORT", "99")
    defer: delEnv("ARGUMINT_SEENBY_PORT")
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app")
    check spec.port.seenBy == byEnv
    check spec.port == 99

  test "supplied by a Config Source reports byConfig":
    let spec = (port: opt("--port=<n>", default = 80, configKey = configKey("port"), help = ""))
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app",
               settings = withConfig({"port": @["99"]}))
    check spec.port.seenBy == byConfig
    check spec.port == 99

  test "unsupplied reports byNone and still reads its coded default":
    let spec = (port: opt("--port=<n>", default = 80, help = ""))
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app")
    check spec.port.seenBy == byNone
    check not spec.port.seen
    check spec.port == 80

  test "a command-line value identical to the coded default still reports byCli":
    # The discriminating case this feature exists for: the value alone can't
    # tell you the user typed it.
    let spec = (port: opt("--port=<n>", default = 80, help = ""))
    spec.parse(usage = "[--port=<n>]", args = @["--port", "80"], command = "app")
    check spec.port == 80
    check spec.port.seenBy == byCli

  test "the command line wins over an available env var":
    let spec = (port: opt("--port=<n>", default = 80, env = "ARGUMINT_SEENBY_BOTH",
                          help = ""))
    putEnv("ARGUMINT_SEENBY_BOTH", "1234")
    defer: delEnv("ARGUMINT_SEENBY_BOTH")
    spec.parse(usage = "[--port=<n>]", args = @["--port", "99"], command = "app")
    check spec.port.seenBy == byCli
    check spec.port == 99

  test "an env var wins over an available Config Source value":
    let spec = (port: opt("--port=<n>", default = 80, env = "ARGUMINT_SEENBY_TIER",
                          configKey = configKey("port"), help = ""))
    putEnv("ARGUMINT_SEENBY_TIER", "99")
    defer: delEnv("ARGUMINT_SEENBY_TIER")
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app",
               settings = withConfig({"port": @["1234"]}))
    check spec.port.seenBy == byEnv
    check spec.port == 99

suite "the same four cases hold for every other value-carrying kind":
  test "a positional arg":
    let spec = (name: arg("<name>", help = ""))
    spec.parse(usage = "[<name>]", args = @["ship"], command = "app")
    check spec.name.seenBy == byCli

    let unset = (name: arg("<name>", help = ""))
    unset.parse(usage = "[<name>]", args = @[], command = "app")
    check unset.name.seenBy == byNone

  test "a multi-value positional (args)":
    let spec = (files: args("<file>", help = ""))
    spec.parse(usage = "[<file>...]", args = @["a", "b"], command = "app")
    check spec.files.seenBy == byCli
    check spec.files == @["a", "b"]

  test "a multi-value option (opts) across all three supplied tiers":
    let cli = (tags: opts("--tag=<t>", help = ""))
    cli.parse(usage = "[--tag=<t>]...", args = @["--tag", "a"], command = "app")
    check cli.tags.seenBy == byCli

    let fromEnv = (tags: opts("--tag=<t>", env = "ARGUMINT_SEENBY_TAGS", help = ""))
    putEnv("ARGUMINT_SEENBY_TAGS", "a:b")
    defer: delEnv("ARGUMINT_SEENBY_TAGS")
    fromEnv.parse(usage = "[--tag=<t>]...", args = @[], command = "app")
    check fromEnv.tags.seenBy == byEnv
    check fromEnv.tags == @["a", "b"]

    let fromConfig = (tags: opts("--tag=<t>", configKey = configKey("tags"), help = ""))
    fromConfig.parse(usage = "[--tag=<t>]...", args = @[], command = "app",
                     settings = withConfig({"tags": @["a", "b"]}))
    check fromConfig.tags.seenBy == byConfig

    let unset = (tags: opts("--tag=<t>", help = ""))
    unset.parse(usage = "[--tag=<t>]...", args = @[], command = "app")
    check unset.tags.seenBy == byNone

  test "a flag across all three supplied tiers":
    let cli = (verbose: flag("-v, --verbose", help = ""))
    cli.parse(usage = "[-v]", args = @["-v"], command = "app")
    check cli.verbose.seenBy == byCli
    check cli.verbose == true

    let fromEnv = (verbose: flag("-v, --verbose", env = "ARGUMINT_SEENBY_V", help = ""))
    putEnv("ARGUMINT_SEENBY_V", "-v")
    defer: delEnv("ARGUMINT_SEENBY_V")
    fromEnv.parse(usage = "[-v]", args = @[], command = "app")
    check fromEnv.verbose.seenBy == byEnv

    let fromConfig = (verbose: flag("-v, --verbose", configKey = configKey("verbose"), help = ""))
    fromConfig.parse(usage = "[-v]", args = @[], command = "app",
                     settings = withConfig({"verbose": @["-v"]}))
    check fromConfig.verbose.seenBy == byConfig

    let unset = (verbose: flag("-v, --verbose", help = ""))
    unset.parse(usage = "[-v]", args = @[], command = "app")
    check unset.verbose.seenBy == byNone
    check not unset.verbose.seen

suite "kinds that carry no value of their own":
  test "a matched command reports byCli, an unmatched sibling byNone":
    let go = (n: opt("--num=<n>", default = 0, help = ""))
    let stop = (n: opt("--num=<n>", default = 0, help = ""))
    let spec = (go: command("go", go, usage = "[--num=<n>]", help = ""),
                stop: command("stop", stop, usage = "[--num=<n>]", help = ""))
    spec.parse(usage = "(go|stop)", args = @["go"], command = "app")
    check spec.go.seenBy == byCli
    check spec.go.seen
    check spec.stop.seenBy == byNone
    check not spec.stop.seen

  test "a matched -h sets its HelpArg to byCli":
    let spec = (h: help())
    var seenInHelp = byNone
    try:
      spec.parse(usage = "[-h]", args = @["-h"], command = "app")
    except HelpError:
      seenInHelp = spec.h.seenBy
    check seenInHelp == byCli

suite "seenBy is fully resolved before any hook fires":
  test "a top-level before hook sees a not-yet-dispatched subcommand's arg":
    var observed: SeenBy
    var observedCmd: SeenBy
    let sub = (msg: arg("<message>", help = ""))
    proc topBefore(spec: tuple, info: HookInfo) =
      observed = sub.msg.seenBy
      observedCmd = spec.go.seenBy

    let spec = (go: command("go", sub, usage = "<message>", help = ""),)
    spec.parse(usage = "go", args = @["go", "hello-world"], command = "app",
               before = topBefore)
    check observed == byCli
    check observedCmd == byCli

  test "an Arg that is seen in a hook already reads its supplied value there":
    # Provenance and values are both resolved for the whole tree before
    # dispatch starts, so `seen` and "the value is readable" agree even for a
    # subcommand this hook's level hasn't descended into yet. Issue #22's
    # follow-up predates ADR 0032 and describes a window that no longer
    # exists; this pins the closure. See ADR 0039.
    var seenInHook: bool
    var valueInHook: string
    let sub = (msg: arg("<message>", help = ""))
    proc topBefore(spec: tuple, info: HookInfo) =
      seenInHook = sub.msg.seen
      valueInHook = sub.msg

    let spec = (go: command("go", sub, usage = "<message>", help = ""),)
    spec.parse(usage = "go", args = @["go", "hello-world"], command = "app",
               before = topBefore)
    check seenInHook
    check valueInHook == "hello-world"

suite "seenBy agrees with HookInfo.matched":
  test "arg in info.matched is equivalent to arg.seenBy == byCli":
    var agreed: bool
    var matchedCount: int
    proc action(spec: tuple, info: HookInfo) =
      matchedCount = info.matched.len
      agreed = true
      for a in [Arg(spec.name), Arg(spec.port), Arg(spec.verbose)]:
        if (a in info.matched) != (a.seenBy == byCli):
          agreed = false

    let spec = (name: arg("<name>", help = ""),
                port: opt("--port=<n>", default = 80, help = ""),
                verbose: flag("-v", help = ""))
    spec.parse(usage = "<name> [--port=<n>] [-v]", args = @["ship", "-v"],
               command = "app", action = action)
    check agreed
    check matchedCount == 2

suite "a bad command-line value now surfaces before a bad env value":
  test "the higher-precedence tier reports first":
    # Behavior change from gating the fallback sweep on seenBy: the CLI tier
    # is converted before the env tier is applied. See ADR 0039.
    let spec = (port: opt("--port=<n>", default = 0, help = ""),
                host: opt("--host=<h>", default = 0, env = "ARGUMINT_SEENBY_HOST",
                          help = ""))
    putEnv("ARGUMINT_SEENBY_HOST", "not-an-int")
    defer: delEnv("ARGUMINT_SEENBY_HOST")
    try:
      spec.parse(usage = "[--port=<n>] [--host=<h>]", args = @["--port", "also-bad"],
                 command = "app")
      check false
    except ParseError as e:
      check "also-bad" in e.msg
      check "not-an-int" notin e.msg
