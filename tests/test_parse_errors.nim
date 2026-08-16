# What a failed parse says. See docs/adr/0035-parse-failure-reporting.md.
#
# Organised by the acceptance criteria in issue #20.

import std/[sequtils, strutils, unittest]

import argumint

proc complaints(msg: string): seq[string] =
  ## Just the bulleted complaint lines, without the usage block below them.
  for line in msg.splitLines:
    if line.startsWith("  - "):
      result.add line[4 .. ^1]

template failure(body: untyped): string =
  ## The message `body` fails with. Fails the test if it parses.
  var caught = ""
  try:
    body
    check false # unreachable
  except ParseError as e:
    caught = e.msg
  caught

proc baseSpec(): auto =
  ## Issue #20's own baseline spec.
  (port: opt("--port=<n>", default = 80, help = ""),
   verbose: flag("-v", help = ""),
   help: help())

proc commandSpec(): auto =
  ## A required command alongside an option reached only through `[options]`.
  let sub = (x: arg[int]("<x>", default = 0, help = ""), help: help())
  (add: command("add", sub, usage = "<x>", help = ""),
   port: opt("--port=<n>", default = 8080, help = ""),
   help: help())

suite "a `missing option` complaint is only ever about a genuine deficiency":
  test "an option reached through the [options] catch-all is never reported missing":
    let msg = failure: baseSpec().parse(args = @["stray"], command = "app", usage = "[options]")
    check "--port" notin msg.complaints.join("\n")
    check "-v" notin msg.complaints.join("\n")

  test "an option that was supplied is never reported missing":
    # Supplied, valid, required by no usage line -- and still reported
    # missing before this.
    let msg = failure: commandSpec().parse(args = @["--port", "9090"], command = "app")
    check msg.complaints == @["missing command: add"]

  test "a usage line wanting two occurrences still reports the second missing":
    # A MatchTable membership test can't tell one occurrence from two, and
    # suppressing on it empties the list entirely. See ADR 0035.
    let spec = (foo: opts("--foo=<v>", help = ""),)
    let msg = failure:
      spec.parse(usage = "--foo=<v> --foo=<v>", args = @["--foo", "a"], command = "app")
    check msg.complaints == @["missing option: --foo"]

  test "and the same for a repeated Flag position":
    let spec = (foo: flag[int](ops = [flagOp("--foo", "+=", 1)], default = 0, help = ""),)
    let msg = failure: spec.parse(usage = "--foo --foo", args = @["--foo"], command = "app")
    check msg.complaints == @["missing option: --foo"]

  test "both occurrences supplied still parses":
    let spec = (foo: opts("--foo=<v>", help = ""),)
    spec.parse(usage = "--foo=<v> --foo=<v>", args = @["--foo", "a", "--foo", "b"], command = "app")
    check spec.foo == @["a", "b"]

  test "a `missing option` complaint is suppressed once something is named":
    let msg = failure: baseSpec().parse(args = @["--nope"], command = "app", usage = "[options]")
    check msg.complaints == @["unrecognized option: --nope"]

  test "ADR 0034's starved-option complaint counts as naming a token":
    # Passes only if suppression keys on the complaint, not its wording.
    let spec = (port: opt("--port=<n>", default = 0, help = ""), help: help())
    let msg = failure: spec.parse(args = @["--port"], command = "app", usage = "[options]")
    check msg.complaints == @["missing value: option --port requires a value"]

  test "when every complaint is a `missing ...`, none are suppressed":
    let spec = (src: arg("<src>", default = "", help = ""),
                dest: arg("<dest>", default = "", help = ""),
                list: flag("--list", help = ""), help: help())
    let msg = failure:
      spec.parse(args = @[], command = "backup", usage = "<src> <dest>\n--list\n(-h | --help)")
    check msg.complaints == @["missing option: (--list | -h)", "missing argument: <src>"]

