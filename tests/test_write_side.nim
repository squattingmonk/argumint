# Tests for the programmatic write side of an Arg -- the exported
# `parse`/`clear` methods (#47) and the three-way arbitration each Value
# Precedence tier performs against an Arg's incoming provenance.
#
# Imports `argumint` alone on purpose: reaching the write side must not
# require a backend import -- see
# `docs/adr/0030-core-types-exported-spec-opaque.md`.

import std/[options, os, strutils, unittest]

import argumint

type
  MemSource = ref object of ConfigSource
    data: seq[(ConfigKey, seq[string])]

  EmptySource = ref object of ConfigSource
    ## Has the key, but offers no values for it.

  CustomArg = ref object of Arg
    ## A hand-rolled Arg per ADR 0030's custom-Arg contract.
    vals: seq[string]

  VariantProbe = ref object of MessageArg
    ## Records which of its own Variants `action` was dispatched with.
    seenVariant: string

method lookup(self: MemSource, key: ConfigKey): Option[seq[string]] =
  for (k, v) in self.data:
    if k == key:
      return some(v)
  none(seq[string])

method parse(self: CustomArg, value: string, variant = "",
             seenBy: Option[SeenBy] = none(SeenBy)) =
  self.arbitrate(seenBy)
  self.vals.add value

method clear(self: CustomArg) =
  procCall clear(Arg(self))
  self.vals.setLen 0

method lookup(self: EmptySource, key: ConfigKey): Option[seq[string]] =
  some(newSeq[string]())

method action(self: VariantProbe, command: string, spec: Spec, variant = "") =
  self.seenVariant = variant
  raise newException(MessageError, self.message)

proc withConfig(pairs: openArray[(string, seq[string])]): SpecSettings =
  var data: seq[(ConfigKey, seq[string])]
  for (k, v) in pairs:
    data.add (configKey(k), v)
  result = newSpecSettings(configSources = @[ConfigSource MemSource(data: data)])

suite "the write surface is reachable from the facade":
  test "parse and clear need no backend import":
    # This file imports `argumint` only; that it compiles at all is the check.
    let port = opt("--port=<n>", default = 80, help = "")
    port.parse("77", seenBy = some(byCli))
    check port.get == 77
    port.clear()
    check port.get == 80

  test "some(byCli) needs no import of std/options beyond the facade's own":
    # `some`/`none`/`Option` are re-exported by argumint itself.
    let port = opt("--port=<n>", default = 80, help = "")
    port.parse("77", seenBy = some(byCli))
    check port.seenBy == byCli

suite "seenBy declares a tier; omitting it extends the current one":
  test "a write with no tier leaves provenance untouched":
    let port = opt("--port=<n>", default = 80, help = "")
    port.parse("77")
    check port.seenBy == byNone
    check not port.seen

  test "a write with no tier is invisible to every accessor":
    # Every reader branches on `seen` -- ADR 0040. This is the deliberate
    # "extend, don't declare" case, not a bug.
    let port = opt("--port=<n>", default = 80, help = "")
    port.parse("77")
    check port.get == 80
    check port.get(otherwise = 1) == 1

  test "a write declaring a tier is visible to every accessor":
    let port = opt("--port=<n>", default = 80, help = "")
    port.parse("77", seenBy = some(byCli))
    check port.seenBy == byCli
    check port.seen
    check port.get == 77
    check port.get(otherwise = 1) == 77

  test "a write naming a weaker tier is ignored -- parse never demotes":
    # A stronger tier's value can't be quietly undercut by a later write.
    let port = opt("--port=<n>", default = 80, help = "")
    port.parse("77", seenBy = some(byCli))
    port.parse("99", seenBy = some(byConfig))
    check port.get == 77
    check port.seenBy == byCli

  test "a Flag write naming a weaker tier applies no operation":
    let verbose = flag[int](ops = [flagOp("-v", "+=", 1)], default = 0, help = "")
    verbose.parse("-v", seenBy = some(byCli))
    verbose.parse("-v", seenBy = some(byEnv))
    check verbose.get == 1
    check verbose.seenBy == byCli

  test "the base method refuses to demote too, so every Arg kind agrees":
    # Commands and Message Args go through the base; it must arbitrate the
    # same way the value-carrying overrides do.
    let cmd = command("run", (x: opt("-x=<n>", default = 0, help = "")), help = "")
    Arg(cmd).parse("", "", some(byCli))
    Arg(cmd).parse("", "", some(byConfig))
    check cmd.seenBy == byCli

  test "clear then parse is how a caller hands an Arg to a weaker tier":
    let port = opt("--port=<n>", default = 80, help = "")
    port.parse("77", seenBy = some(byCli))
    port.clear()
    port.parse("99", seenBy = some(byConfig))
    check port.get == 99
    check port.seenBy == byConfig

  test "a declared write records exactly the tier it was given":
    for tier in [byConfig, byEnv, byCli]:
      let port = opt("--port=<n>", default = 80, help = "")
      port.parse("77", seenBy = some(tier))
      check port.seenBy == tier

