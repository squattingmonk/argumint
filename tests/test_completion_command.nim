# Tests for `completion()`, the built-in command printing the whole
# program's completion script as a Message Argument (#252, ADR 0074).

import std/[sequtils, strutils, unittest]

import argumint
from argumint/completion import reply

proc messageOf(body: proc ()): string =
  try:
    body()
  except MessageError as e:
    result = e.msg

proc wire(spec: Spec, words: varargs[string]): seq[string] =
  ## `__complete`'s output for `words`, one line each.
  spec.reply(@words, "prog").splitLines

suite "completion()":
  test "prints the root Spec's script for each shell":
    for shell in Shell:
      let built = (completion: completion(), help: help()).newSpec
      let msg = messageOf(proc () =
        built.parse(args = @["completion", $shell], command = "prog"))
      check msg == built.completionScript(shell, "prog")
      check msg.len > 0

  test "completes the command given to parse":
    let built = (completion: completion()).newSpec
    let msg = messageOf(proc () =
      built.parse(args = @["completion", "fish"], command = "notes"))
    check msg == built.completionScript(Shell.fish, "notes")
    check "__notes_complete" in msg

  test "nested in a command, still prints the whole program's script":
    let built = (
      tools: command("tools", (completion: completion()), help = ""),
    ).newSpec
    let msg = messageOf(proc () =
      built.parse(args = @["tools", "completion", "bash"], command = "prog"))
    check msg == built.completionScript(Shell.bash, "prog")

  test "is a message: before hooks see showsMessage, no action fires":
    var log: seq[string]
    proc before(spec: tuple, info: HookInfo) =
      log.add "before " & $info.showsMessage
    proc action(spec: tuple, info: HookInfo) = log.add "action"
    proc after(spec: tuple, info: HookInfo) = log.add "after"
    let spec = (completion: completion(), help: help())
    discard messageOf(proc () =
      spec.parse(args = @["completion", "zsh"], command = "prog",
        before = before, action = action, after = after,
        usage = "{cmd}\n{cmd} completion"))
    check log == @["before true", "after"]

  test "an unknown shell is a parse error and fires no hook":
    var log: seq[string]
    proc before(spec: tuple, info: HookInfo) = log.add "before"
    let spec = (completion: completion())
    expect ParseError:
      spec.parse(args = @["completion", "tcsh"], command = "prog",
        before = before)
    check log.len == 0

  test "its help lists the shells":
    let spec = (completion: completion(), help: help())
    var text = ""
    try:
      spec.parse(args = @["completion", "--help"], command = "prog",
        settings = newSpecSettings(style = nil))
    except HelpError as e:
      text = e.msg
    check "Usage:\n  prog completion <shell>\n" in text
    check "[choices: bash, zsh, fish]" in text
    check "source <(prog completion bash)" in text

  test "Tab offers the shells":
    let built = (completion: completion(), help: help()).newSpec
    let words = built.wire("completion", "")
    for shell in ["bash", "zsh", "fish"]:
      check shell & "\t" in words

  test "another command's arg[Shell] is not a message":
    var got: seq[Shell]
    proc install(spec: tuple, info: HookInfo) =
      check not info.showsMessage
      got.add spec.shell.get
    let spec = (
      install: command("install", (shell: arg[Shell]("<shell>")), help = "",
        action = install),
      completion: completion(),
    )
    spec.parse(args = @["install", "fish"], command = "prog")
    check got == @[Shell.fish]

  test "takes another name, and hidden keeps it out of help and Tab":
    let built = (
      gen: completion("gen-completion", hidden = true),
      help: help(),
    ).newSpec(settings = newSpecSettings(style = nil))
    let msg = messageOf(proc () =
      built.parse(args = @["gen-completion", "fish"], command = "prog"))
    check msg == built.completionScript(Shell.fish, "prog")

    var text = ""
    try:
      built.parse(args = @["--help"], command = "prog")
    except HelpError as e:
      text = e.msg
    check "Commands:" notin text
    check not built.wire("").anyIt(it.startsWith("gen-completion"))
