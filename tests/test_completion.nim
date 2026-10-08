# Tests for dynamic shell completion (`fsm.completeArgs*`, the `__complete`
# entry point, and `completion.genCompletionScript*`) -- see
# `docs/adr/0012-fsm-driven-shell-completion.md` and
# `docs/adr/0022-completion-candidate-help-text.md`.

import std/[os, osproc, sequtils, strutils, unittest]

import argumint

proc values(candidates: seq[CompletionCandidate]): seq[string] =
  candidates.mapIt(it.value)

proc find(candidates: seq[CompletionCandidate], value: string): CompletionCandidate =
  for c in candidates:
    if c.value == value:
      return c
  raise newException(ValueError, "no candidate named " & value)

suite "Option/value completion":
  let spec = (
    logLevel: opt("--log-level=<level>", validator = choice(["debug", "info", "warn", "error"])),
    amend: flag("--amend"),
  )
  let built = newSpec(spec, usage = "[options]")

  test "an option's bare name is offered, not its declared placeholder suffix":
    check built.completeArgs(@["--lo"], "prog").values == @["--log-level"]

  test "a pending option's value is completed from its Choice validator":
    check built.completeArgs(@["--log-level", ""], "prog").values == @["debug", "info", "warn", "error"]

  test "a pending option's value completion is prefix-filtered":
    check built.completeArgs(@["--log-level", "d"], "prog").values == @["debug"]

  test "a pending option's value completion carries no help text":
    for c in built.completeArgs(@["--log-level", ""], "prog"):
      check c.help == ""

  test "a Flag never triggers pending-value completion, even mid-command-line":
    let result = built.completeArgs(@["--amend", ""], "prog").values
    check "--log-level" in result
    check "--amend" in result
    # if --amend had wrongly been treated as pending a value, this would
    # instead be a Choice's candidate values -- neither of which is one
    check "debug" notin result

  test "an unrecognized already-typed word yields no candidates, never raises":
    check built.completeArgs(@["--unknown", ""], "prog") == newSeq[CompletionCandidate]()

suite "End-of-Options Marker is invisible to completion":
  test "-- is never offered as a candidate, even right at the marker's own position":
    let spec = (
      verbose: flag("--verbose"),
      files: args("<file>"),
    )
    let built = newSpec(spec, usage = "[options] -- <file>...")
    # Right after [options] is exhausted, live states include both the
    # repeat-loop-back (more options) and the marker's own transition --
    # neither `--verbose` completions nor `--` itself should ever include
    # a bare "--" candidate, since typing it is never required (ADR 0020
    # point 8).
    check "--" notin built.completeArgs(@[""], "prog").values
    check "--" notin built.completeArgs(@["--verbose", ""], "prog").values

suite "Command completion and subcommand descent":
  let add = (
    files: args("<file>"),
  )
  let commit = (
    message: arg("<message>"),
    amend: flag("--amend"),
  )
  let spec = (
    verbose: flag("--verbose"),
    add: command("add", add),
    commit: command("commit", commit),
  )
  let built = newSpec(spec)

  test "a command's variant is offered by prefix":
    check built.completeArgs(@["comm"], "prog").values == @["commit"]

  test "nothing typed yet offers every top-level option/command":
    let result = built.completeArgs(@[""], "prog").values
    check "--verbose" in result
    check "add" in result
    check "commit" in result

  test "descends into a matched subcommand's own spliced FSM automatically":
    check built.completeArgs(@["commit", "--am"], "prog").values == @["--amend"]

suite "A Command name shadowing a positional value stays live for completion":
  # ADR 0019: "ship" is a declared command name, but the "<file>" Usage
  # Line is a genuinely separate alternative that can also accept it as a
  # literal positional value -- completion after a fully-typed "ship"
  # should still explore both, not just the one Command descended into.
  let ship = (
    name: arg("<name>", validator = choice(["titanic", "bismarck"])),
  )
  let spec = (
    ship: command("ship", ship, usage = "<name>"),
    file: arg("<file>"),
    verbose: flag("--verbose"),
  )
  let built = newSpec(spec, usage = "ship\n<file> [--verbose]")

  test "completion after \"ship\" offers both the nested command's own candidates and what follows a literal <file> value":
    let result = built.completeArgs(@["ship", ""], "prog").values
    check "titanic" in result
    check "bismarck" in result
    check "--verbose" in result

