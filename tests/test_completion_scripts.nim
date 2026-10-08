# Drives the generated completion scripts through the real shells (#198,
# #200): zsh interactively, since `compset`/`compadd` only run inside a
# completion widget; fish through `complete -C`; and bash by setting
# `COMP_WORDS` as readline would and calling the function. This binary is
# also the CLI being completed: each shell runs it, through an `amdemo`
# symlink, with `__complete`. A suite is skipped where its shell isn't
# installed, and on Windows.

import std/[algorithm, os, osproc, sequtils, strutils, unittest]

import argumint

let cli = (
  logLevel: opt("--log-level=<level>", validator = choice(["debug", "info", "warn", "error"]),
    help = "How much to log"),
  output: opt("-o, --out=<file>", help = "Where to write"),
  into: opt("--into=<dir>", complete = Dirs, help = "Where to put it"),
  deploy: command("deploy", (
    env: arg("<env>", validator = choice(["staging", "production"])),
  ), help = "Deploy the site"),
  cat: command("cat", (file: arg("<file>"), n: flag("-n"), help: help()), help = "Print a file"),
  cd: command("cd", (dir: arg("<dir>", complete = Dirs), help: help()), help = "Change directory"),
  tag: command("tag", (name: arg("<name>", complete = None), help: help()), help = "Tag it"),
  count: command("count", (count: arg[int]("<count>"), help: help()), help = "Count"),
  help: help(),
)

if isCompletionRequest():
  cli.parseOrQuit(command = "amdemo")

let root = getTempDir() / "argumint_completion_scripts"
let bin = root / "bin"
  ## Holds the `amdemo` symlink, put on `PATH`.
let work = root / "work"
  ## The directory each shell completes in.

proc setUp(shell: Shell): string =
  ## Lays out `root` and writes `shell`'s script, returning its path.
  createDir(bin)
  createDir(work / "src")
  createDir(work / "sub dir")
  writeFile(work / "alpha.txt", "")
  writeFile(work / "beta file.txt", "")
  writeFile(work / "sample.txt", "")
  writeFile(work / "src" / "main.nim", "")
  removeFile(bin / "amdemo")
  createSymlink(getAppFilename(), bin / "amdemo")
  result = root / "amdemo." & $shell
  writeFile(result, newSpec(cli).completionScript(shell, "amdemo"))