suite "the offending token is named":
  test "a typo'd command is named and given a suggestion":
    let spec = (ship: command("ship", (help: help()), help = ""),
                mine: command("mine", (help: help()), help = ""),
                help: help())
    let msg = failure: spec.parse(args = @["shp", "move"], command = "nf", usage = "(ship | mine)")
    check msg.complaints == @["unrecognized command: shp; did you mean ship?"]

  test "the redundant `missing command` line goes with it":
    let spec = (ship: command("ship", (help: help()), help = ""),
                mine: command("mine", (help: help()), help = ""),
                help: help())
    let msg = failure: spec.parse(args = @["zzz"], command = "nf", usage = "(ship | mine)")
    check msg.complaints == @["unrecognized command: zzz"]
    # ...but the valid set stays visible in the usage block below.
    check "nf (ship | mine)" in msg

  test "a stray positional is named":
    let msg = failure: baseSpec().parse(args = @["stray"], command = "app", usage = "[options]")
    check msg.complaints == @["unexpected argument: stray"]

  test "the named token comes from the furthest-reaching failed branch":
    # `-v` matched correctly; a branch that got nowhere used to name it.
    let msg = failure: baseSpec().parse(args = @["-v", "stray"], command = "app", usage = "[options]")
    check msg.complaints == @["unexpected argument: stray"]

  test "a FlagOp Alias exclusivity conflict names the later variant, not both":
    # The first variant typed is consumed; the second is what broke
    # exclusivity. Naming both used to name a correctly-typed token half the
    # time -- see ADR 0036.
    for (args, offender) in {@["--moored", "--drifting"]: "--drifting",
                             @["--drifting", "--moored"]: "--moored"}:
      let spec = (moored: flag(ops = [flagOp("--moored", "=", true),
                                      flagOp("--drifting", "=", false)],
                               default = false, help = ""),)
      let msg = failure: spec.parse(usage = "[--moored | --drifting]", args = args, command = "prog")
      check msg.complaints == @["unexpected flag: " & offender]

  test "a leftover past a typed `--` is never called an unrecognized option":
    # Everything classifies Positional past the marker.
    let spec = (help: help(),)
    let msg = failure: spec.parse(args = @["--", "--weird"], command = "app", usage = "[options]")
    check msg.complaints == @["unexpected argument: --weird"]

  test "a starved option standing in a command's position keeps its own wording":
    let msg = failure: commandSpec().parse(args = @["--port"], command = "app")
    check "missing value: option --port requires a value" in msg.complaints

  test "a nested spec's leftover is named against that spec, not the parent's":
    let sub = (speed: opt[int]("--speed=<n>", default = 0, help = ""), help: help())
    let spec = (go: command("go", sub, usage = "[options]", help = ""), help: help())
    let msg = failure: spec.parse(args = @["go", "--sped", "3"], command = "app")
    check msg.complaints == @["unrecognized option: --sped; did you mean --speed?"]

  test "an option-shaped leftover stays an option even where a command was wanted":
    # A stray `missing command` must not turn every leftover into one.
    let msg = failure: commandSpec().parse(args = @["--prot", "80"], command = "app")
    check "unrecognized option: --prot; did you mean --port?" in msg.complaints
    check not msg.complaints.anyIt(it.startsWith("unrecognized command"))

  test "and past a `--` nothing is a mistyped command either":
    # Nothing is a command name past the marker.
    let msg = failure: commandSpec().parse(args = @["--", "add"], command = "app")
    check "unexpected argument: add" in msg.complaints
    check "did you mean" notin msg

  test "wording follows what the grammar expected, not the token's shape":
    # Lexically a positional either way; only the grammar position differs.
    let asCommand = failure: commandSpec().parse(args = @["stray"], command = "app")
    let asArgument = failure: baseSpec().parse(args = @["stray"], command = "app", usage = "[options]")
    check asCommand.complaints == @["unrecognized command: stray"]
    check asArgument.complaints == @["unexpected argument: stray"]

