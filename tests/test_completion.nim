# Tests for dynamic shell completion (`completion.resolveCompletion*`, the
# `__complete` wire format from `completion.reply*` and the entry point in
# `parse*`, and `completion.genCompletionScript*`) -- see
# `docs/adr/0012-fsm-driven-shell-completion.md` and
# `docs/adr/0022-completion-candidate-help-text.md`.

import std/[algorithm, options, os, osproc, sequtils, strutils, sugar,
  unittest]

import argumint
import argumint/walk/completion, argumint/help
from argumint/core/backend import CompletionCandidate, fills, paths, patterns,
  run

type
  MemSource = ref object of ConfigSource
    data: seq[(ConfigKey, seq[string])]

method lookup(self: MemSource, key: ConfigKey): Option[seq[string]] =
  for (k, v) in self.data:
    if k == key:
      return some(v)

type
  CountingSource = ref object of MemSource
    lookups: int

method lookup(self: CountingSource, key: ConfigKey): Option[seq[string]] =
  inc self.lookups
  procCall MemSource(self).lookup(key)

proc completeArgs(spec: Spec, words: seq[string], command: string): seq[CompletionCandidate] =
  spec.resolveCompletion(words, command).candidates

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

suite "A help filter doesn't change completion (#316)":
  test "an Arg the help formatter filters out is still offered":
    let format = opt("--format=<fmt>", validator = choice(["json", "yaml"]),
      help = "Output format")
    proc withoutFormat(ctx: HelpContext): string =
      formatColumn(ctx.filter((arg) => arg != Arg(format)))
    let spec = newSpec((format: format, help: help(formatter = withoutFormat)),
      settings = newSpecSettings(style = nil))
    check "--format" notin spec.genHelp("prog", withoutFormat)
    check spec.completeArgs(@[""], "prog").values ==
      @["-h", "--help", "--format"]
    check spec.completeArgs(@["--format", ""], "prog").values ==
      @["json", "yaml"]

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

proc wire(spec: Spec, words: varargs[string]): seq[string] =
  ## `__complete`'s output for `words`, one line each -- the candidates, then
  ## the directive.
  spec.reply(@words, "site").splitLines

suite "Path completion directive (#200)":
  let site = newSpec((
    cat: command("cat", (file: arg("<file>"), n: flag("-n"), help: help()), help = "Print a file"),
    cd: command("cd", (dir: arg("<dir>", complete = Dirs), help: help()), help = "Change directory"),
    tag: command("tag", (name: arg("<name>", complete = None), help: help()), help = "Tag it"),
    count: command("count", (count: arg[int]("<count>"), help: help()), help = "Count"),
    output: opt("-o, --out=<file>"),
    into: opt("--into=<dir>", complete = Dirs),
    logLevel: opt("--log-level=<level>", validator = choice(["debug", "info"])),
    completion: command("completion", (
      shell: arg("<shell>", validator = choice(["bash", "zsh", "fish"])),
    ), help = "Print a script"),
    help: help(),
  ))

  for (words, directive) in [
    (@["cat", ""], ":files"),
    (@["cat", "al"], ":files"),
    (@["cat", "alpha.txt", ""], ":"),
    (@["cd", ""], ":dirs"),
    (@["tag", ""], ":"),
    (@["count", ""], ":files"),
    (@["-o", "be"], ":files"),
    (@["--into", ""], ":dirs"),
    (@["--log-level", ""], ":"),
    (@["completion", "f"], ":"),
    (@["cat", "-n", ""], ":files"),
  ]:
    test "completing " & $words & " ends with " & directive:
      check site.wire(words)[^1] == directive

  test "options are still offered beside files":
    check site.wire("cat", "") == @["-h\tDisplay this help message",
      "--help\tDisplay this help message", "-n\t", ":files"]

  test "an empty result is the directive alone":
    check site.wire("cat", "alpha.txt", "zz") == @[":"]

  test "choice values replace the file fallback":
    let spec = newSpec((mode: arg("<mode>", validator = choice(["fast", "slow"])),))
    check spec.wire("") == @["fast\t", "slow\t", ":"]

  test "Files beats Dirs across Usage Lines":
    let spec = newSpec((
      file: arg("<file>"),
      dir: arg("<dir>", complete = Dirs),
    ), usage = "<file>\n<dir>")
    check spec.wire("")[^1] == ":files"

  test "Dirs beats None across Usage Lines":
    let spec = newSpec((
      dir: arg("<dir>", complete = Dirs),
      name: arg("<name>", complete = None),
    ), usage = "<dir>\n<name>")
    check spec.wire("")[^1] == ":dirs"

  test "a hidden positional offers no paths":
    let spec = newSpec((file: arg("<file>", hidden = true),))
    check spec.wire("") == @[":"]

  test "a typed option's value falls back to its own paths after a positional":
    let spec = newSpec((
      into: opt("--into=<dir>", complete = Dirs),
      file: arg("<file>", complete = None),
    ), usage = "[options] <file>")
    check spec.wire("x", "--into", "")[^1] == ":dirs"

