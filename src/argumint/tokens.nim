## Owns "what is this token, given where we are" -- ADR 0019 (lazy token
## classification) and ADR 0034 (Strict Option Checking). `RawToken` and
## `Classification` are the data model; a `TokenCursor` carries a token
## stream together with the `Spec` governing it and whether `--` has been
## crossed, since those three answer every question in this file together.
## `fsm.nim` owns the walk itself; failure reporting and the Value
## Precedence fallback tiers moved out to `complaints.nim`/`precedence.nim`
## -- see `docs/architecture.md` §3.

import std/[importutils, pegs, strformat, tables]

import ./backend
# Reaches `Spec`'s private `options`/`commands` tables (ADR 0030) --
# non-generic code only, see docs/gotchas.md.
privateAccess(Spec)

type
  RawToken* = object
    ## A raw command-line token, classified only as far as pure string shape can
    ## tell without consulting a `Spec` -- see ADR 0019.
    raw*: string
      ## The literal token as typed
    optShape*: bool
      ## True if `raw` looks like `-o`/`--opt`/`-o=val`/`--opt=val`, or a
      ## `-xyz`-shaped cluster candidate
    idx*: int
      ## Original position in the CLI argv -- a peeled cluster remainder
      ## inherits its parent token's `idx` rather than getting a fresh one.
      ## Lets Flag Operation composition sort by true typed order instead
      ## of grammar/push order -- see `parseAllValues` (`fsm.nim`).
    subIdx*: int
      ## How many letters have been peeled off this token's parent cluster
      ## -- 0 for anything the user typed. Ranking-only, and deliberately
      ## separate from `idx`, which must keep naming the whole physical
      ## argument for composition order. See `Reach` (`fsm.nim`).
    cluster*: string
      ## The Short-Option Cluster this token was peeled from -- empty when `raw`
      ## *is* what the user typed, which is what `fromCluster` tests. Peeling
      ## destroys the original, so a complaint about `-1.5`'s leftover has no
      ## other way to say where `-.` came from. Read through `userTyped`, never
      ## directly. See ADR 0038.

  Classification* = object
    ## What a `RawToken` actually is, resolved lazily against a `Spec` -- see
    ## `classify`, ADR 0019. `consumed`/`remainder` feed `consume`.
    consumed*: int
    remainder*: string
    starvedOpt*: Arg
      ## Set when this token *is* a declared Optional but no value is available
      ## for it. The non-accepting outcome that lets the leftover-token
      ## complaint tell "name unknown" from "name known, no value" apart -- see
      ## ADR 0034.`kind` is still `Positional` here (there is no accepting
      ## classification to report), so consult this before trusting it.
    starvedName*: string
      ## The variant `starvedOpt` was spelled as
    case kind*: ArgKind
    of Command:
      cmd*: CommandArg
      cmdName*: string
    of Optional:
      opt*: Arg
      optName*: string
      optVal*: string
      optSep*: string
    of Flag:
      flag*: Arg
      flagName*: string
    of Positional:
      argVal*: string

  TokenCursor* = object
    ## A token stream together with the `Spec` governing it and whether `--` has
    ## been crossed -- the three pieces of state every classification question
    ## in this file needs together. See ADR 0019.
    tokens*: seq[RawToken]
    spec*: Spec
    optsEnd*: bool

let
  OptionValueFormat = peg"""
    # Allows you to capture [-o, =, val] / [--option, =, val] in -o=val / --option=val
    option <- ^ {(shortOption / longOption)} ({equals} {value}) $
    equals <- '=' / ':'
    shortOption <- '-' \w
    longOption <- '--' \w (\w / ('-' \w))+
    value <- _*
  """

  OptionFormat = peg"""
  # Allows you to capture -o / --option
  option <- ^ {(shortOption / longOption)} $
  shortOption <- '-' \w
  longOption <- '--' \w (\w / ('-' \w))+
  """