suite "parse's value semantics are unchanged and unconditional":
  test "a scalar ValueArg replaces its one slot":
    let port = opt("--port=<n>", default = 80, help = "")
    port.parse("1", seenBy = some(byCli))
    port.parse("2", seenBy = some(byCli))
    check port.get == 2

  test "a multi ValueArg appends":
    let tags = opts("--tag=<t>", help = "")
    tags.parse("a", seenBy = some(byCli))
    tags.parse("b", seenBy = some(byCli))
    check tags.get == @["a", "b"]

  test "a FlagArg applies the named variant's Flag Operation":
    let verbose = flag[int](ops = [flagOp("-v", "+=", 1), flagOp("-q", "-=", 1)],
                            default = 0, help = "")
    verbose.parse("-v", seenBy = some(byCli))
    verbose.parse("-v", seenBy = some(byCli))
    verbose.parse("-q", seenBy = some(byCli))
    check verbose.get == 1

  test "a FlagArg's clamp still applies to a programmatic write":
    let verbose = flag[int](ops = [flagOp("-v", "+=", 1)], default = 0,
                            clamp = clamp(0..2), help = "")
    for _ in 0 ..< 5:
      verbose.parse("-v", seenBy = some(byCli))
    check verbose.get == 2

  test "an unregistered flag variant raises":
    let verbose = flag[int](ops = [flagOp("-v", "+=", 1)], default = 0, help = "")
    expect ParseError:
      verbose.parse("--nope", seenBy = some(byCli))

  test "a value the Validator rejects still raises":
    let port = opt("--port=<n>", default = 80, validator = range(1..10), help = "")
    expect ValidationError:
      port.parse("99", seenBy = some(byCli))

  test "a value that cannot be converted still raises":
    let port = opt("--port=<n>", default = 80, help = "")
    expect ParseError:
      port.parse("nope", seenBy = some(byCli))

  test "the base parse is quiet for an Arg kind that carries no value":
    # Commands and Message Args go through the base, which only records --
    # it must not raise the way the old base did.
    let cmd = command("run", (x: opt("-x=<n>", default = 0, help = "")), help = "")
    let msg = message("--version", "1.0", help = "")
    let hlp = help("-h, --help", help = "")
    for arg in [Arg cmd, Arg msg, Arg hlp]:
      arg.parse("", "", some(byCli))
      check arg.seenBy == byCli

suite "a fallback tier's variant name is checked before it is applied":
  test "an empty env value names no variant, rather than the first one":
    # `parse` resolves "" to `variants[0]` as a convenience for programmatic
    # callers; a tier reading a blank env var must not get that fallback.
    putEnv("ARGUMINT_WRITE_BLANK", "")
    defer: delEnv("ARGUMINT_WRITE_BLANK")
    let verbose = flag[int](ops = [flagOp("-v", "+=", 1)], default = 0,
                            env = "ARGUMINT_WRITE_BLANK", help = "")
    let spec = (verbose: verbose)
    expect ParseError:
      spec.parse(usage = "[-v]...", args = @[], command = "app")

  test "an empty Config Source value names no variant either":
    let verbose = flag[int](ops = [flagOp("-v", "+=", 1)], default = 0,
                            configKey = configKey("verbose"), help = "")
    let spec = (verbose: verbose)
    expect ParseError:
      spec.parse(usage = "[-v]...", args = @[], command = "app",
                 settings = withConfig({"verbose": @[""]}))

suite "a write that raises leaves the Arg exactly as it was":
  # `arbitrate` runs its replacing body *before* clearing, and conversion
  # happens before `arbitrate` is reached at all -- so a failed write can't
  # leave an Arg cleared, stamped with a tier, and holding nothing. That
  # state would make the scalar accessor index an empty seq.
  test "a value that cannot be converted leaves an unsupplied Arg unsupplied":
    let port = opt("--port=<n>", default = 80, help = "")
    expect ParseError:
      port.parse("notanumber", seenBy = some(byCli))
    check port.seenBy == byNone
    check not port.seen
    check port.get == 80

  test "a value the Validator rejects leaves the weaker tier's value intact":
    let port = opt("--port=<n>", default = 80, validator = range(1..10), help = "")
    port.parse("5", seenBy = some(byConfig))
    expect ValidationError:
      port.parse("99", seenBy = some(byCli))
    check port.seenBy == byConfig
    check port.get == 5

  test "a failed Flag write leaves the value and provenance alone":
    let verbose = flag[int](ops = [flagOp("-v", "+=", 1)], default = 0, help = "")
    verbose.parse("-v", seenBy = some(byConfig))
    expect ParseError:
      verbose.parse("--nope", seenBy = some(byCli))
    check verbose.get == 1
    check verbose.seenBy == byConfig

