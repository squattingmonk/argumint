# `showHelp`, which a hook calls to show its Level's help the way that
# Level's Help flag would. Imports nothing but `argumint`, so a program can
# reach it without `argumint/help`.

import std/[os, osproc, streams, unittest]

import argumint

proc tagged(role: StyleRole, text: string): string =
  ## Marks each styled span as `{role:text}`.
  "{" & $role & ":" & text & "}"

proc helpRaised(spec: tuple, args: seq[string], showHelpFromAction = false,
    settings = newSpecSettings(style = nil)): ref HelpError =
  ## The `HelpError` that parsing `args` raises for `spec`; with
  ## `showHelpFromAction`, the root Action calls `showHelp`.
  proc show(spec: tuple, info: HookInfo) = showHelp(info)
  try:
    if showHelpFromAction:
      spec.parse(action = show, args = args, command = "prog", settings = settings)
    else:
      spec.parse(args = args, command = "prog", settings = settings)
  except HelpError as e: result = e
  doAssert not result.isNil, "no HelpError raised"

suite "showHelp from an Action":
  test "it raises what the Level's --help would, unstyled":
    let spec = (name: opt("--name=<name>", help = "Who to greet"), help: help())
    let shown = spec.helpRaised(@[], showHelpFromAction = true)
    let asked = spec.helpRaised(@["--help"])
    check shown.msg == asked.msg
    check shown.styledMsg == asked.styledMsg

  test "it raises what the Level's --help would, styled":
    let spec = (name: opt("--name=<name>", help = "Who to `greet`"), help: help())
    let styled = newSpecSettings(style = tagged)
    let shown = spec.helpRaised(@[], showHelpFromAction = true, settings = styled)
    let asked = spec.helpRaised(@["--help"], settings = styled)
    check shown.msg == asked.msg
    check shown.styledMsg == asked.styledMsg
    check shown.styledMsg != shown.msg

  test "it uses the Help flag's formatter":
    let spec = (name: opt("--name=<name>", help = "Who to greet"),
      help: help(formatter = formatParagraph))
    check spec.helpRaised(@[], showHelpFromAction = true).msg == """
Usage:
  prog [options]
  prog (-h | --help)

Options:
  --name=<name>
    Who to greet

  -h, --help
    Display this help message"""

  test "with two Help flags, it uses the first declared":
    let spec = (name: opt("--name=<name>", help = "Who to greet"),
      long: help("--help-long", formatter = formatParagraph),
      help: help())
    check spec.helpRaised(@[], showHelpFromAction = true).msg == """
Usage:
  prog [options]
  prog --help-long
  prog (-h | --help)

Options:
  --name=<name>
    Who to greet

  --help-long
    Display this help message

  -h, --help
    Display this help message"""

  test "with no Help flag, it falls back to formatColumn":
    let spec = (name: opt("--name=<name>", help = "Who to greet"),)
    let e = spec.helpRaised(@[], showHelpFromAction = true)
    check e.msg == """
Usage:
  prog [options]

Options:
  --name=<name>  Who to greet"""
    check e.styledMsg == e.msg

  test "with no Help flag, only styledMsg is styled":
    let spec = (name: opt("--name=<name>", help = "Who to greet"),)
    let e = spec.helpRaised(@[], showHelpFromAction = true,
      settings = newSpecSettings(style = tagged))
    check e.msg == """
Usage:
  prog [options]

Options:
  --name=<name>  Who to greet"""
    check e.styledMsg == """
{srHeader:Usage:}
{srPlain:  }{srProgram:prog}{srPlain: }{srOption:[options]}

{srHeader:Options:}
{srPlain:  }{srOption:--name}{srPlain:=}{srMetavar:<name>}{srPlain:  Who to greet}"""

  test "it shows the Level being dispatched, not the root":
    proc move(spec: tuple, info: HookInfo) = showHelp(info)
    let moveSpec = (speed: opt("--speed=<kn>", help = "Speed in knots"),)
    let shipSpec = (move: command("move", moveSpec, action = move),)
    let spec = (ship: command("ship", shipSpec), help: help())
    check spec.helpRaised(@["ship", "move"]).msg == """
Usage:
  prog ship move [options]

Options:
  --speed=<kn>  Speed in knots"""

  test "from a Command's Action, it raises what that Command's --help would":
    proc move(spec: tuple, info: HookInfo) = showHelp(info)
    let moveSpec = (speed: opt("--speed=<kn>", help = "Speed in knots"), help: help())
    let spec = (ship: command("ship", (move: command("move", moveSpec, action = move),)),)
    for settings in [newSpecSettings(style = nil), newSpecSettings(style = tagged)]:
      let shown = spec.helpRaised(@["ship", "move"], settings = settings)
      let asked = spec.helpRaised(@["ship", "move", "--help"], settings = settings)
      check shown.msg == asked.msg
      check shown.styledMsg == asked.styledMsg

  test "it ends an if expression's branch":
    var key = ""
    proc pick(spec: tuple, info: HookInfo) =
      key = if info.here.command == "prog": "root" else: showHelp(info)
    (name: opt("--name=<name>", help = "Who to greet"),).parse(
      action = pick, args = @[], command = "prog")
    check key == "root"

suite "showHelp through parseOrQuit":
  test "it prints the help to stdout and exits 0":
    let
      dir = getTempDir() / "argumint_t318_" & $getCurrentProcessId()
      bin = dir / "app".addFileExt(ExeExt)
      root = currentSourcePath().parentDir.parentDir
    createDir(dir)
    defer: removeDir(dir)
    let build = execCmdEx(quoteShellCommand([getCurrentCompilerExe(), "c",
      "--hints:off", "--warnings:off", "--path:" & root / "src",
      "--nimcache:" & dir / "nimcache", "-o:" & bin,
      root / "tests" / "fixtures" / "showhelp_app.nim"]))
    doAssert build.exitCode == 0, build.output
    let p = startProcess(bin, args = ["config"], options = {})
    defer: p.close()
    let output = p.outputStream.readAll
    check p.waitForExit == 0
    check output == """
Usage:
  app config [options]
  app config (-h | --help)

Options:
  --key=<key>  The key to read
  -h, --help   Display this help message
"""