suite "Catch-all repeatability and cycle safety":
  # `--verbose` is explicitly named (so excluded from the catch-all and
  # non-repeatable); `--moored` is reachable only via `[options]` (so
  # repeatable by default, per ADR 0002).
  let spec = (
    verbose: flag("--verbose"),
    moored: flag("--moored"),
  )
  let built = newSpec(spec, usage = "--verbose [options]")

  test "the required option is offered first":
    check built.completeArgs(@[""], "prog").values == @["--verbose"]

  test "a catch-all-only option keeps being offered, and doesn't hang":
    check built.completeArgs(@["--verbose", ""], "prog").values == @["--moored"]
    check built.completeArgs(@["--verbose", "--moored", ""], "prog").values == @["--moored"]
    check built.completeArgs(@["--verbose", "--moored", "--moored", ""], "prog").values == @["--moored"]

  test "an already-consumed, explicitly-named non-repeatable option stops appearing":
    let result = built.completeArgs(@["--verbose", "--moored", ""], "prog").values
    check "--verbose" notin result

suite "FlagOp Alias-aware completion":
  # A Flag's variants partition into FlagOp Alias sets by (op, value) --
  # `Arg.aliases` says so (issue #8) -- so completion must offer only the
  # alias set actually reachable at a given position, not every variant the
  # Arg has anywhere on the usage line. See `fsm.bareVariants`.
  let spec = (
    direction: flag[int](ops = [flagOp("--up", "=", 1), flagOp("--down", "=", -1), flagOp("--left", "=", 2), flagOp("--right", "=", -2)], default = 0, help = ""),
  )
  let built = newSpec(spec, usage = "(--up | --down) (--left | --right)")

  test "only the first position's own alias set is offered before anything is typed":
    check built.completeArgs(@[""], "prog").values == @["--up", "--down"]

  test "satisfying the first position advances to the second, without re-offering the first":
    check built.completeArgs(@["--down", ""], "prog").values == @["--left", "--right"]
    check built.completeArgs(@["--up", ""], "prog").values == @["--left", "--right"]

  test "a plain (non-choice) sequence behaves the same way":
    let spec2 = (
      verbosity: flag[int](ops = [flagOp("-u", "+=", 5), flagOp("-d", "-=", 2)], default = 1, help = "", clamp = clamp(0..10)),
    )
    let built2 = newSpec(spec2, usage = "-u -d")
    check built2.completeArgs(@[""], "prog").values == @["-u"]
    check built2.completeArgs(@["-u", ""], "prog").values == @["-d"]

  test "FlagOp Alias variants stay mutually offered at their one position":
    let spec3 = (
      verbosity: flag("-v, --verbose", default = false, help = ""),
    )
    let built3 = newSpec(spec3, usage = "-v")
    check built3.completeArgs(@[""], "prog").values == @["-v", "--verbose"]

suite "Env-var fallback during completion":
  let spec = (
    port: opt("--port=<port>", env = "ARGUMINT_TEST_COMPLETION_PORT"),
    other: flag("--other"),
  )
  let built = newSpec(spec, usage = "--port=<port> [--other]")

  test "without env, only the still-required option is offered":
    check built.completeArgs(@[""], "prog").values == @["--port"]

  test "with env satisfying the required option, completion advances past it":
    putEnv("ARGUMINT_TEST_COMPLETION_PORT", "9090")
    try:
      check "--other" in built.completeArgs(@[""], "prog").values
    finally:
      delEnv("ARGUMINT_TEST_COMPLETION_PORT")

