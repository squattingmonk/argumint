# Drives the generated zsh completion script through a real interactive zsh,
# since `compset`/`compadd` only run inside a completion widget (#198). This
# binary is also the CLI being completed: zsh runs it, through a `mycli`
# symlink, with `__complete`. Skipped where zsh isn't installed, and on
# Windows.

import std/[os, osproc, strutils, unittest]

import argumint

let cli = (
  logLevel: opt("--log-level=<level>", validator = choice(["debug", "info", "warn", "error"]),
    help = "How much to log"),
  deploy: command("deploy", (
    env: arg("<env>", validator = choice(["staging", "production"])),
  ), help = "Deploy the site"),
  help: help(),
)

if isCompletionRequest():
  cli.parseOrQuit(command = "mycli")

const Driver = """
zmodload zsh/zpty
bindir=$1 script=$2 typed=$3
zpty -b z "PATH=$bindir:\$PATH zsh -f -i"
# Reads until the output matches the pattern `$1`, for up to 10 seconds.
await() {
  out=""
  local chunk i
  for i in {1..100}; do
    while zpty -r -t z chunk; do out+=$chunk; done
    [[ $out == $~1 ]] && return 0
    sleep 0.1
  done
  return 1
}
zpty -w z "PS1='> '; unsetopt PROMPT_SP; autoload -U compinit; compinit -u; setopt nobeep; source ${(q)script}"
zpty -w z "bindkey -e; dumpbuf() { print -r -- \"<<BUF:\$BUFFER>>\" }; zle -N dumpbuf; bindkey '^X' dumpbuf"
zpty -w z 'echo __READY__'
await '*__READY__*__READY__*' || exit 1
zpty -w -n z "$typed"$'\t\x18'
await '*<<BUF:*>>*' || exit 1
print -r -- "$out"
zpty -d z
"""
  ## Types `typed` and Tab, then Ctrl-X to print the line (`dumpbuf`), which
  ## zsh reads only once the Tab is done. `bindkey -e`, since `$EDITOR` may
  ## pick vi.

proc stripAnsi(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\e' and i + 1 < s.len and s[i + 1] == '[':
      i += 2
      while i < s.len and s[i] notin {'a'..'z', 'A'..'Z'}:
        i.inc
    elif s[i] != '\r':
      result.add s[i]
    i.inc

suite "zsh script (#198)":
  let zshExe = when defined(windows): "" else: findExe("zsh")
  let dir = getTempDir() / "argumint_zsh_completion"
  let script = dir / "mycli.zsh"
  let driver = dir / "drive.zsh"
  if zshExe.len > 0:
    createDir(dir)
    removeFile(dir / "mycli")
    createSymlink(getAppFilename(), dir / "mycli")
    writeFile(script, newSpec(cli).completionScript(zsh, "mycli"))
    writeFile(driver, Driver)

  template needsZsh(body: untyped) =
    if zshExe.len == 0: skip()
    else: body

  proc tab(typed: string): tuple[menu: seq[string], line: string] =
    ## The menu Tab lists after `typed`, and the line it leaves.
    let (output, code) = execCmdEx(quoteShellCommand([zshExe, "-f", driver, dir, script, typed]))
    doAssert code == 0, output
    # The typed line, any menu, then the line again with `dumpbuf`'s output.
    let lines = output.stripAnsi.splitLines
    var typedAt = -1
    for i, line in lines:
      if "<<BUF:" in line:
        result.line = line[line.find("<<BUF:") + 6 ..< line.find(">>")]
        result.menu = lines[typedAt + 1 ..< i]
        break
      if typedAt < 0 and typed in line:
        typedAt = i

  let levels = @["debug", "error", "info", "warn"]

  for (typed, menu) in [
    ("mycli --log-level=", levels),
    ("mycli --log-level:", levels),
    ("mycli --log-level ", levels),
    ("mycli deploy ", @["production", "staging"]),
  ]:
    test "Tab after " & typed.escape & " lists " & $menu:
      needsZsh:
        check tab(typed).menu.join(" ").splitWhitespace == menu

  for (typed, line) in [
    ("mycli --log-level=de", "mycli --log-level=debug "),
    ("mycli --log-level:w", "mycli --log-level:warn "),
    ("mycli dep", "mycli deploy "),
    ("mycli zzz", "mycli zzz"),
    ("mycli deploy staging ", "mycli deploy staging "),
  ]:
    test "Tab after " & typed.escape & " leaves " & line.escape:
      needsZsh:
        check tab(typed).line == line

  test "Tab mid-line completes the word under the cursor":
    needsZsh:
      # Typed `mycli d cat`, then the cursor moved back onto `d`.
      check tab("mycli d cat\e[D\e[D\e[D\e[D").line.startsWith("mycli deploy ")

  test "the menu shows each word beside its description":
    needsZsh:
      # zsh may pack entries into columns, so look for each one.
      let menu = tab("mycli ").menu.join("\n")
      for entry in [
        "deploy  -- Deploy the site",
        "-h  -- Display this help message",
        "--help  -- Display this help message",
        "--log-level  -- How much to log",
      ]:
        check entry in menu

  test "the menu after a value offers the next words":
    needsZsh:
      let menu = tab("mycli --log-level=info ").menu.join("\n")
      check "deploy  -- Deploy the site" in menu
      check "debug" notin menu

  removeDir(dir)