suite "a history-aware Validator sees the right history per branch":
  test "replacing does not check against values about to be discarded":
    # `unique` would reject the promotion if it compared against the weaker
    # tier's values, which the stronger tier is about to clear.
    let tags = opts("--tag=<t>", validator = unique[string](), help = "")
    tags.parse("a", seenBy = some(byConfig))
    tags.parse("a", seenBy = some(byCli))
    check tags.get == @["a"]
    check tags.seenBy == byCli

  test "extending still checks against what is already there":
    let tags = opts("--tag=<t>", validator = unique[string](), help = "")
    tags.parse("a", seenBy = some(byCli))
    expect ValidationError:
      tags.parse("a", seenBy = some(byCli))
    check tags.get == @["a"]

suite "clear returns an Arg to its coded-default state":
  test "a scalar ValueArg clears both value and provenance":
    let port = opt("--port=<n>", default = 80, help = "")
    port.parse("77", seenBy = some(byCli))
    port.clear()
    check port.seenBy == byNone
    check not port.seen
    # Reads the coded default rather than indexing an emptied seq.
    check port.get == 80

  test "a multi ValueArg clears both value and provenance":
    let tags = opts("--tag=<t>", default = @["d"], help = "")
    tags.parse("a", seenBy = some(byCli))
    tags.clear()
    check tags.seenBy == byNone
    check tags.get == @["d"]

  test "a FlagArg restores its construction-time default after any ops":
    let verbose = flag[int](ops = [flagOp("-v", "+=", 1)], default = 3, help = "")
    verbose.parse("-v", seenBy = some(byCli))
    verbose.parse("-v", seenBy = some(byCli))
    check verbose.get == 5
    verbose.clear()
    check verbose.get == 3
    check verbose.seenBy == byNone

  test "clear on a command, help arg, or message arg is a no-op":
    let cmd = command("run", (x: opt("-x=<n>", default = 0, help = "")), help = "")
    let msg = message("--version", "1.0", help = "")
    let hlp = help("-h, --help", help = "")
    for arg in [Arg cmd, Arg msg, Arg hlp]:
      arg.parse("", "", some(byCli))
      arg.clear()
      check arg.seenBy == byNone

  test "clear then parse is the replace idiom for a multi-valued Arg":
    let tags = opts("--tag=<t>", help = "")
    tags.parse("a", seenBy = some(byCli))
    tags.parse("b", seenBy = some(byCli))
    tags.clear()
    for v in ["x", "y"]:
      tags.parse(v, seenBy = some(byCli))
    check tags.get == @["x", "y"]

suite "arbitrate is the tier rule a custom Arg subtype routes through":
  # ADR 0030's custom-Arg contract: an override arbitrates via `arbitrate`
  # and applies its value only on the branch that applies. Reachable from the
  # facade alone -- this file imports no backend.
  test "an equal tier applies without clearing":
    let c = CustomArg(kind: Optional, variants: @["--foo"], help: "")
    c.parse("a", seenBy = some(byEnv))
    c.parse("b", seenBy = some(byEnv))
    check c.vals == @["a", "b"]
    check c.seenBy == byEnv

  test "a weaker tier is refused and applies nothing":
    let c = CustomArg(kind: Optional, variants: @["--foo"], help: "")
    c.parse("a", seenBy = some(byCli))
    c.parse("z", seenBy = some(byConfig))
    check c.vals == @["a"]
    check c.seenBy == byCli

  test "a stronger tier clears first, then applies":
    let c = CustomArg(kind: Optional, variants: @["--foo"], help: "")
    c.parse("a", seenBy = some(byEnv))
    c.parse("x", seenBy = some(byCli))
    check c.vals == @["x"]
    check c.seenBy == byCli

  test "no declared tier extends at whatever tier is current":
    let c = CustomArg(kind: Optional, variants: @["--foo"], help: "")
    c.parse("a", seenBy = some(byCli))
    c.parse("y")
    check c.vals == @["a", "y"]
    check c.seenBy == byCli

