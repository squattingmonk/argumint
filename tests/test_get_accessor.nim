# Tests for `get`/`get(otherwise)` -- the explicit accessors that read a
# parsed value where the `toT`/`toSeqT` converters can't fire. See
# `docs/adr/0040-explicit-value-accessor.md`.

import std/[json, options, os, strutils, unittest]

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

suite "get reads the same value the implicit conversion does":
  test "a scalar option returns the supplied value":
    let spec = (port: opt("--port=<n>", default = 80, help = ""))
    spec.parse(usage = "[--port=<n>]", args = @["--port", "99"], command = "app")
    check spec.port.get == 99
    check spec.port.get == spec.port.int

  test "a scalar option returns its coded default when unsupplied":
    let spec = (port: opt("--port=<n>", default = 80, help = ""))
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app")
    check spec.port.get == 80

  test "a positional arg returns the supplied value or its coded default":
    let spec = (name: arg("<name>", default = "nobody", help = ""))
    spec.parse(usage = "[<name>]", args = @["Bob"], command = "app")
    check spec.name.get == "Bob"

    let unset = (name: arg("<name>", default = "nobody", help = ""))
    unset.parse(usage = "[<name>]", args = @[], command = "app")
    check unset.name.get == "nobody"

  test "a multi-value option returns the accumulated seq":
    let spec = (tags: opts("--tag=<t>", help = ""))
    spec.parse(usage = "[--tag=<t>]...", args = @["--tag", "a", "--tag", "b"],
               command = "app")
    check spec.tags.get == @["a", "b"]

  test "the no-arg form is the otherwise form, called with the coded default":
    # The no-arg `get` delegates to the template rather than repeating its
    # supplied-or-not test, so the two can't drift; ADR 0040.
    let spec = (port: opt("--port=<n>", default = 80, help = ""))
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app")
    check spec.port.get == spec.port.get(otherwise = 80)

    let supplied = (port: opt("--port=<n>", default = 80, help = ""))
    supplied.parse(usage = "[--port=<n>]", args = @["--port", "99"], command = "app")
    check supplied.port.get == supplied.port.get(otherwise = 80)

  test "a multi-value option returns its coded default seq when unsupplied":
    let spec = (tags: opts("--tag=<t>", default = @["x", "y"], help = ""))
    spec.parse(usage = "[--tag=<t>]...", args = @[], command = "app")
    check spec.tags.get == @["x", "y"]

  test "a multi-value positional returns the accumulated seq":
    let spec = (files: args("<file>", help = ""))
    spec.parse(usage = "[<file>...]", args = @["a", "b"], command = "app")
    check spec.files.get == @["a", "b"]

  test "a flag returns its value":
    let spec = (verbose: flag("-v, --verbose", help = ""))
    spec.parse(usage = "[-v]", args = @["-v"], command = "app")
    check spec.verbose.get == true

    let unset = (verbose: flag("-v, --verbose", help = ""))
    unset.parse(usage = "[-v]", args = @[], command = "app")
    check unset.verbose.get == false

  test "a counting flag returns its composed value":
    let spec = (level: flag[int](ops = "-v+=1", default = 0, help = ""))
    spec.parse(usage = "[-v]...", args = @["-v", "-v", "-v"], command = "app")
    check spec.level.get == 3

  test "a multi-op flag's composed value reads the same through get and the converter":
    let spec = (level: flag[int](ops = "-v+=1, -q-=1, --reset=0", default = 5,
                                 help = ""))
    spec.parse(usage = "[-v | -q | --reset]...", args = @["-v", "-v", "-q"],
               command = "app")
    check spec.level.get == 6
    check spec.level.get == spec.level.int

  test "converter and get agree for every arg kind":
    let spec = (
      name: arg("<name>", default = "nobody", help = ""),
      files: args("<file>", help = ""),
      port: opt("--port=<n>", default = 80, help = ""),
      tags: opts("--tag=<t>", default = @["x"], help = ""),
      verbose: flag("-v", help = ""))
    spec.parse(usage = "[<name>] [<file>...] [--port=<n>] [--tag=<t>]... [-v]",
               args = @["Bob", "a", "b", "--tag", "z"], command = "app")
    check spec.name.get == spec.name.string
    check spec.files.get == seq[string](spec.files)
    check spec.port.get == spec.port.int
    check spec.tags.get == seq[string](spec.tags)
    check spec.verbose.get == spec.verbose.bool