suite "Completers (#215)":
  test "a completer's values are offered, with no paths":
    let spec = newSpec((branch: arg("<branch>", complete = proc (ctx: CompletionContext): Offer =
      offer(["main", "dev"])),))
    check spec.wire("") == @["main\t", "dev\t", ":"]

  test "a completer's values are filtered by the word being completed":
    let spec = newSpec((branch: arg("<branch>", complete = proc (ctx: CompletionContext): Offer =
      offer(["main", "dev", "docs"])),))
    check spec.wire("d") == @["dev\t", "docs\t", ":"]

  test "a completer can ask for paths beside its values":
    let spec = newSpec((src: arg("<src>", complete = proc (ctx: CompletionContext): Offer =
      offer(["-"], paths = Files)),))
    check spec.wire("") == @["-\t", ":files"]

  test "a completer answers a pending option's value":
    let spec = newSpec((host: opt("--host=<host>", complete = proc (ctx: CompletionContext): Offer =
      offer(["alpha", "beta"])),), usage = "[options]")
    check spec.wire("--host", "") == @["alpha\t", "beta\t", ":"]

  test "a completer is told the word being completed":
    var told: seq[string]
    let spec = newSpec((host: opt("--host=<host>", complete = proc (ctx: CompletionContext): Offer =
      told.add ctx.word
      offer(newSeq[string]())), file: arg("<file>")), usage = "[options] <file>")
    discard spec.wire("--host", "al")
    discard spec.wire("x", "--host", "be")
    check told == @["al", "be"]

  test "a completer's descriptions ride along, each on one line":
    let spec = newSpec((host: arg("<host>", complete = proc (ctx: CompletionContext): Offer =
      offer([("alpha", "The first\nhost.\n\nMore."), ("beta", "Tab\there"), ("gamma", "")])),))
    check spec.wire("") == @["alpha\tThe first host.", "beta\tTab here", "gamma\t", ":"]

  test "a completer replaces a choice's values":
    let spec = newSpec((mode: arg("<mode>", validator = choice(["fast", "slow"]),
      complete = proc (ctx: CompletionContext): Offer = offer(["medium"])),))
    check spec.wire("") == @["medium\t", ":"]

  test "an explicit Dirs replaces a choice's values":
    let spec = newSpec((mode: arg("<mode>", validator = choice(["fast", "slow"]),
      complete = Dirs),))
    check spec.wire("") == @[":dirs"]

  test "by default an enum-typed Arg offers its values":
    type Speed = enum fast, slow
    let spec = newSpec((speed: arg[Speed]("<speed>"),))
    check spec.wire("") == @["fast\t", "slow\t", ":"]

  test "a completer that raises offers nothing":
    let spec = newSpec((host: arg("<host>", complete = proc (ctx: CompletionContext): Offer =
      raise newException(IOError, "offline")),))
    check spec.wire("") == @[":"]

  test "a completer runs once per Tab, however many branches reach it":
    var calls = 0
    let spec = newSpec((
      host: arg("<host>", complete = proc (ctx: CompletionContext): Offer =
        inc calls
        offer(["alpha"])),
      verbose: flag("-v"),
      help: help(),
    ), usage = "[-v] <host>\n[-v] [-h] <host>")
    check spec.wire("") == @["-v\t", "-h\tDisplay this help message",
      "--help\tDisplay this help message", "alpha\t", ":"]
    check calls == 1

  test "a hidden option's completer runs only once the option is typed":
    var calls = 0
    let spec = newSpec((key: opt("--key=<key>", hidden = true,
      complete = proc (ctx: CompletionContext): Offer =
        inc calls
        offer(["x"])),), usage = "[options]")
    check spec.wire("") == @[":"]
    check calls == 0
    check spec.wire("--key", "") == @["x\t", ":"]
    check calls == 1

  test "a hidden Arg's completer never runs":
    var calls = 0
    let spec = newSpec((host: arg("<host>", hidden = true,
      complete = proc (ctx: CompletionContext): Offer =
        inc calls
        offer(["alpha"])),))
    check spec.wire("") == @[":"]
    check calls == 0