proc fromCluster(token: RawToken): bool =
  ## Whether this token is a peeled `-abc` remainder rather than something the
  ## user typed. Derived, not stored: a `cluster` is carried over on exactly the
  ## peel that would have set a flag, and is never empty there (a peel's parent
  ## is a 3+ character dash token).
  token.cluster.len > 0

proc isOptShape(raw: string): bool =
  ## Pure string-shape recognition needing no `Spec` -- see ADR 0019.
  raw =~ OptionFormat or raw =~ OptionValueFormat or
    (raw.len > 2 and raw[0] == '-' and raw[1] != '-')

proc isNonOptionShort(raw: string): bool =
  ## A **Non-Option Short**: one leading dash whose second character isn't an
  ## ASCII letter (`-5`, `-.5`, `-1e9`, `-0x1F`, `-+3`, `-5x`). Two leading
  ## dashes never qualify. Shape only, deliberately *not* "parses as a number"
  ## -- that admits `-inf`/`-nan` while rejecting `-0x1F`/`-+3`. See ADR 0034.
  raw.len > 1 and raw[0] == '-' and raw[1] != '-' and
    raw[1] notin {'a'..'z', 'A'..'Z'}

proc exemptFromStrict(token: RawToken): bool =
  ## Whether Strict Option Checking never applies to `token`. A Non-Option Short
  ## qualifies only when the user actually typed it: a peeled `-abc` remainder
  ## is a cluster continuation, so `-1.5`'s leftover `-.5` is still an
  ## unrecognized option exactly as `-1x`'s `-x` is. See `RawToken.fromCluster`.
  token.raw.isNonOptionShort and not token.fromCluster

proc userTyped*(token: RawToken): string =
  ## What the user actually put on the command line to produce `token` --
  ## itself, unless it's a peel of something longer. See `RawToken.cluster`.
  if token.fromCluster: token.cluster else: token.raw

proc mustResolve*(token: RawToken): bool =
  ## Whether `token` has to resolve against the spec or else be an error:
  ## option-shaped, and not exempt. Says nothing about `strictOptions` -- a
  ## starved option is an error either way, so callers that only fire under the
  ## setting pair this with it. See ADR 0034.
  token.optShape and not token.exemptFromStrict

proc tokenizeArgs(args: seq[string], start = 0): seq[RawToken] =
  ## Splits `args[start..]` into `RawToken`s by shape only -- never touches
  ## `Spec`, never raises -- see ADR 0019.
  for i in start ..< args.len:
    result.add RawToken(raw: args[i], optShape: args[i].isOptShape, idx: i)

proc initCursor*(spec: Spec, args: seq[string], start = 0): TokenCursor =
  ## Tokenizes `args` (see `tokenizeArgs`) and pairs the result with `spec`, the
  ## root Spec governing position 0 -- a matched `Command` transition descends
  ## `cursor.spec` further as the walk proceeds (`fsm.nim`).
  TokenCursor(spec: spec, tokens: tokenizeArgs(args, start))

proc len*(cur: TokenCursor): int =
  ## Thin wrapper over `.tokens.len`, for `fsm.nim`'s convenience.
  cur.tokens.len

proc `[]`*(cur: TokenCursor, i: int): RawToken =
  ## Thin wrapper over `.tokens[i]`, for `fsm.nim`'s convenience.
  cur.tokens[i]

proc refusesAsValue(cur: TokenCursor, pos: int): bool =
  ## Whether Strict Option Checking stops the token at `pos` from filling a
  ## declared Optional's value slot, so `--name --help` starves rather than
  ## setting `name` to `"--help"`. Same setting as the positional slot
  ## (`refusesAsPositional`); with strict off an option-shaped token still
  ## counts as a value and starvation needs end of input.
  cur.spec.settings.strictOptions and cur[pos].mustResolve