suite "Hidden args aren't offered (#199)":
  let spec = (
    secret: flag("--secret", hidden = true, help = "Hidden"),
    key: opt("--key=<k>", hidden = true, validator = choice(["a", "b"]), help = "Hidden opt"),
    old: command("old", (x: flag("-x"),), hidden = true, help = "Old"),
    new: command("new", (x: flag("-x"),), help = "New"),
    help: help(),
  )
  let built = newSpec(spec)

  for (words, expected) in [
    (@[""], @["-h", "--help", "new"]),
    (@["--s"], newSeq[string]()),
    (@["o"], newSeq[string]()),
    (@["old", ""], @["-x"]),
    (@["--key", ""], @["a", "b"]),
  ]:
    test "completing " & $words & " offers " & $expected:
      check built.completeArgs(words, "prog").values == expected

  test "a hidden option named in the usage line isn't offered":
    let spec = (
      secret: flag("--secret", hidden = true),
      loud: flag("--loud"),
    )
    check newSpec(spec, usage = "[--secret] [--loud]").completeArgs(@[""], "prog").values == @["--loud"]

  test "a hidden positional's choices aren't offered":
    let spec = (
      mode: arg("<mode>", hidden = true, validator = choice(["fast", "slow"])),
    )
    check newSpec(spec).completeArgs(@[""], "prog").values == newSeq[string]()

  test "hidden args still parse":
    spec.parse(args = @["--secret", "--key", "a", "new"], command = "prog")
    check spec.secret
    check spec.key == "a"
    check spec.new.seen
    spec.parse(args = @["old", "-x"], command = "prog")
    check spec.old.seen

suite "Options after a positional (#197)":
  let deploySpec = (
    env: arg("<env>", validator = choice(["staging", "production"]), help = "Where to deploy"),
    force: flag("-f, --force", help = "Deploy even if checks fail"),
    help: help(),
  )
  let site = newSpec((
    logLevel: opt("--log-level=<level>", validator = choice(["debug", "info"]), help = "How much to log"),
    deploy: command("deploy", deploySpec, help = "Deploy the site"),
    help: help(),
  ))

  for (words, expected) in [
    (@["deploy", ""], @["-h", "--help", "-f", "--force", "staging", "production"]),
    (@["deploy", "staging", ""], @["-f", "--force"]),
    (@["deploy", "staging", "-"], @["-f", "--force"]),
    (@["deploy", "staging", "-f", ""], @["-f", "--force"]),
    (@["--log-level", "debug", "deploy", "staging", ""], @["-f", "--force"]),
    (@["deploy", "staging", "--log-level", ""], newSeq[string]()),
  ]:
    test "completing " & $words & " offers " & $expected:
      check site.completeArgs(words, "site").values == expected

  let file = newSpec((
    brief: flag("-b"),
    n: opt("-n=<n>", validator = choice(["1", "2"])),
    file: arg("<file>"),
  ), usage = "[options] <file>")

  for (words, expected) in [
    (@["in.txt", ""], @["-b", "-n"]),
    (@["in.txt", "-n", ""], @["1", "2"]),
    (@["in.txt", "-b", ""], @["-b", "-n"]),
  ]:
    test "under [options] <file>, completing " & $words & " offers " & $expected:
      check file.completeArgs(words, "prog").values == expected

  let xvy = (
    v: flag("-v"),
    x: arg("<x>"),
    y: arg("<y>"),
  )

  for (usage, words, expected) in [
    ("<x> [-v] <y>", @["a", "b", ""], @["-v"]),
    ("<x> [-v] <y>", @["a", "-v", "b", ""], newSeq[string]()),
    ("[-v] <x> <y>", @["a", ""], @["-v"]),
  ]:
    test "under " & usage & ", completing " & $words & " offers " & $expected:
      check newSpec(xvy, usage = usage).completeArgs(words, "prog").values == expected

  test "a hidden option isn't offered after a positional":
    let spec = (
      secret: flag("--secret", hidden = true),
      file: arg("<file>"),
    )
    check newSpec(spec, usage = "[options] <file>").completeArgs(@["in.txt", ""], "prog").values == newSeq[string]()