suite "get(otherwise) replaces the coded default at the call site":
  test "returns the supplied value, ignoring otherwise":
    let spec = (port: opt("--port=<n>", default = 80, help = ""))
    spec.parse(usage = "[--port=<n>]", args = @["--port", "99"], command = "app")
    check spec.port.get(8080) == 99

  test "returns otherwise when unsupplied, ignoring the coded default":
    let spec = (port: opt("--port=<n>", default = 80, help = ""))
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app")
    check spec.port.get(8080) == 8080
    check spec.port.get == 80 # the coded default is untouched

  test "a multi-value option falls back to otherwise":
    let spec = (tags: opts("--tag=<t>", default = @["x"], help = ""))
    spec.parse(usage = "[--tag=<t>]...", args = @[], command = "app")
    check spec.tags.get(@["z"]) == @["z"]

    let supplied = (tags: opts("--tag=<t>", default = @["x"], help = ""))
    supplied.parse(usage = "[--tag=<t>]...", args = @["--tag", "a"], command = "app")
    check supplied.tags.get(@["z"]) == @["a"]

  test "a positional arg falls back to otherwise":
    let spec = (name: arg("<name>", default = "nobody", help = ""))
    spec.parse(usage = "[<name>]", args = @[], command = "app")
    check spec.name.get("anon") == "anon"

  test "a flag falls back to otherwise only when no tier supplied it":
    let unset = (verbose: flag("-v", default = true, help = ""))
    unset.parse(usage = "[-v]", args = @[], command = "app")
    check unset.verbose.get(false) == false

    let supplied = (verbose: flag("-v", default = true, help = ""))
    supplied.parse(usage = "[-v]", args = @["-v"], command = "app")
    check supplied.verbose.get(true) == false # -v toggled it off; still supplied

  test "a value supplied by an environment variable counts as supplied":
    let spec = (port: opt("--port=<n>", default = 80, env = "ARGUMINT_GET_PORT",
                          help = ""))
    putEnv("ARGUMINT_GET_PORT", "99")
    defer: delEnv("ARGUMINT_GET_PORT")
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app")
    check spec.port.get(8080) == 99

  test "a flag supplied by an environment variable counts as supplied":
    let spec = (verbose: flag("-v", default = true, env = "ARGUMINT_GET_VERBOSE",
                              help = ""))
    putEnv("ARGUMINT_GET_VERBOSE", "-v")
    defer: delEnv("ARGUMINT_GET_VERBOSE")
    spec.parse(usage = "[-v]", args = @[], command = "app")
    check spec.verbose.get(true) == false

  test "a flag supplied by a Config Source counts as supplied":
    let spec = (verbose: flag("-v", default = true, configKey = configKey("verbose"),
                              help = ""))
    spec.parse(usage = "[-v]", args = @[], command = "app",
               settings = withConfig({"verbose": @["-v"]}))
    check spec.verbose.get(true) == false

  test "a value supplied by a Config Source counts as supplied":
    let spec = (port: opt("--port=<n>", default = 80, configKey = configKey("port"),
                          help = ""))
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app",
               settings = withConfig({"port": @["99"]}))
    check spec.port.get(8080) == 99

  test "a CLI value equal to the coded default still counts as supplied":
    let spec = (port: opt("--port=<n>", default = 80, help = ""))
    spec.parse(usage = "[--port=<n>]", args = @["--port", "80"], command = "app")
    check spec.port.get(8080) == 80

suite "seen is the supplied-or-not predicate for FlagArg; ValueArg reads test the stored value instead":
  test "a ValueArg that is seen always has a stored value to index":
    # `get(otherwise)` indexes `value[0]` whenever a value is stored -- for
    # every write reached through `parse`/`spec.parse`, `seen` and "holds a
    # value" agree, so this remains true for the ordinary parsed path. #29
    # makes the accessor test the stored value directly (not `seen`), which
    # is what lets a tier-less `put` be read back too -- see
    # "a ValueArg holding a value is readable even when unseen" below and
    # `tests/test_put.nim`. ADR 0032 parses every tier for the whole tree
    # before dispatch; ADR 0039 writes provenance over the same tree.
    let cli = (port: opt("--port=<n>", default = 80, help = ""))
    cli.parse(usage = "[--port=<n>]", args = @["--port", "99"], command = "app")
    check cli.port.seen
    check cli.port.get(0) == cli.port.get

    let fromEnv = (port: opt("--port=<n>", default = 80, env = "ARGUMINT_GET_SEEN",
                             help = ""))
    putEnv("ARGUMINT_GET_SEEN", "99")
    defer: delEnv("ARGUMINT_GET_SEEN")
    fromEnv.parse(usage = "[--port=<n>]", args = @[], command = "app")
    check fromEnv.port.seen
    check fromEnv.port.get(0) == fromEnv.port.get

    let fromConfig = (port: opt("--port=<n>", default = 80,
                                configKey = configKey("port"), help = ""))
    fromConfig.parse(usage = "[--port=<n>]", args = @[], command = "app",
                     settings = withConfig({"port": @["99"]}))
    check fromConfig.port.seen
    check fromConfig.port.get(0) == fromConfig.port.get

  test "an unseen ValueArg falls back, and a seen one never does":
    let unset = (tags: opts("--tag=<t>", default = @["x"], help = ""))
    unset.parse(usage = "[--tag=<t>]...", args = @[], command = "app")
    check not unset.tags.seen
    check unset.tags.get(@["z"]) == @["z"]

  test "a ValueArg holding a value is readable even when unseen":
    # A tier-less `put`/`parse` stores a value but leaves `seenBy` at
    # `byNone` -- `get`/`get(otherwise)` must not be fooled by that into
    # falling back. See `tests/test_put.nim` for the exhaustive coverage;
    # this pins the one-line consequence at this accessor's own seam.
    let port = opt("--port=<n>", default = 80, help = "")
    port.put(77)
    check not port.seen
    check port.get == 77
    check port.get(otherwise = 1) == 77

  test "a parent hook reads a child's value through get(otherwise)":
    # The window ADR 0032 closed: a parent `before` fires only after every
    # level's values are converted, so `seen` and the stored value agree
    # there and `get(otherwise)` returns the supplied value, not `otherwise`.
    var observed = ""
    let sub = (msg: arg("<msg>", default = "none", help = ""))
    proc topBefore(spec: tuple, info: HookInfo) =
      observed = sub.msg.get("fallback")

    let spec = (go: command("go", sub, usage = "<msg>", help = ""),)
    spec.parse(usage = "go", args = @["go", "hello"], command = "app",
               before = topBefore)
    check observed == "hello"
    check sub.msg.get("fallback") == "hello"