proc namedCompleter(ctx: CompletionContext): Offer =
  offer(["named"])

var globalHosts = @["global"]

suite "What converts to a Completer (#215)":
  test "every PathCompletion, on every value constructor":
    for c in [Files, Dirs, None]:
      check arg("<a>", complete = c).complete.fills == false
      check arg[int]("<a>", complete = c).complete.fills == false
      check args("<a>", complete = c).complete.fills == false
      check args[int]("<a>", complete = c).complete.fills == false
      check opt("--a", complete = c).complete.fills == false
      check opt[int]("--a", complete = c).complete.fills == false
      check opts("--a", complete = c).complete.fills == false
      check opts[int]("--a", complete = c).complete.fills == false

  test "proc literals, named procs, stored procs and effect-annotated procs":
    let local = @["local"]
    let stored: CompleterProc = proc (ctx: CompletionContext): Offer = offer(["stored"])
    for (spec, expected) in [
      (newSpec((a: arg("<a>", complete = proc (ctx: CompletionContext): Offer =
        offer(["none"])),)), "none"),
      (newSpec((a: arg[int]("<a>", complete = proc (ctx: CompletionContext): Offer =
        offer(globalHosts)),)), "global"),
      (newSpec((a: arg("<a>", complete = proc (ctx: CompletionContext): Offer =
        offer(local)),)), "local"),
      (newSpec((a: arg[int]("<a>", complete = namedCompleter),)), "named"),
      (newSpec((a: arg("<a>", complete = stored),)), "stored"),
      (newSpec((a: arg("<a>", complete = proc (ctx: CompletionContext): Offer
        {.raises: [], gcsafe.} = offer(["fx"])),)), "fx"),
    ]:
      check spec.wire("") == @[expected & "\t", ":"]

  test "`$` names a Completer's kind":
    check $arg("<a>").Arg.complete == "Completer(default)"
    check $arg("<a>", complete = Files).Arg.complete == "Completer(fixed)"
    check $arg("<a>", complete = namedCompleter).Arg.complete == "Completer(proc)"

  test "a proc of another shape doesn't convert":
    check not compiles(arg("<a>", complete = proc (word: string): seq[string] = @[]))

type
  Log = ref object
    ## What a fill test's completer saw, and whether a hook ran.
    seen: seq[int]
    hookRan: bool