const Driver = """
zmodload zsh/zpty
bindir=$1 script=$2 typed=$3 workdir=$4
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
zpty -w z "cd ${(q)workdir}; PS1='> '; unsetopt PROMPT_SP; autoload -U compinit; compinit -u; setopt nobeep; source ${(q)script}"
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

suite "zsh script (#198, #200)":
  let zshExe = when defined(windows): "" else: findExe("zsh")
  let driver = root / "drive.zsh"
  var script = ""
  if zshExe.len > 0:
    script = setUp(zsh)
    writeFile(driver, Driver)

  template needsZsh(body: untyped) =
    if zshExe.len == 0: skip()
    else: body

  proc tab(typed: string): tuple[menu: seq[string], line: string] =
    ## The menu Tab lists after `typed`, and the line it leaves.
    let (output, code) = execCmdEx(quoteShellCommand([zshExe, "-f", driver, bin, script, typed, work]))
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
    ("amdemo --log-level=", levels),
    ("amdemo --log-level:", levels),
    ("amdemo --log-level ", levels),
    ("amdemo deploy ", @["production", "staging"]),
  ]:
    test "Tab after " & typed.escape & " lists " & $menu:
      needsZsh:
        check tab(typed).menu.join(" ").splitWhitespace == menu

  for (typed, line) in [
    ("amdemo --log-level=de", "amdemo --log-level=debug "),
    ("amdemo --log-level:w", "amdemo --log-level:warn "),
    ("amdemo dep", "amdemo deploy "),
    ("amdemo zzz", "amdemo zzz"),
    ("amdemo deploy staging ", "amdemo deploy staging "),
    ("amdemo cat al", "amdemo cat alpha.txt "),
    ("amdemo cat be", "amdemo cat beta\\ file.txt "),
    ("amdemo cat su", "amdemo cat sub\\ dir/"),
    ("amdemo cat src/", "amdemo cat src/main.nim "),
    ("amdemo cat alpha.txt ", "amdemo cat alpha.txt -n "),
    ("amdemo -o be", "amdemo -o beta\\ file.txt "),
    ("amdemo --out=be", "amdemo --out=beta\\ file.txt "),
  ]:
    test "Tab after " & typed.escape & " leaves " & line.escape:
      needsZsh:
        check tab(typed).line == line

  test "Tab mid-line completes the word under the cursor":
    needsZsh:
      # Typed `amdemo d cat`, then the cursor moved back onto `d`.
      check tab("amdemo d cat\e[D\e[D\e[D\e[D").line.startsWith("amdemo deploy ")

  test "the menu shows each word beside its description":
    needsZsh:
      # zsh may pack entries into columns, so look for each one.
      let menu = tab("amdemo ").menu.join("\n")
      for entry in [
        "deploy  -- Deploy the site",
        "-h  -- Display this help message",
        "--help  -- Display this help message",
        "--log-level  -- How much to log",
      ]:
        check entry in menu

  test "the menu after a value offers the next words":
    needsZsh:
      let menu = tab("amdemo --log-level=info ").menu.join("\n")
      check "deploy  -- Deploy the site" in menu
      check "debug" notin menu

  for (typed, has, lacks) in [
    ("amdemo cat ", @["alpha.txt", "beta\\ file.txt", "src/", "sub\\ dir/", "-n", "--help"], newSeq[string]()),
    ("amdemo cd ", @["src/", "sub\\ dir/", "--help"], @["alpha.txt"]),
    ("amdemo count ", @["alpha.txt", "src/", "--help"], newSeq[string]()),
    ("amdemo --into=s", @["src/", "sub\\ dir/"], @["sample.txt"]),
    ("amdemo --log-level=", @["debug"], @["alpha.txt"]),
  ]:
    test "Tab after " & typed.escape & " lists " & $has & ", not " & $lacks:
      needsZsh:
        let menu = tab(typed).menu.join("\n")
        for word in has: check word in menu
        for word in lacks: check word notin menu

  test "Tab after a None positional offers only options":
    needsZsh:
      # `-h` and `--help` share `-`, which zsh inserts.
      check tab("amdemo tag ").line == "amdemo tag -"

  removeDir(root)

suite "fish script (#200)":
  let fishExe = when defined(windows): "" else: findExe("fish")
  var script = ""
  if fishExe.len > 0:
    script = setUp(fish)

  proc complete(typed: string): seq[string] =
    ## The words fish's `complete -C` offers after `typed`, in `work`.
    let command = "set -x PATH " & quoteShell(bin) & " $PATH; source " & quoteShell(script) &
      "; complete -C " & quoteShell(typed)
    let (output, code) = execCmdEx(quoteShellCommand([fishExe, "--no-config", "-c", command]),
      workingDir = work)
    doAssert code == 0, output
    output.splitLines.filterIt(it.len > 0).mapIt(it.split('\t')[0])

  for (typed, offered) in [
    ("amdemo cat ", @["alpha.txt", "beta file.txt", "sample.txt", "src/", "sub dir/", "-h", "-n", "--help"]),
    ("amdemo cat al", @["alpha.txt"]),
    ("amdemo cat su", @["sub dir/"]),
    ("amdemo --into=s", @["--into=src/", "--into=sub dir/"]),
    ("amdemo cat src/", @["src/main.nim"]),
    ("amdemo cat alpha.txt ", @["-n"]),
    ("amdemo cd ", @["src/", "sub dir/", "-h", "--help"]),
    ("amdemo tag ", @["-h", "--help"]),
    ("amdemo count ", @["alpha.txt", "beta file.txt", "sample.txt", "src/", "sub dir/", "-h", "--help"]),
    ("amdemo -o be", @["beta file.txt"]),
    ("amdemo --out=be", @["--out=beta file.txt"]),
    ("amdemo --into=", @["--into=src/", "--into=sub dir/"]),
    ("amdemo --log-level=", @["--log-level=debug", "--log-level=error", "--log-level=info", "--log-level=warn"]),
    ("amdemo deploy s", @["staging"]),
  ]:
    test "completing " & typed.escape & " offers " & $offered:
      if fishExe.len == 0: skip()
      else:
        check complete(typed) == offered

  removeDir(root)

suite "bash script (#200)":
  let bashExe = when defined(windows): "" else: findExe("bash")
  var script = ""
  if bashExe.len > 0:
    script = setUp(bash)

  proc complete(words: seq[string]): seq[string] =
    ## `COMPREPLY` for `words` (`COMP_WORDS`, split as readline would) with
    ## the cursor on the last, in `work`. Readline, not the script, escapes
    ## a path and marks a directory, so neither shows here.
    let driver = root / "drive.bash"
    writeFile(driver, [
      "PATH=" & quoteShell(bin) & ":$PATH",
      "source " & quoteShell(script),
      # `compopt` only runs inside real completion.
      "compopt() { :; }",
      "COMP_WORDS=(" & words.mapIt(quoteShell(it)).join(" ") & ")",
      "COMP_CWORD=" & $words.high,
      "_amdemo_complete",
      """printf '%s\n' "${COMPREPLY[@]}"""",
    ].join("\n") & "\n")
    let (output, code) = execCmdEx(quoteShellCommand([bashExe, driver]), workingDir = work)
    doAssert code == 0, output
    output.splitLines.filterIt(it.len > 0).sorted

  let files = @["alpha.txt", "beta file.txt", "sample.txt", "src", "sub dir"]

  for (words, offered) in [
    (@["amdemo", "cat", ""], files & @["-h", "-n", "--help"]),
    (@["amdemo", "cat", "al"], @["alpha.txt"]),
    (@["amdemo", "cat", "su"], @["sub dir"]),
    (@["amdemo", "cat", "src/"], @["src/main.nim"]),
    (@["amdemo", "cat", "alpha.txt", ""], @["-n"]),
    (@["amdemo", "cd", ""], @["src", "sub dir", "-h", "--help"]),
    (@["amdemo", "tag", ""], @["-h", "--help"]),
    (@["amdemo", "count", ""], files & @["-h", "--help"]),
    (@["amdemo", "-o", "be"], @["beta file.txt"]),
    (@["amdemo", "--out", "=", "be"], @["beta file.txt"]),
    (@["amdemo", "--into", "="], @["src", "sub dir"]),
    (@["amdemo", "--log-level", "="], @["debug", "error", "info", "warn"]),
    (@["amdemo", "deploy", "s"], @["staging"]),
  ]:
    test "completing " & $words & " offers " & $offered:
      if bashExe.len == 0: skip()
      else:
        check complete(words) == offered.sorted

  removeDir(root)