suite "get(otherwise) evaluation":
  test "otherwise is not evaluated when the arg was supplied":
    var calls = 0
    proc fallback(): int =
      inc calls
      8080

    let spec = (port: opt("--port=<n>", default = 80, help = ""))
    spec.parse(usage = "[--port=<n>]", args = @["--port", "99"], command = "app")
    check spec.port.get(fallback()) == 99
    check calls == 0

    let unset = (port: opt("--port=<n>", default = 80, help = ""))
    unset.parse(usage = "[--port=<n>]", args = @[], command = "app")
    check unset.port.get(fallback()) == 8080
    check calls == 1

  test "the arg operand is evaluated exactly once on both paths":
    var reads = 0
    let supplied = (port: opt("--port=<n>", default = 80, help = ""))
    supplied.parse(usage = "[--port=<n>]", args = @["--port", "99"], command = "app")
    let unsupplied = (port: opt("--port=<n>", default = 80, help = ""))
    unsupplied.parse(usage = "[--port=<n>]", args = @[], command = "app")

    proc read(a: ValueArg[int, false]): ValueArg[int, false] =
      inc reads
      a

    check read(supplied.port).get(8080) == 99
    check reads == 1
    check read(unsupplied.port).get(8080) == 8080
    check reads == 2

  test "a flag's arg operand is evaluated exactly once":
    var reads = 0
    let spec = (verbose: flag("-v", help = ""))
    spec.parse(usage = "[-v]", args = @["-v"], command = "app")

    proc read(a: FlagArg[bool]): FlagArg[bool] =
      inc reads
      a

    check read(spec.verbose).get(false) == true
    check reads == 1

suite "get compiles where the implicit conversion does not fire":
  setup:
    let spec = (
      name: opt("--name=<n>", default = "Bob", help = ""),
      count: opt("--count=<n>", default = 1, help = ""),
      tags: opts("--tag=<t>", default = @["a", "b"], help = ""),
      verbose: flag("-v", help = ""))
    spec.parse(usage = "[--name=<n>] [--count=<n>] [--tag=<t>]... [-v]",
               args = @[], command = "app")

  test "join on a multi-value arg":
    check spec.tags.get.join(",") == "a,b"

  test "in / contains on a multi-value arg":
    check "a" in spec.tags.get
    check "z" notin spec.tags.get

  test "some() infers the value type":
    let opt = some(spec.name.get)
    check opt == some("Bob")
    let o2: Option[string] = some(spec.name.get)
    check o2.get == "Bob"

  test "a case selector":
    var branch = ""
    case spec.name.get
    of "Bob": branch = "bob"
    else: branch = "other"
    check branch == "bob"

  test "JSON construction":
    let j = %*{"name": spec.name.get, "count": spec.count.get,
               "tags": spec.tags.get, "verbose": spec.verbose.get}
    check j["name"].getStr == "Bob"
    check j["count"].getInt == 1
    check j["tags"].len == 2
    check j["verbose"].getBool == false

  test "an element of a typed seq literal":
    let xs: seq[string] = @[spec.name.get]
    check xs == @["Bob"]

  test "var inference":
    var s = spec.name.get
    s.add "!"
    check s == "Bob!"

    var xs = spec.tags.get
    xs.add "c"
    check xs == @["a", "b", "c"]