proc gitSpec(log: Log, settings = newSpecSettings(style = nil), seed = ""): Spec =
  ## `--repo` at the root, pre-seeded to `seed` if given, read by the
  ## completer of `checkout <branch>` and of `--tag`. A `--repo` of 13
  ## makes the completer raise.
  let repo = opt[int]("--repo=<n>", env = "ARGUMINT_TEST_REPO", configKey = "repo")
  if seed.len > 0:
    repo.parse(seed, seenBy = some(byCli))
  let byRepo = proc (ctx: CompletionContext): Offer =
    log.seen.add repo.get
    if repo.get == 13:
      raise newException(IOError, "unlucky")
    offer(["main"])
  newSpec((
    repo: repo,
    tag: opt("--tag=<tag>", complete = byRepo),
    checkout: command("checkout", (branch: arg("<branch>", complete = byRepo),),
      before = proc (spec: tuple[branch: ValueArg[string]], info: HookInfo) =
        log.hookRan = true),
  ), usage = "[options] checkout\n[options]", settings = settings)

suite "Completers see earlier values (#215)":
  setup:
    delEnv "ARGUMINT_TEST_REPO"
  teardown:
    delEnv "ARGUMINT_TEST_REPO"

  for (words, seen) in [
    (@["--repo", "7", "checkout", ""], 7),
    (@["checkout", "r"], 0),
    (@["--repo", "7", "--repo", "8", "checkout", ""], 8),
    (@["--repo", "nope", "checkout", ""], 0),
    (@["--repo", "7", "--tag", ""], 7),
    (@["--repo=7", "--tag", ""], 7),
  ]:
    test "completing " & $words & " shows the completer --repo " & $seen:
      let log = Log()
      check gitSpec(log).wire(words)[^1] == ":"
      check log.seen == @[seen]
      check not log.hookRan

  test "an env var reaches the completer":
    putEnv "ARGUMINT_TEST_REPO", "5"
    let log = Log()
    discard gitSpec(log).wire("checkout", "")
    check log.seen == @[5]

  test "a Config Source reaches the completer":
    let log = Log()
    let source = MemSource(data: @[(configKey("repo"), @["6"])])
    discard gitSpec(log, newSpecSettings(style = nil,
      configSources = @[ConfigSource source])).wire("checkout", "")
    check log.seen == @[6]

  test "an option typed after a positional sees earlier values":
    var seen: seq[int]
    let repo = opt[int]("--repo=<n>")
    let spec = newSpec((
      repo: repo,
      file: arg("<file>", complete = None),
      tag: opt("--tag=<tag>", complete = proc (ctx: CompletionContext): Offer =
        seen.add repo.get
        offer(newSeq[string]())),
    ), usage = "[options] <file>")
    check spec.wire("--repo", "7", "x", "--tag", "") == @[":"]
    check seen == @[7]

  test "an env var below the root reaches the completer":
    putEnv "ARGUMINT_TEST_REPO", "3"
    var seen: seq[int]
    let depth = opt[int]("--depth=<n>", env = "ARGUMINT_TEST_REPO")
    let spec = newSpec((clone: command("clone", (depth: depth,
      url: arg("<url>", complete = proc (ctx: CompletionContext): Offer =
        seen.add depth.get
        offer(newSeq[string]())))),))
    discard spec.wire("clone", "")
    check seen == @[3]

  test "a completer that raises after the fill offers nothing":
    let log = Log()
    check gitSpec(log).wire("--repo", "13", "checkout", "") == @[":"]
    check log.seen == @[13]

  test "a pre-seeded value survives the fill":
    let log = Log()
    discard gitSpec(log, seed = "99").wire("checkout", "")
    check log.seen == @[99]

  test "an oversupplied env var supplies nothing, as in parse":
    putEnv "ARGUMINT_TEST_TAGS", "a:b:c"
    defer: delEnv "ARGUMINT_TEST_TAGS"
    var seen: seq[seq[string]]
    let tags = opts("--tag=<t>", env = "ARGUMINT_TEST_TAGS")
    let spec = newSpec((tags: tags,
      host: arg("<host>", complete = proc (ctx: CompletionContext): Offer =
        seen.add tags.get
        offer(newSeq[string]())),
    ), usage = "--tag=<t> <host>")
    discard spec.wire("")
    check seen == @[newSeq[string]()]

  test "the fill looks up no Config Source the walk already did":
    let source = CountingSource(data: @[(configKey("repo"), @["6"])])
    var seen: seq[int]
    let repo = opt[int]("--repo=<n>", configKey = "repo")
    let spec = newSpec((repo: repo,
      host: arg("<host>", complete = proc (ctx: CompletionContext): Offer =
        seen.add repo.get
        offer(newSeq[string]())),
    ), usage = "--repo=<n> <host>", settings = newSpecSettings(style = nil,
      configSources = @[ConfigSource source]))
    discard spec.wire("")
    check seen == @[6]
    check source.lookups == 1

  test "a value that fails is skipped, the rest are stored":
    var seen: seq[seq[int]]
    let tags = opts[int]("--tag=<t>")
    let spec = newSpec((tags: tags,
      host: arg("<host>", complete = proc (ctx: CompletionContext): Offer =
        seen.add tags.get
        offer(newSeq[string]())),
    ), usage = "[--tag=<t>...] <host>")
    discard spec.wire("--tag=1", "--tag=x", "--tag=2", "")
    check seen == @[@[1, 2]]

  test "a command-line value that fails closes the env var to it":
    # The user did supply `--repo`, so no weaker tier steps in -- ADR 0077.
    putEnv "ARGUMINT_TEST_REPO", "7"
    let log = Log()
    discard gitSpec(log).wire("--repo", "nope", "checkout", "")
    check log.seen == @[0]

  test "a store failure other than a bad value propagates from the fill":
    # Only conversion and validation failures are skipped -- ADR 0077.
    let boom = opt[int]("--boom=<n>", validator = argumint.check(proc (n: int): bool =
      raise newException(IOError, "disk on fire")))
    let spec = newSpec((boom: boom,
      host: arg("<host>", complete = proc (ctx: CompletionContext): Offer =
        offer(newSeq[string]())),
    ), usage = "[--boom=<n>] <host>")
    expect IOError:
      discard spec.wire("--boom=1", "")

  test "an ambiguous grammar binds the value as parse would":
    var seen: seq[(string, string)]
    let user = arg("<user>")
    let org = arg("<org>")
    let spec = newSpec((user: user, org: org,
      repo: arg("<repo>", complete = proc (ctx: CompletionContext): Offer =
        seen.add (user.get, org.get)
        offer(newSeq[string]())),
    ), usage = "(<user> | <org>) <repo>")
    discard spec.wire("acme", "")
    check seen == @[("acme", "")]

  test "the fill happens once, though two completers are reachable":
    var seen: seq[seq[string]]
    let tags = opts("--tag=<tag>")
    let byTags = proc (ctx: CompletionContext): Offer =
      seen.add tags.get
      offer(newSeq[string]())
    let spec = newSpec((
      tags: tags,
      file: arg("<file>", complete = byTags),
      dir: arg("<dir>", complete = byTags),
    ), usage = "[options] <file>\n[options] <dir>")
    discard spec.wire("--tag", "a", "")
    check seen == @[@["a"], @["a"]]

  test "an args completer reads its own earlier values":
    var seen: seq[seq[string]]
    let files = args("<file>")
    files.complete = proc (ctx: CompletionContext): Offer =
      seen.add files.get
      offer(newSeq[string]())
    let spec = newSpec((files: files,))
    discard spec.wire("a", "b", "")
    check seen == @[@["a", "b"]]

  # The walk's probes read Config Sources anyway -- see architecture.md,
  # "Resolving candidates".
  test "a PathCompletion completer fills nothing":
    putEnv "ARGUMINT_TEST_REPO", "5"
    let repo = opt[int]("--repo=<n>", env = "ARGUMINT_TEST_REPO", configKey = "repo")
    let source = MemSource(data: @[(configKey("repo"), @["6"])])
    let spec = newSpec((repo: repo, dir: arg("<dir>", complete = Dirs)),
      usage = "[options] <dir>", settings = newSpecSettings(style = nil,
        configSources = @[ConfigSource source]))
    check spec.wire("") == @["--repo\t", ":dirs"]
    check repo.seenBy == byNone