suite "tier arbitration: S < T clears, then applies":
  test "an undeclared pre-seed is discarded by the command line":
    let tags = opts("--tag=<t>", help = "")
    let spec = (tags: tags)
    tags.parse("seed")
    spec.parse(usage = "[--tag=<t>]...", args = @["--tag", "a", "--tag", "b"],
               command = "app")
    check tags.get == @["a", "b"]
    check tags.seenBy == byCli

  test "a byConfig pre-seed is replaced by an env-supplied value":
    putEnv("ARGUMINT_WRITE_REPLACE", "1234")
    defer: delEnv("ARGUMINT_WRITE_REPLACE")
    let port = opt("--port=<n>", default = 80, env = "ARGUMINT_WRITE_REPLACE",
                   help = "")
    let spec = (port: port)
    port.parse("8080", seenBy = some(byConfig))
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app")
    check port.get == 1234
    check port.seenBy == byEnv

  test "an undeclared pre-seed is discarded by a Config Source value":
    let tags = opts("--tag=<t>", configKey = configKey("tags"), help = "")
    let spec = (tags: tags)
    tags.parse("seed")
    spec.parse(usage = "[--tag=<t>]...", args = @[], command = "app",
               settings = withConfig({"tags": @["a", "b"]}))
    check tags.get == @["a", "b"]
    check tags.seenBy == byConfig

suite "tier arbitration: S == T applies without clearing":
  test "a byCli pre-seed is appended to by command-line values, seed first":
    let tags = opts("--tag=<t>", help = "")
    let spec = (tags: tags)
    tags.parse("seed", seenBy = some(byCli))
    spec.parse(usage = "[--tag=<t>]...", args = @["--tag", "a", "--tag", "b"],
               command = "app")
    check tags.get == @["seed", "a", "b"]
    check tags.seenBy == byCli

  test "a byEnv pre-seed is appended to by env-supplied values":
    putEnv("ARGUMINT_WRITE_APPEND", "a:b")
    defer: delEnv("ARGUMINT_WRITE_APPEND")
    let tags = opts("--tag=<t>", env = "ARGUMINT_WRITE_APPEND", help = "")
    let spec = (tags: tags)
    tags.parse("seed", seenBy = some(byEnv))
    spec.parse(usage = "[--tag=<t>]...", args = @[], command = "app")
    check tags.get == @["seed", "a", "b"]
    check tags.seenBy == byEnv

  test "a byConfig pre-seed is appended to by config-supplied values":
    let tags = opts("--tag=<t>", configKey = configKey("tags"), help = "")
    let spec = (tags: tags)
    tags.parse("seed", seenBy = some(byConfig))
    spec.parse(usage = "[--tag=<t>]...", args = @[], command = "app",
               settings = withConfig({"tags": @["a", "b"]}))
    check tags.get == @["seed", "a", "b"]
    check tags.seenBy == byConfig

  test "a byCli pre-seeded Flag composes with command-line operations":
    let verbose = flag[int](ops = [flagOp("-v", "+=", 1)], default = 0, help = "")
    let spec = (verbose: verbose)
    verbose.parse("-v", seenBy = some(byCli))
    spec.parse(usage = "[-v]...", args = @["-v", "-v"], command = "app")
    check verbose.get == 3

suite "tier arbitration: S > T skips the tier entirely":
  test "a byCli pre-seed skips an available env var":
    putEnv("ARGUMINT_WRITE_SKIPENV", "1234")
    defer: delEnv("ARGUMINT_WRITE_SKIPENV")
    let port = opt("--port=<n>", default = 80, env = "ARGUMINT_WRITE_SKIPENV",
                   help = "")
    let spec = (port: port)
    port.parse("8080", seenBy = some(byCli))
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app")
    check port.get == 8080
    check port.seenBy == byCli

  test "a byCli pre-seed skips an available Config Source value":
    let port = opt("--port=<n>", default = 80, configKey = configKey("port"),
                   help = "")
    let spec = (port: port)
    port.parse("8080", seenBy = some(byCli))
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app",
               settings = withConfig({"port": @["1234"]}))
    check port.get == 8080
    check port.seenBy == byCli

  test "a byEnv pre-seed skips an available Config Source value":
    let port = opt("--port=<n>", default = 80, configKey = configKey("port"),
                   help = "")
    let spec = (port: port)
    port.parse("8080", seenBy = some(byEnv))
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app",
               settings = withConfig({"port": @["1234"]}))
    check port.get == 8080
    check port.seenBy == byEnv