suite "Completion candidates carry help text":
  test "an option's completion candidate carries its help text":
    let spec = (
      logLevel: opt("--log-level=<level>", help = "Logging verbosity"),
    )
    let built = newSpec(spec, usage = "[options]")
    check built.completeArgs(@[""], "prog").find("--log-level").help == "Logging verbosity"

  test "a flag's completion candidate carries its help text":
    let spec = (
      verbose: flag("--verbose", help = "Be noisy"),
    )
    let built = newSpec(spec, usage = "[options]")
    check built.completeArgs(@[""], "prog").find("--verbose").help == "Be noisy"

  test "a command's completion candidate carries its help text":
    let sub = (files: args("<file>"))
    let spec = (
      add: command("add", sub, help = "Add files to the index"),
    )
    let built = newSpec(spec)
    check built.completeArgs(@[""], "prog").find("add").help == "Add files to the index"

  test "a flag with divergent per-variant ops annotates its shared help with each variant's Flag Operation Description (#154)":
    let spec = (
      rank: flag[int](ops = [flagOp("--boost", "+=", 5), flagOp("--dampen", "-=", 2)], default = 0, help = "Adjust rank"),
    )
    let built = newSpec(spec, usage = "[options]")
    let candidates = built.completeArgs(@[""], "prog")
    check candidates.find("--boost").help == "Adjust rank [action: Increase by 5]"
    check candidates.find("--dampen").help == "Adjust rank [action: Decrease by 2]"

  test "a variant is described the same way under every usage line that offers it (#154)":
    let spec = (
      rank: flag[int](ops = [flagOp("-b, --boost", "+=", 5), flagOp("-d, --dampen", "-=", 2)], default = 0, help = "Adjust rank"),
    )
    for usage in ["[options]", "--boost", "(--boost | --dampen)"]:
      let candidates = newSpec(spec, usage = usage).completeArgs(@[""], "prog")
      check candidates.find("-b").help == "Adjust rank [action: Increase by 5]"
      check candidates.find("--boost").help == "Adjust rank [action: Increase by 5]"
      if usage != "--boost":
        check candidates.find("--dampen").help == "Adjust rank [action: Decrease by 2]"

  test "with no short help, a divergent variant completes as its bare Flag Operation Description, never its long help (#154)":
    let spec = (
      rank: flag[int](ops = [flagOp("--boost", "+=", 5), flagOp("--dampen", "-=", 2)], default = 0,
        help = (short: "", long: "Adjust the rank\nat length")),
    )
    let candidates = newSpec(spec, usage = "[options]").completeArgs(@[""], "prog")
    check candidates.find("--boost").help == "Increase by 5"
    check candidates.find("--dampen").help == "Decrease by 2"

  test "a divergent variantDesc is flattened to one line too":
    let spec = (
      rank: flag[int](ops = [flagOp("--boost", "+=", 5, help = "Raise\n  the rank"),
        flagOp("--dampen", "-=", 2)], default = 0),
    )
    let built = newSpec(spec, usage = "[options]")
    check built.completeArgs(@[""], "prog").find("--boost").help == "Raise the rank"

  test "a tab in help text becomes a space":
    let built = newSpec((verbose: flag("--verbose", help = "Be\tnoisy")), usage = "[options]")
    check built.completeArgs(@[""], "prog").find("--verbose").help == "Be noisy"

  test "help text reads as it would with no styler: Help Markup's ticks kept, escapes collapsed":
    let spec = (
      verbose: flag("--verbose", help = "Like `-v`, not ``-q``"),
    )
    let built = newSpec(spec, usage = "[options]")
    check built.completeArgs(@[""], "prog").find("--verbose").help == "Like `-v`, not `-q`"

  test "an option's own help never leaks onto its Choice-validator value candidates":
    let spec = (
      logLevel: opt("--log-level=<level>", help = "Logging verbosity",
        validator = choice(["debug", "info", "warn", "error"])),
    )
    let built = newSpec(spec, usage = "[options]")
    let candidates = built.completeArgs(@["--log-level", ""], "prog")
    check candidates.len > 0
    for c in candidates:
      check c.help == ""

suite "__complete entry point":
  test "raises CompletionError with tab-separated candidate/help lines and fires no hooks":
    var hookFired = false
    let spec = (
      logLevel: opt("--log-level=<level>", validator = choice(["debug", "info", "warn", "error"])),
    )
    let built = newSpec(spec, usage = "[options]")
    built.before = proc(info: HookInfo) = hookFired = true
    built.action = proc(info: HookInfo) = hookFired = true
    built.after = proc(info: HookInfo) = hookFired = true

    var caught = ""
    try:
      built.parse(args = @["__complete", "--lo"], command = "test")
    except CompletionError as e:
      caught = e.msg
    check caught == "--log-level\t"
    check not hookFired

  test "a candidate's help text rides along after its own tab":
    let spec = (
      logLevel: opt("--log-level=<level>", help = "Logging verbosity"),
    )
    let built = newSpec(spec, usage = "[options]")
    var caught = ""
    try:
      built.parse(args = @["__complete", "--lo"], command = "test")
    except CompletionError as e:
      caught = e.msg
    check caught == "--log-level\tLogging verbosity"

  test "multi-line help is its first paragraph on the candidate's own line":
    let spec = (
      level: opt("--level=<n>", help = "First line\nsecond `--level`\n\nMore."),
      mode: opt("--mode=<m>", help = """
        Picks a mode.

        Modes:
        - fast"""),
    )
    let built = newSpec(spec, usage = "[options]")
    var caught = ""
    try:
      built.parse(args = @["__complete", "--"], command = "test")
    except CompletionError as e:
      caught = e.msg
    check caught.splitLines == @[
      "--level\tFirst line second `--level`", "--mode\tPicks a mode."]

