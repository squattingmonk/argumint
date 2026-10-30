# What `argumint/customarg` adds to `import argumint` for a Custom Arg
# (#269): `initArg`, and the methods and types a Custom Arg overrides.

import std/[options, unittest]

import argumint, argumint/customarg

type TagArg = ref object of Arg
  tags: seq[string]

method accept(self: TagArg, c: Contribution, how: Arbitration) =
  if how == arReplace:
    self.clear
  self.tags.add c.value

proc tagArg(variants: string): TagArg =
  result = TagArg(help: "A tag", group: "Options")
  result.initArg(Optional, variants)

suite "initArg":
  test "sets kind, and splits variants as the built-in constructors do":
    let tag = tagArg("-t, --tag=<t>")
    check tag.kind == ArgKind.Optional
    check tag.variants == @["-t", "--tag=<t>"]
    check tag.variants == opt("-t, --tag=<t>", help = "").variants

  test "raises SpecDefect on a second call":
    let tag = tagArg("--tag=<t>")
    expect SpecDefect:
      tag.initArg(Optional, "--other=<o>")
    check tag.variants == @["--tag=<t>"]

  test "leaves the Variants to newSpec, which names the tuple field":
    let bad = tagArg("-_")
    try:
      discard newSpec((tag: bad))
      fail()
    except SpecDefect as e:
      check e.msg == "invalid optional arg variant for tag: -_"

  test "a Custom Arg built with it parses through the facade":
    let spec = (tag: tagArg("--tag=<t>"))
    spec.parse(args = @["--tag", "a", "--tag", "b"], command = "prog")
    check spec.tag.tags == @["a", "b"]
    check spec.tag.seenBy == byCli

suite "the Custom Arg surface":
  test "an Arg's value sources can be read back":
    # #59: overriding never needed these exported, but reading one back
    # did. See `docs/adr/0046-arg-value-source-contract.md`.
    let port = opt("--port=<n>", env = env("PORT", ","),
                   configKey = configKey("server", "port"), help = "")
    check port.envSource.isSome
    check port.envSource.get.name == "PORT"
    check port.envSource.get.delim == some(",")
    check port.envName == "PORT"
    check port.configKey.join == "server.port"

    # An Arg with neither tier reads as empty rather than failing to compile.
    let name = arg("<name>", help = "")
    check name.envSource.isNone
    check name.envName == ""
    check name.configKey.len == 0

  test "every name the facade withholds is here":
    let port = opt("--port=<n>", default = 0, help = "")
    check not port.isMessage
    check compiles(Arg(nil).action(HookInfo()))
    check compiles(Arg(nil).accept(Contribution(), arReplace))
    check compiles(subject(Arg(nil), Contribution(variant: "-v")))
    check arReplace is Arbitration