proc label(c: Completer): string =
  ## Names a fixed Completer for a test title.
  let o = c.run(CompletionContext())
  result = $o.paths
  if o.patterns.len > 0:
    result.add " " & $o.patterns

suite "File patterns (#214)":
  test "files' patterns follow the directive, on every value constructor":
    let spec = newSpec((
      a: arg("<a>", complete = files("*.toml", "*.ini")),
      b: args[int]("<b>", complete = files("*.toml", "*.ini")),
      c: opt("--cc=<c>", complete = files("*.toml", "*.ini")),
      d: opts[int]("--dd=<d>", complete = files("*.toml", "*.ini")),
    ), usage = "[options] <a> <b>...")
    check spec.wire("") == @["--cc\t", "--dd\t", ":files\t*.toml\t*.ini"]
    check spec.wire("x", "")[^1] == ":files\t*.toml\t*.ini"
    check spec.wire("--cc", "") == @[":files\t*.toml\t*.ini"]
    check spec.wire("--dd", "") == @[":files\t*.toml\t*.ini"]

  test "files with no patterns is Files":
    let spec = newSpec((a: arg("<a>", complete = files()),))
    check spec.wire("") == @[":files"]

  test "files fills nothing":
    putEnv "ARGUMINT_TEST_REPO", "5"
    defer: delEnv "ARGUMINT_TEST_REPO"
    let repo = opt[int]("--repo=<n>", env = "ARGUMINT_TEST_REPO")
    let spec = newSpec((repo: repo, config: arg("<config>", complete = files("*.toml"))),
      usage = "[options] <config>")
    check spec.wire("") == @["--repo\t", ":files\t*.toml"]
    check repo.seenBy == byNone

  test "a completer can filter the files beside its values":
    let spec = newSpec((patch: arg("<patch>", complete = proc (ctx: CompletionContext): Offer =
      offer(["a"], paths = Files, patterns = ["*.patch"])),))
    check spec.wire("") == @["a\t", ":files\t*.patch"]
    let described = newSpec((patch: arg("<patch>", complete = proc (ctx: CompletionContext): Offer =
      offer([("a", "Latest")], paths = Files, patterns = ["*.patch"])),))
    check described.wire("") == @["a\tLatest", ":files\t*.patch"]

  test "files replaces a choice's values":
    let spec = newSpec((mode: arg("<mode>", validator = choice(["fast", "slow"]),
      complete = files("*.toml")),))
    check spec.wire("") == @[":files\t*.toml"]

  test "patterns need Files, and no tab or newline":
    expect Defect: discard offer(["a"], paths = Dirs, patterns = ["*.x"])
    expect Defect: discard offer(["a"], patterns = ["*.x"])
    expect Defect: discard offer([("a", "")], paths = Dirs, patterns = ["*.x"])
    expect Defect: discard offer(["a"], paths = Files, patterns = ["*\t.x"])
    expect Defect: discard files("*.x", "*\n.y")
    expect Defect: discard files("*\t.x")

  # One Usage Line per Completer, so the frontier holds both.
  for (first, second, directive) in [
    (files("*.toml"), toCompleter(Files), ":files"),
    (toCompleter(Files), files("*.toml"), ":files"),
    (files("*.toml", "*.ini"), files("*.ini", "*.patch"), ":files\t*.toml\t*.ini\t*.patch"),
    (files("*.toml"), toCompleter(Dirs), ":files\t*.toml"),
    (toCompleter(Dirs), files("*.toml"), ":files\t*.toml"),
    (toCompleter(None), files("*.toml"), ":files\t*.toml"),
  ]:
    test "Usage Lines offering " & first.label & " and " & second.label & " end with " & directive.escape:
      let spec = newSpec((a: arg("<a>", complete = first), b: arg("<b>", complete = second)),
        usage = "<a>\n<b>")
      check spec.wire("")[^1] == directive

  # `cmd --xx` is both the command's `--xx` and `<name>`'s, so both await
  # a value.
  for (parent, child, directive) in [
    (files("*.toml"), toCompleter(Files), ":files"),
    (toCompleter(Files), files("*.toml"), ":files"),
    (files("*.toml", "*.ini"), files("*.ini", "*.patch"), ":files\t*.ini\t*.patch\t*.toml"),
    (files("*.toml"), toCompleter(Dirs), ":files\t*.toml"),
    (toCompleter(Dirs), files("*.toml"), ":files\t*.toml"),
    (toCompleter(None), files("*.toml"), ":files\t*.toml"),
  ]:
    test "pending options offering " & parent.label & " and " & child.label & " end with " & directive.escape:
      let spec = newSpec((
        name: arg("<name>"),
        xx: opt("--xx=<a>", complete = parent),
        cmd: command("cmd", (xx: opt("--xx=<b>", complete = child),), usage = "[options]"),
      ), usage = "cmd\n<name> [options]")
      check spec.wire("cmd", "--xx", "")[^1] == directive

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
    check caught == "--log-level\t\n:"
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
    check caught == "--log-level\tLogging verbosity\n:"

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
      "--level\tFirst line second `--level`", "--mode\tPicks a mode.", ":"]

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