suite "did-you-mean":
  proc suggestSpec(): auto =
    (port: opt("--port=<n>", default = 0, help = ""),
     speed: opt("--speed=<kn>", default = 0, help = ""),
     moored: flag("--moored", help = ""),
     drifting: flag("--drifting", help = ""),
     sort: flag("--sort", help = ""),
     version: flag("--version", help = ""),
     help: help())

  proc suggestionFor(typed: string): string =
    failure: suggestSpec().parse(args = @[typed], command = "app", usage = "[options]")

  test "a transposition is one edit, not two":
    # All missed under plain Levenshtein at distance 1.
    check "did you mean --port?" in suggestionFor("--prot")
    check "did you mean --drifting?" in suggestionFor("--drifitng")
    check "did you mean --version?" in suggestionFor("--verison")
    check "did you mean --help?" in suggestionFor("--hepl")

  test "the other typo classes still land":
    check "did you mean --port?" in suggestionFor("--porrt")  # doubled
    check "did you mean --speed?" in suggestionFor("--sped")  # dropped
    check "did you mean --moored?" in suggestionFor("--mored")

  test "the threshold scales with the candidate, so a short name stays strict":
    # `--sort` is two edits away and must not be offered.
    let msg = suggestionFor("--por")
    check "did you mean --port?" in msg
    check "--sort" notin msg

  test "every candidate tied at the best distance is offered":
    check "did you mean --port or --sort?" in suggestionFor("--fort")

  test "declaration order can't decide a tie":
    let a = (sort: flag("--sort", help = ""), port: opt("--port=<n>", default = 0, help = ""))
    let b = (port: opt("--port=<n>", default = 0, help = ""), sort: flag("--sort", help = ""))
    let first = failure: a.parse(args = @["--fort"], command = "app", usage = "[options]")
    let second = failure: b.parse(args = @["--fort"], command = "app", usage = "[options]")
    check "did you mean --port or --sort?" in first
    check "did you mean --port or --sort?" in second

  test "the cap keeps a long name from suggesting its own opposite":
    let spec = (enable: flag("--enable-experimental", help = ""),
                disable: flag("--disable-experimental", help = ""))
    let msg = failure: spec.parse(args = @["--enable-experimentl"], command = "app", usage = "[options]")
    check "did you mean --enable-experimental?" in msg
    check "--disable-experimental" notin msg.complaints.join("\n")

  test "a short option is never offered as a suggestion":
    # Every one-character name is one edit from every other.
    let spec = (v: flag("-v", help = ""), q: flag("-q", help = ""), help: help())
    let msg = failure: spec.parse(args = @["-j"], command = "app", usage = "[options]")
    check msg.complaints == @["unrecognized option: -j"]

  test "nor for a cluster remainder the user never typed":
    # `-1x` peels to a leftover `-x` nobody typed.
    let spec = (one: flag("-1, --one", help = ""), v: flag("-v", help = ""),
                q: flag("-q", help = ""), rest: args("<rest>", help = ""), help: help())
    let msg = failure: spec.parse(args = @["-1x"], command = "app", usage = "[options] [<rest>...]")
    check "did you mean" notin msg

  test "a long option is never offered in a short option's place":
    # `-ab` is cluster syntax -- what failed is a letter inside it.
    let spec = (ab: flag("--ab", help = ""),)
    let msg = failure: spec.parse(args = @["-ab"], command = "app", usage = "[options]")
    check "did you mean" notin msg

  test "so a short-form token receives no suggestion at all":
    # Short candidates excluded everywhere, long ones for short-form tokens.
    for typed in ["-j", "-ab", "-verbose"]:
      let spec = (v: flag("-v", help = ""), verbose: flag("--verbose", help = ""),
                  help: help())
      let msg = failure: spec.parse(args = @[typed], command = "app", usage = "[options]")
      check "did you mean" notin msg

  test "a long-form token still gets its long-form suggestion":
    let spec = (verbose: flag("--verbose", help = ""), help: help())
    let msg = failure: spec.parse(args = @["--verbsoe"], command = "app", usage = "[options]")
    check "did you mean --verbose?" in msg

  test "a token with no candidate within threshold is still named, without a suggestion":
    let msg = suggestionFor("--nothinglikeit")
    check msg.complaints == @["unrecognized option: --nothinglikeit"]

  test "a multi-byte token is measured by character, not by byte":
    # `naïve` is 5 runes but 6 bytes, so a byte-wise distance would drop the
    # suggestion. Via a command because `\w` is ASCII-only, so a multi-byte
    # token is never option-shaped.
    let spec = (naive: command("naive", (help: help()), help = ""), help: help())
    let msg = failure: spec.parse(args = @["naïve"], command = "app", usage = "naive")
    check "did you mean naive?" in msg

  test "commands are suggested by the same rule as options":
    let spec = (deploy: command("deploy", (help: help()), help = ""),
                destroy: command("destroy", (help: help()), help = ""),
                help: help())
    let msg = failure: spec.parse(args = @["depoly"], command = "app", usage = "(deploy | destroy)")
    check "did you mean deploy?" in msg
    check "destroy" notin msg.complaints.join("\n")

