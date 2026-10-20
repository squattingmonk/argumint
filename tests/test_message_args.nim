# Tests for Message Arguments as a capability (#255): any Arg whose
# `isMessage` is `true` fires its `action` in place of the level's own
# `action` hook, may be any kind, and may hold a converted value.
#
# The probes are declared here, outside the library, on purpose: a
# `ValueArg[T]` subtype built by the withheld `initValueArg(A, ...)` must
# dispatch its own overrides from a foreign module -- see docs/gotchas.md.

import std/[strutils, unittest]

import argumint, argumint/customarg
import argumint/values/argtypes

type
  Color = enum red, green, blue

  ColorProbe = ref object of ValueArg[Color]
    ## A positional Message Argument holding an enum.

  LevelProbe = ref object of ValueArg[int]
    ## An Option Message Argument taking a value.

method isMessage(self: ColorProbe): bool = true

method action(self: ColorProbe, info: HookInfo, variant = "") =
  raise newException(MessageError, "color " & $self.get & " at " & info.here.command)

method isMessage(self: LevelProbe): bool = true

method action(self: LevelProbe, info: HookInfo, variant = "") =
  raise newException(MessageError, "level " & $self.get & " via " & variant)

proc colorProbe(): ColorProbe =
  initValueArg(ColorProbe, kind = Positional, variants = "<color>",
    default = red, help = "", group = "", hidden = false,
    validator = noValidator[Color]())

proc levelProbe(): LevelProbe =
  initValueArg(LevelProbe, kind = Optional, variants = "--level,-l",
    default = 0, help = "", group = "", hidden = false,
    validator = range(1..9))

proc messageOf(body: proc ()): string =
  try:
    body()
  except MessageError as e:
    result = e.msg

suite "a ValueArg subtype from another module":
  test "dispatches its own isMessage":
    check colorProbe().isMessage
    check levelProbe().isMessage

  test "converts its value through ValueArg[T]'s hooks":
    let probe = colorProbe()
    probe.parse("blue")
    check probe.get == blue

suite "a positional Message Argument holding a value":
  test "fires its action with the converted value":
    var log: seq[string]
    var shown = false
    proc before(spec: tuple, info: HookInfo) =
      log.add "before"
      shown = info.showsMessage
    proc action(spec: tuple, info: HookInfo) = log.add "action"
    proc after(spec: tuple, info: HookInfo) = log.add "after"

    let spec = (color: colorProbe())
    let msg = messageOf(proc () =
      spec.parse(args = @["green"], command = "prog", before = before,
        action = action, after = after))
    check msg == "color green at prog"
    check shown
    check log == @["before", "after"]

  test "an invalid value fails as a parse error and fires no hook":
    var log: seq[string]
    proc before(spec: tuple, info: HookInfo) = log.add "before"

    let spec = (color: colorProbe())
    expect ParseError:
      spec.parse(args = @["mauve"], command = "prog", before = before)
    check log.len == 0

  test "fires at the level it was typed at, with that level's command":
    let sub = (color: colorProbe())
    let spec = (paint: command("paint", sub, help = ""))
    let msg = messageOf(proc () =
      spec.parse(args = @["paint", "blue"], command = "prog"))
    check msg == "color blue at prog paint"

  test "an auto-filled usage lists it once, in the positional line":
    let spec = (color: colorProbe(), help: help())
    var text = ""
    try:
      spec.parse(args = @["--help"], command = "prog",
        settings = newSpecSettings(style = nil))
    except HelpError as e:
      text = e.msg
    check text.startsWith("Usage:\n  prog <color>\n  prog (-h | --help)\n\n")

suite "an Option Message Argument taking a value":
  test "fires its action with the converted value and typed variant":
    var log: seq[string]
    var shown = false
    proc before(spec: tuple, info: HookInfo) =
      log.add "before"
      shown = info.showsMessage
    proc after(spec: tuple, info: HookInfo) = log.add "after"

    let spec = (level: levelProbe())
    let msg = messageOf(proc () =
      spec.parse(args = @["-l", "3"], command = "prog", before = before,
        after = after))
    check msg == "level 3 via -l"
    check shown
    check log == @["before", "after"]

  test "an unconvertible value fails as a parse error and fires no hook":
    var log: seq[string]
    proc before(spec: tuple, info: HookInfo) = log.add "before"

    let spec = (level: levelProbe())
    expect ParseError:
      spec.parse(args = @["--level=x"], command = "prog", before = before)
    check log.len == 0

  test "an invalid value fails validation and fires no hook":
    var log: seq[string]
    proc before(spec: tuple, info: HookInfo) = log.add "before"

    let spec = (level: levelProbe())
    expect ValidationError:
      spec.parse(args = @["--level=12"], command = "prog", before = before)
    check log.len == 0

suite "plain Args are not Message Arguments":
  test "arg, opt and flag have isMessage false":
    check not arg[Color]("<color>").isMessage
    check not opt("--level=<n>", default = 0).isMessage
    check not flag("-v").isMessage

  test "matching them leaves showsMessage false and fires the action hook":
    var shown = true
    var fired = false
    proc action(spec: tuple, info: HookInfo) =
      shown = info.showsMessage
      fired = true

    let spec = (color: arg[Color]("<color>"), level: opt("--level=<n>", default = 0),
      verbose: flag("-v"))
    spec.parse(args = @["blue", "--level=2", "-v"], command = "prog", action = action)
    check fired
    check not shown
    check spec.color == blue

suite "HookInfo carries the root and the level being dispatched":
  test "every hook at every level sees its own level and the shared root":
    var log: seq[string]
    var seen: seq[(string, Spec, Spec)]
      ## Per hook: its name, `here.spec` and `root.spec`.

    proc record(name: string, info: HookInfo) =
      log.add name & ": " & info.here.command & " / " & info.root.command
      seen.add (name, info.here.spec, info.root.spec)

    template hook(name: string): untyped =
      proc (spec: tuple, info: HookInfo) = record(name, info)

    let b = (n: opt("-n=<n>", default = 0))
    let a = (b: command("b", b, help = "", before = hook("b-before"),
      action = hook("b-action"), after = hook("b-after")))
    let spec = (a: command("a", a, help = "", before = hook("a-before"),
      action = hook("a-action"), after = hook("a-after")))
    let built = spec.newSpec(settings = newSpecSettings(style = nil))
    built.before = proc (info: HookInfo) = record("root-before", info)
    built.action = proc (info: HookInfo) = record("root-action", info)
    built.after = proc (info: HookInfo) = record("root-after", info)
    built.parse(args = @["a", "b"], command = "prog")

    check log == @[
      "root-before: prog / prog",
      "a-before: prog a / prog",
      "b-before: prog a b / prog",
      "b-action: prog a b / prog",
      "b-after: prog a b / prog",
      "a-after: prog a / prog",
      "root-after: prog / prog",
    ]
    for (name, here, root) in seen:
      let expected =
        if name.startsWith("root"): built
        elif name.startsWith("a-"): spec.a.spec
        else: a.b.spec
      check here == expected
      check root == built

  test "at the root, here is root":
    var got: HookInfo
    let built = (n: opt("-n=<n>", default = 0)).newSpec
    built.action = proc (info: HookInfo) = got = info
    built.parse(args = @[], command = "prog")
    check got.here == got.root
    check got.root == (built, "prog")

  test "root.command follows the command passed to parse":
    var root = ""
    proc before(spec: tuple, info: HookInfo) = root = info.root.command
    let spec = (n: opt("-n=<n>", default = 0))
    spec.parse(args = @[], command = "notes", before = before)
    check root == "notes"