proc refusesAsPositional*(cur: TokenCursor, pos: int, c: Classification): bool =
  ## Whether an `Argument` matcher must decline `cur.tokens[pos]` as opaque
  ## literal text -- refuse-to-match, never raise, so the token stays leftover
  ## for `walk` to word and backtracking survives. See ADR 0034.
  ##
  ## A starved declared Optional is refused whatever `strictOptions` says;
  ## otherwise this is ADR 0019 gap 3's case, and `cur.optsEnd` is what exempts
  ## a post-`--` token -- `classify` short-circuits it to a plain `Positional`
  ## that would otherwise look exactly like an unknown option.
  if not c.starvedOpt.isNil:
    return true
  cur.spec.settings.strictOptions and not cur.optsEnd and c.kind == Positional and
    cur[pos].mustResolve

proc starved(option: Arg, variant, raw: string): Classification =
  ## A declared Optional with no value available for it -- see
  ## `Classification.starvedOpt`.
  Classification(kind: Positional, argVal: raw, consumed: 1,
    starvedOpt: option, starvedName: variant)

proc classify*(cur: TokenCursor, pos: int): Classification =
  ## Decides what `cur.tokens[pos]` is against `cur.spec`'s tables -- the lazy
  ## half of ADR 0019. Never raises: an unresolved option-shaped token falls
  ## through to the `Positional` fallback at the bottom.
  let token = cur[pos]
  if cur.optsEnd:
    return Classification(kind: Positional, argVal: token.raw, consumed: 1)
  if token.raw in cur.spec.commands:
    return Classification(kind: Command, cmd: cur.spec.commands[token.raw], cmdName: token.raw, consumed: 1)
  if token.optShape:
    # Bare `-o`/`--option`; an Optional's value comes from the next token.
    if token.raw =~ OptionFormat:
      let variant = token.raw
      if variant in cur.spec.options:
        let option = cur.spec.options[variant]
        case option.kind
        of Flag:
          return Classification(kind: Flag, flag: option, flagName: variant, consumed: 1)
        of Optional:
          if pos + 1 < cur.len and not cur.refusesAsValue(pos + 1):
            return Classification(kind: Optional, opt: option, optName: variant, optVal: cur[pos + 1].raw, consumed: 2)
          # Declared, but nothing usable follows -- a starved option, not an
          # unknown name. Errors under both settings.
          return starved(option, variant, token.raw)
        else: discard
    # `-o=val` / `--option=value`.
    elif token.raw =~ OptionValueFormat:
      let (variant, sep, value) = (matches[0], matches[1], matches[2])
      if variant in cur.spec.options and cur.spec.options[variant].kind == Optional:
        return Classification(kind: Optional, opt: cur.spec.options[variant], optName: variant, optSep: sep, optVal: value, consumed: 1)
    # A cluster of short options (`-abc`). Only the first letter resolves
    # here -- a Flag leaves the rest as `remainder` for `consume` to
    # reinsert; an Optional swallows the rest as its value. See ADR 0019
    # point 2 on why this can't be decided eagerly.
    elif token.raw.len > 2 and token.raw[0] == '-' and token.raw[1] != '-':
      let variant = "-" & token.raw[1]
      if variant in cur.spec.options:
        let option = cur.spec.options[variant]
        let folded = token.raw.substr(2)
        case option.kind
        of Flag:
          return Classification(kind: Flag, flag: option, flagName: variant, consumed: 1,
            remainder: (if folded.len > 0: "-" & folded else: ""))
        of Optional:
          # `folded` is never empty here -- the branch guard is `raw.len > 2`
          # -- so an Optional reached through a cluster always has its value
          # attached and can't starve. Bare `-p` goes through `OptionFormat`.
          if fmt"{variant}{folded}" =~ OptionValueFormat:
            return Classification(kind: Optional, opt: option, optName: variant, optSep: matches[1], optVal: matches[2], consumed: 1)
          else:
            return Classification(kind: Optional, opt: option, optName: variant, optVal: folded, consumed: 1)
        else: discard
  Classification(kind: Positional, argVal: token.raw, consumed: 1)