suite "genCompletionScript":
  let spec = (
    logLevel: opt("--log-level=<level>", validator = choice(["debug", "info", "warn", "error"])),
  )
  let built = newSpec(spec, usage = "[options]")

  test "every shell's script mentions the binary name and the __complete trigger":
    for shell in Shell:
      let script = built.completionScript(shell, "mycli")
      check "mycli" in script
      check "__complete" in script

  test "bash strips help text before offering candidates, since it has no description slot":
    check "cut -f1" in built.completionScript(bash, "mycli")

  test "zsh renders help text via compadd -d":
    check "compadd -d" in built.completionScript(zsh, "mycli")

proc bashComplete(script: string, words: seq[string], cword: int): tuple[forwarded, reply: seq[string]] =
  ## Runs `script`'s bash function on `words` (`COMP_WORDS`, binary name
  ## first) with the cursor on `words[cword]`. A stub `mycli` records what
  ## the script forwards to `__complete` and offers `debug` and `info`.
  let path = getTempDir() / "argumint_test_complete.bash"
  writeFile(path, script & [
    """mycli() { shift; printf 'FWD:%s\n' "$@" >&2; printf 'debug\t\ninfo\t\n'; }""",
    "COMP_WORDS=(" & words.mapIt(quoteShell(it)).join(" ") & ")",
    "COMP_CWORD=" & $cword,
    "_mycli_complete",
    """printf 'REPLY:%s\n' "${COMPREPLY[@]}"""",
  ].join("\n") & "\n")
  defer: removeFile(path)
  let (output, code) = execCmdEx("bash " & quoteShell(path) & " 2>&1")
  doAssert code == 0, output
  for line in output.splitLines:
    if line.startsWith("FWD:"): result.forwarded.add line[4 .. ^1]
    elif line.startsWith("REPLY:") and line.len > 6: result.reply.add line[6 .. ^1]

suite "bash script forwards what the user typed (#198)":
  let script = newSpec((
    logLevel: opt("--log-level=<level>", validator = choice(["debug", "info"])),
  ), usage = "[options]").completionScript(bash, "mycli")

  # bash's COMP_WORDBREAKS splits `--log-level=de` into `--log-level`, `=`,
  # `de`.
  for (words, cword, forwarded, reply) in [
    (@["mycli", "--log-level", "="], 2, @["--log-level", ""], @["debug", "info"]),
    (@["mycli", "--log-level", "=", "de"], 3, @["--log-level", "de"], @["debug"]),
    (@["mycli", "--log-level", ":"], 2, @["--log-level", ""], @["debug", "info"]),
    (@["mycli", "--log-level", ":", "de"], 3, @["--log-level", "de"], @["debug"]),
    (@["mycli", "--log-level", ""], 2, @["--log-level", ""], @["debug", "info"]),
    (@["mycli", "--log-level", "=", "info", ""], 4, @["--log-level", "info", ""], @["debug", "info"]),
    (@["mycli", "d", "cat"], 1, @["d"], @["debug"]),
    (@["mycli", "a", "=", ""], 3, @["a", "=", ""], @["debug", "info"]),
    (@["mycli", "a", "="], 2, @["a", "="], newSeq[string]()),
  ]:
    test "completing " & $words & " at " & $cword & " forwards " & $forwarded:
      # On Windows, `bash` may be WSL's, which can't read a Windows path.
      if defined(windows) or findExe("bash").len == 0: skip()
      else:
        let got = bashComplete(script, words, cword)
        check got.forwarded == forwarded
        check got.reply == reply