proc bashComplete(script: string, words: seq[string], cword: int,
    directive = ":"): tuple[forwarded, reply: seq[string]] =
  ## Runs `script`'s bash function on `words` (`COMP_WORDS`, binary name
  ## first) with the cursor on `words[cword]`, in a directory holding
  ## `alpha.txt` and `sub/`. A stub `mycli` records what the script forwards
  ## to `__complete`, and offers `debug` and `info`, then `directive`.
  let dir = getTempDir() / "argumint_test_complete"
  createDir(dir / "sub")
  writeFile(dir / "alpha.txt", "")
  defer: removeDir(dir)
  let path = dir / "complete.bash"
  writeFile(path, script & [
    """mycli() { shift; printf 'FWD:%s\n' "$@" >&2; printf 'debug\t\ninfo\t\n%s\n' """ &
      quoteShell(directive) & "; }",
    "cd " & quoteShell(dir),
    "COMP_WORDS=(" & words.mapIt(quoteShell(it)).join(" ") & ")",
    "COMP_CWORD=" & $cword,
    # `compopt` only runs inside real completion.
    "compopt() { :; }",
    "_mycli_complete",
    """printf 'REPLY:%s\n' "${COMPREPLY[@]}"""",
  ].join("\n") & "\n")
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

suite "bash script adds the paths __complete asks for (#200)":
  let script = newSpec((
    file: arg("<file>"),
  )).completionScript(bash, "mycli")

  for (cur, directive, reply) in [
    ("", ":files", @["debug", "info", "alpha.txt", "complete.bash", "sub"]),
    ("al", ":files", @["alpha.txt"]),
    ("", ":dirs", @["debug", "info", "sub"]),
    ("s", ":dirs", @["sub"]),
    ("", ":", @["debug", "info"]),
  ]:
    test "completing " & cur.escape & " with " & directive & " offers " & $reply:
      if defined(windows) or findExe("bash").len == 0: skip()
      else:
        check bashComplete(script, @["mycli", cur], 1, directive).reply.sorted == reply.sorted


suite "agreement with help (ADR 0063)":
  test "a divergent flag's description reads as help's row does":
    let spec = newSpec((
      rank: flag[int](ops = [flagOp("--boost", "+=", 5), flagOp("--dampen", "-=", 2)],
        help = "Adjust rank"),
      help: help()), usage = "[options]", settings = newSpecSettings(style = nil))
    let described = spec.resolveCompletion(@["--bo"], "prog").candidates
    check described == @[("--boost", "Adjust rank [action: Increase by 5]")]
    let row = spec.genHelp("prog").splitLines.filterIt(it.strip.startsWith("--boost"))
    check row.len == 1 and row[0].endsWith(" " & described[0].help)