proc consume*(cur: var TokenCursor, pos: int, c: Classification) =
  ## Removes/reinserts the raw token(s) an accepted `Classification` accounts
  ## for at `pos` -- see `classify`'s cluster branch, ADR 0019.
  let parent = cur[pos]
  cur.tokens.delete pos
  if c.consumed == 2:
    cur.tokens.delete pos # the value that was tokens[pos + 1]
  elif c.remainder.len > 0:
    # Inherits the parent token's idx -- it's the same physical CLI argument,
    # just partially consumed -- but advances `subIdx`, one more letter of it
    # now being accounted for. See `RawToken.idx`/`.subIdx`.
    cur.tokens.insert(RawToken(raw: c.remainder, optShape: c.remainder.isOptShape,
      idx: parent.idx, subIdx: parent.subIdx + 1,
      # Carried so a complaint can say which typed token this came out of;
      # peeling destroys it otherwise. Also what makes `fromCluster` true.
      cluster: parent.userTyped), pos)

proc consumeOptsEnd*(cur: var TokenCursor, pos: int): bool =
  ## Drops a not-yet-consumed literal `--` at `pos` and marks this cursor past
  ## the end of options -- see ADR 0019. Returns whether it did so, so callers
  ## can re-examine `pos` without incrementing.
  if not cur.optsEnd and cur[pos].raw == "--":
    cur.tokens.delete pos
    cur.optsEnd = true
    result = true