suite "one message shape":
  test "ParseError.msg begins with the first complaint, not a newline":
    let msg = failure: baseSpec().parse(args = @["stray"], command = "app", usage = "[options]")
    check msg.startsWith("  - unexpected argument: stray")

  test "a conversion failure gains the bullet and the usage block":
    let msg = failure:
      baseSpec().parse(args = @["--port", "abc"], command = "app", usage = "[options]")
    check msg.complaints == @["expected int for --port but got \"abc\""]
    check "Usage:\n  app [options]" in msg

  test "a validation failure gets the same shape, keeping its own type":
    let spec = (num: opt("--num=<n>", default = 1, validator = range(1..10), help = ""),
                help: help())
    var caught = ""
    try:
      spec.parse(args = @["--num", "999"], command = "app", usage = "[options]")
      check false # unreachable
    except ValidationError as e:
      caught = e.msg
    check caught.complaints == @["for --num, got 999 but expected one of 1 .. 10"]
    check "Usage:\n  app [options]" in caught

  test "the usage block still follows a grammar failure":
    let msg = failure: commandSpec().parse(args = @[], command = "app")
    check "Usage:\n  app [options] add" in msg

suite "a failed branch is ranked by Reach, not by matchers satisfied":
  # Issue #40, ADR 0036. An Option matcher scans the whole token list, so an
  # options-only usage line can skip over the token the user got wrong, match
  # something later, and outrank the branch that actually understood the
  # leading input.
  proc navalSpec(): auto =
    ## `examples/naval_fate.nim`'s spec, help text stripped.
    let
      moored = flag(ops = [flagOp("--moored", "=", true),
                           flagOp("--drifting", "=", false)])
      ship = (new: command("new", (names: args("<name>", help = ""), help: help()),
                           usage = "<name>...", help = ""),
              move: command("move", (name: arg("<name>", help = ""),
                                     x: arg("<x>", default = 0, help = ""),
                                     y: arg("<y>", default = 0, help = ""),
                                     speed: opt("--speed=<kn>", default = 10, help = ""),
                                     help: help()),
                            usage = "<name> <x> <y> [--speed=<kn>]", help = ""),
              shoot: command("shoot", (x: arg("<x>", default = 0, help = ""),
                                       y: arg("<y>", default = 0, help = ""),
                                       help: help()),
                             usage = "<x> <y>", help = ""),
              help: help())
      mineArgs = (x: arg("<x>", default = 0, help = ""),
                  y: arg("<y>", default = 0, help = ""),
                  moored: moored, help: help())
      mine = (set: command("set", mineArgs, usage = "<x> <y> [--moored | --drifting]", help = ""),
              remove: command("remove", mineArgs, usage = "<x> <y> [--moored | --drifting]", help = ""),
              help: help())
    (ship: command("ship", ship, help = ""), mine: command("mine", mine, help = ""),
     help: help(), version: version("-v, --version", "Naval Fate 2.0.0"))

  proc navalFailure(args: seq[string]): seq[string] =
    let msg = failure: navalSpec().parse(args = args, command = "naval_fate")
    msg.complaints

  test "a trailing option no longer costs a mistyped command its suggestion":
    # The `(-h | --help)` line skipped `shp` to match at index 1, scoring a
    # depth the command lines couldn't reach; `missing command` was discarded
    # and `shp` fell through to `classify` as a bare positional.
    for args in [@["shp", "--help"], @["shp", "-h"], @["shp", "--version"]]:
      check navalFailure(args) == @["unrecognized command: shp; did you mean ship?"]

  test "and the cases that already worked still do":
    for args in [@["shp"], @["shp", "foo"]]:
      check navalFailure(args) == @["unrecognized command: shp; did you mean ship?"]

  test "a correctly typed command is no longer named as the offender":
    # `ship` matched, then the nested spec failed on `mve`; a branch that
    # understood none of that used to tie and merge its leftover in.
    for args in [@["ship", "mve", "-v"], @["ship", "mve", "--help"]]:
      check navalFailure(args) == @["unrecognized command: mve; did you mean move?"]

  test "nor at a deeper nesting level":
    check navalFailure(@["mine", "st", "--help"]) ==
      @["unrecognized command: st; did you mean set?"]

  test "the sole real complaint is no longer buried under correct tokens":
    # Everything but `--help` is right; only its position is wrong.
    check navalFailure(@["ship", "move", "a", "1", "2", "--help"]) ==
      @["unexpected flag: --help"]

  test "an exclusivity conflict names the later variant even when reached out of order":
    let spec = (x: arg("<x>", default = 0, help = ""),
                y: arg("<y>", default = 0, help = ""),
                moored: flag(ops = [flagOp("--moored", "=", true),
                                    flagOp("--drifting", "=", false)],
                             default = false, help = ""))
    let msg = failure:
      spec.parse(usage = "<x> <y> [--moored | --drifting]",
                 args = @["--drifting", "1", "2", "--moored"], command = "prog")
    check msg.complaints == @["unexpected flag: --moored"]

  test "only the first offender is named, not every later one":
    let spec = (letters: flag[int](ops = [flagOp("--aa", "=", 1), flagOp("--bb", "=", 2),
                                          flagOp("--cc", "=", 3)], default = 0, help = ""),)
    let msg = failure:
      spec.parse(usage = "[--aa | --bb | --cc]", args = @["--cc", "--bb", "--aa"],
                 command = "prog")
    check msg.complaints == @["unexpected flag: --bb"]

  test "Reach carries across a nesting boundary, so the deeper branch still wins":
    # Both lines consume `<a>` and tie on what this level's own matcher ate;
    # only their descendants tell them apart. Without the nested Reach they
    # tie and merge, naming `2` -- a perfectly good `<b>` -- alongside `3`.
    let spec = (a: arg("<a>", default = 0, help = ""), b: arg("<b>", default = 0, help = ""),
                zzz: command("zzz", (help: help(),), help = ""),
                qqq: command("qqq", (help: help(),), help = ""))
    let msg = failure:
      spec.parse(usage = "<a> <b> zzz\n<a> qqq", args = @["1", "2", "3"], command = "app")
    check msg.complaints == @["unrecognized command: 3"]

  test "a matched option is no longer named alongside the branch that wanted more":
    # `-b -a`: `-b` alone is a valid parse, so `-a` is the whole offence. The
    # `-a <z>` branch stalls at index 0 and no longer ties its way in.
    let spec = (a: flag("-a", help = ""), b: flag("-b", help = ""),
                z: arg("<z>", default = "", help = ""), help: help())
    let msg = failure: spec.parse(usage = "-a <z>\n-b", args = @["-b", "-a"], command = "app")
    check msg.complaints == @["unexpected flag: -a"]
    # ...and typed the other way `-a` is consumed, so only the real gap shows.
    let msg2 = failure: spec.parse(usage = "-a <z>\n-b", args = @["-a", "-b"], command = "app")
    check msg2.complaints == @["missing argument: <z>"]

  test "the tied-branch merge still groups same-kind complaints onto one line":
    # Reach ties at 0 for both usage lines, so both `missing option`s survive.
    let spec = (list: flag("--list", help = ""), help: help())
    let msg = failure: spec.parse(args = @[], command = "app", usage = "--list\n(-h | --help)")
    check msg.complaints == @["missing option: (--list | -h)"]