suite "a tier that resolves nothing leaves a pre-seed intact":
  test "an absent env var does not destroy a byConfig pre-seed":
    delEnv("ARGUMINT_WRITE_ABSENT")
    let port = opt("--port=<n>", default = 80, env = "ARGUMINT_WRITE_ABSENT",
                   help = "")
    let spec = (port: port)
    port.parse("8080", seenBy = some(byConfig))
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app")
    check port.get == 8080
    check port.seenBy == byConfig

  test "an unmentioned command line does not destroy an undeclared pre-seed":
    let port = opt("--port=<n>", default = 80, help = "")
    let spec = (port: port)
    port.parse("8080")
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app")
    check port.get(otherwise = 8080) == 8080
    check port.seenBy == byNone

  test "an empty Config Source does not destroy an undeclared pre-seed":
    let tags = opts("--tag=<t>", configKey = configKey("tags"), help = "")
    let spec = (tags: tags)
    tags.parse("seed")
    spec.parse(usage = "[--tag=<t>]...", args = @[], command = "app",
               settings = withConfig({"other": @["a"]}))
    check tags.get(otherwise = @["seed"]) == @["seed"]

suite "provenance never outruns the value it describes":
  test "a Config Source offering zero values leaves the Arg unsupplied":
    # A source that *has* the key but resolves no values takes the apply
    # path and writes nothing. Stamping `byConfig` there would leave the Arg
    # reading as Seen with an empty value seq, and the scalar accessor would
    # index it -- so the tier's provenance is written by whoever writes the
    # value, not by the call site.
    let port = opt("--port=<n>", default = 80, configKey = configKey("port"),
                   help = "")
    let spec = (port: port)
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app",
               settings = newSpecSettings(configSources = @[ConfigSource EmptySource()]))
    check port.seenBy == byNone
    check not port.seen
    check port.get == 80

suite "an Arg reachable from two spec levels is applied once per tier":
  test "an env var shared by an ancestor and a nested command applies once":
    putEnv("ARGUMINT_WRITE_SHARED", "foo")
    defer: delEnv("ARGUMINT_WRITE_SHARED")
    let tag = opts("--tag=<t>", env = "ARGUMINT_WRITE_SHARED", help = "")
    let spec = (tag: tag, run: command("run", (tag: tag), usage = "[--tag=<t>]...",
                                       help = ""))
    spec.parse(usage = "[--tag=<t>]... run", args = @["run"], command = "app")
    check tag.get == @["foo"]

  test "a Config Source value shared by two levels applies once":
    let tag = opts("--tag=<t>", configKey = configKey("tag"), help = "")
    let spec = (tag: tag, run: command("run", (tag: tag), usage = "[--tag=<t>]...",
                                       help = ""))
    spec.parse(usage = "[--tag=<t>]... run", args = @["run"], command = "app",
               settings = withConfig({"tag": @["foo"]}))
    check tag.get == @["foo"]

suite "provenance is complete before the first hook fires":
  test "a pre-seeded Arg reads as supplied inside a before hook":
    let port = opt("--port=<n>", default = 80, help = "")
    var sawTier: SeenBy
    var sawValue: int
    let spec = (port: port)
    port.parse("8080", seenBy = some(byCli))
    spec.parse(usage = "[--port=<n>]", args = @[], command = "app",
               before = proc (s: tuple[port: type port], info: HookInfo) =
                 sawTier = s.port.seenBy
                 sawValue = s.port.get)
    check sawTier == byCli
    check sawValue == 8080

suite "Message Args still fire, and know which variant fired":
  test "a help request still raises HelpError":
    let spec = (h: help("-h, --help", help = "show help"),
                port: opt("--port=<n>", default = 80, help = ""))
    expect HelpError:
      spec.parse(usage = "[-h] [--port=<n>]", args = @["-h"], command = "app")

  test "a message arg still raises MessageError":
    let spec = (v: message("--version, -V", "1.0", help = ""))
    expect MessageError:
      spec.parse(usage = "[-V]", args = @["-V"], command = "app")

  test "action receives the variant that matched, not the matched value":
    # `parseMessageArgs` dispatches with the Match's `variant`; passing its
    # `value` instead leaves a multi-variant Message Arg unable to tell which
    # of its own spellings the user typed.
    let probe = VariantProbe(kind: Flag, variants: @["--version", "-V"],
                             message: "1.0", help: "")
    let spec = (v: Arg probe)
    expect MessageError:
      spec.parse(usage = "[-V]", args = @["-V"], command = "app")
    check probe.seenVariant == "-V"