when isMainModule:
  import std/[unittest]
  import ../argumint

  proc restSpec(): auto =
    (rest: args("<rest>"),)

  proc nameSpec(): auto =
    (name: opt("--name=<s>", default = ""),)

  suite "isOptShape":
    test "recognizes bare short and long options":
      check "-o".isOptShape
      check "--opt".isOptShape

    test "recognizes attached-value forms":
      for shape in ["-o=val", "-o:val", "--option=value", "--option:value"]:
        check isOptShape(shape)

    test "recognizes a cluster candidate":
      check "-abc".isOptShape

    test "long options must have at last two non-dash characters to be option-shaped":
      # `longOption <- '--' \w (\w / ('-' \w))+`. Pinned because it looks like
      # a hole rather than an intentional exemption -- see ADR 0034.
      check not "--o".isOptShape
      check not "--5".isOptShape

    test "negative numbers are option-shaped":
      check "-1".isOptShape
      check "-1.5".isOptShape

    test "a literal -- is not option-shaped":
      check not "--".isOptShape

    test "a bare - is not option-shaped":
      check not "-".isOptShape

  suite "isNonOptionShort":
    test "every documented Non-Option Short qualifies":
      for tok in ["-5", "-.5", "-1e9", "-0x1F", "-+3", "-5x", "-1_000"]:
        check tok.isNonOptionShort

    test "a normal short option never qualifies":
      check not "-a".isNonOptionShort
      check not "-abc".isNonOptionShort

    test "two leading dashes never qualify":
      check not "--5".isNonOptionShort
      check not "--1_000".isNonOptionShort

  suite "exemptFromStrict":
    test "a Non-Option Short typed directly is exempt":
      check RawToken(raw: "-.5").exemptFromStrict

    test "the same text as a cluster remainder is not exempt":
      # With `-1` declared as a Flag, `-1.5` peels to a `-.5` remainder --
      # a cluster continuation, refused exactly as `-1x`'s `-x` is, not the
      # Non-Option Short exemption. See ADR 0034's "a cluster remainder is
      # not a Non-Option Short" deviation. The suite below drives the real
      # peel end to end rather than constructing this shape by hand.
      check not RawToken(raw: "-.5", cluster: "-1.5").exemptFromStrict

    test "a normal short option is never exempt, cluster or not":
      check not RawToken(raw: "-x").exemptFromStrict
      check not RawToken(raw: "-x", cluster: "-1x").exemptFromStrict

  suite "refusesAsPositional":
    test "strictOptions on: refuses an unresolved option-shaped token":
      let
        spec = newSpec(restSpec(), usage = "<rest>...")
        cur = initCursor(spec, @["--nope"])
        c = cur.classify(0)
      check cur.refusesAsPositional(0, c)

    test "strictOptions off: accepts it as literal positional text":
      let
        settings = newSpecSettings(strictOptions = false)
        spec = newSpec(restSpec(), usage = "<rest>...", settings = settings)
        cur = initCursor(spec, @["--nope"])
        c = cur.classify(0)
      check not cur.refusesAsPositional(0, c)

    test "a starved declared Optional is refused whatever strictOptions says":
      let
        settings = newSpecSettings(strictOptions = false)
        spec = newSpec(nameSpec(), usage = "[options]", settings = settings)
        cur = initCursor(spec, @["--name"])
        c = cur.classify(0)
      check not c.starvedOpt.isNil
      check cur.refusesAsPositional(0, c)

    test "a post-`--` token is exempt even with strictOptions on":
      let spec = newSpec(restSpec(), usage = "<rest>...")
      var cur = initCursor(spec, @["--", "--nope"])
      discard cur.consumeOptsEnd(0)
      let c = cur.classify(0)
      check c.kind == ArgKind.Positional
      check not cur.refusesAsPositional(0, c)

  suite "classify: cluster peel":
    test "a Flag cluster peels one letter, leaving the remainder as a RawToken":
      let
        spec = newSpec((v: flag("-v"), a: flag("-a")), usage = "[options]")
        cur = initCursor(spec, @["-va"])
        c = cur.classify(0)
      check c.kind == ArgKind.Flag
      check c.flagName == "-v"
      check c.remainder == "-a"

    test "an Optional in a cluster swallows the rest as its attached value":
      let
        spec = newSpec((p: opt("-p=<n>", default = "")), usage = "[options]")
        cur = initCursor(spec, @["-p80"])
        c = cur.classify(0)
      check c.kind == ArgKind.Optional
      check c.optVal == "80"
      check c.consumed == 1

    test "a declared spelling resolves before an undeclared letter would starve the scan":
      let
        spec = newSpec((n: opt("-n=<s>", default = "")), usage = "[options]")
        cur = initCursor(spec, @["-nan"])
        c = cur.classify(0)
      check c.kind == ArgKind.Optional
      check c.optName == "-n"
      check c.optVal == "an"

    test "`-1.5` against a declared `-1` Flag peels to a `-.5` remainder that is refused, not exempt":
      let spec = newSpec((one: flag("-1"),), usage = "[options]")
      var cur = initCursor(spec, @["-1.5"])
      let c = cur.classify(0)
      check c.kind == ArgKind.Flag
      check c.flagName == "-1"
      check c.remainder == "-.5"
      cur.consume(0, c)
      check cur.len == 1
      check cur[0].raw == "-.5"
      check cur[0].cluster == "-1.5"
      check not cur[0].exemptFromStrict

  suite "classify: attached values via `-o=val`":
    test "a short option's attached value":
      let
        spec = newSpec((p: opt("-p=<n>", default = "")), usage = "[options]")
        cur = initCursor(spec, @["-p=80"])
        c = cur.classify(0)
      check c.kind == ArgKind.Optional
      check c.optName == "-p"
      check c.optSep == "="
      check c.optVal == "80"
      check c.consumed == 1

    test "a long option's attached value":
      let
        spec = newSpec((port: opt("--port=<n>", default = "")), usage = "[options]")
        cur = initCursor(spec, @["--port=80"])
        c = cur.classify(0)
      check c.kind == ArgKind.Optional
      check c.optName == "--port"
      check c.optVal == "80"

  suite "classify: starvation":
    let spec = newSpec(nameSpec(), usage = "[options]")

    test "a declared Optional with nothing after it starves":
      let
        cur = initCursor(spec, @["--name"])
        c = cur.classify(0)
      check c.kind == ArgKind.Positional
      check not c.starvedOpt.isNil
      check c.starvedName == "--name"

    test "strictOptions on: an option-shaped following token starves rather than being eaten":
      let
        cur = initCursor(spec, @["--name", "--nope"])
        c = cur.classify(0)
      check c.kind == ArgKind.Positional
      check not c.starvedOpt.isNil
      check c.starvedName == "--name"

    test "strictOptions off: the same following token is eaten as the value":
      spec.settings.strictOptions = false
      let
        cur = initCursor(spec, @["--name", "--nope"])
        c = cur.classify(0)
      check c.kind == ArgKind.Optional
      check c.optVal == "--nope"
      check c.consumed == 2

  suite "classify: end-of-options short-circuit":
    test "past optsEnd every token classifies as plain Positional text":
      let spec = newSpec(restSpec(), usage = "<rest>...")
      var cur = initCursor(spec, @["--nope"])
      cur.optsEnd = true
      let c = cur.classify(0)
      check c.kind == ArgKind.Positional
      check c.argVal == "--nope"
      check c.starvedOpt.isNil

  suite "classify: command and positional":
    test "a declared command name classifies as Command":
      let
        spec = newSpec((go: command("go", restSpec())), usage = "go")
        cur = initCursor(spec, @["go"])
        c = cur.classify(0)
      check c.kind == ArgKind.Command
      check c.cmdName == "go"

    test "plain text falls through to Positional":
      let
        spec = newSpec((n: arg("<n>")), usage = "<n>")
        cur = initCursor(spec, @["hello"])
        c = cur.classify(0)
      check c.kind == ArgKind.Positional
      check c.argVal == "hello"

    test "never raises, whatever shape the token is":
      let spec = newSpec(restSpec(), usage = "<rest>...")
      for tok in ["-", "--", "-=", "--=", "-o=", "=", "-1.5.6", "-o=val=extra", ""]:
        let cur = initCursor(spec, @[tok])
        discard cur.classify(0)

  suite "consume":
    test "a peeled remainder inherits idx and increments subIdx":
      # ADR 0038: idx must name the whole physical CLI argument for Flag
      # Operation composition order, so a peel can't reset it -- constructed
      # directly, rather than via a fresh initCursor, so the parent's idx
      # (7) is clearly distinct from its position (0).
      let spec = newSpec((v: flag("-v"), a: flag("-a")), usage = "[options]")
      var cur = TokenCursor(spec: spec,
        tokens: @[RawToken(raw: "-va", optShape: true, idx: 7, subIdx: 2)])
      let c = cur.classify(0)
      check c.remainder == "-a"
      cur.consume(0, c)
      check cur.len == 1
      check cur[0].raw == "-a"
      check cur[0].idx == 7
      check cur[0].subIdx == 3
      check cur[0].cluster == "-va"

    test "a detached value consumes both its own token and the next":
      let spec = newSpec((port: opt("--port=<n>", default = "")), usage = "[options]")
      var cur = initCursor(spec, @["--port", "80", "extra"])
      let c = cur.classify(0)
      check c.consumed == 2
      cur.consume(0, c)
      check cur.len == 1
      check cur[0].raw == "extra"

  suite "consumeOptsEnd":
    test "drops a literal -- once, sets optsEnd, and returns false after":
      let spec = newSpec(restSpec(), usage = "<rest>...")
      var cur = initCursor(spec, @["--", "--nope"])
      check cur.consumeOptsEnd(0)
      check cur.optsEnd
      check cur.len == 1
      check cur[0].raw == "--nope"
      check not cur.consumeOptsEnd(0)
      check cur.len == 1

    test "does nothing to a token that isn't a literal --":
      let spec = newSpec(restSpec(), usage = "<rest>...")
      var cur = initCursor(spec, @["--nope"])
      check not cur.consumeOptsEnd(0)
      check not cur.optsEnd
      check cur.len == 1
