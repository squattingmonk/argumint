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

privateAccess(Spec) ## Reaches `Spec`'s private `options`/`commands` tables
  ## (ADR 0030) -- non-generic code only, see docs/gotchas.md.

type
  RawToken* = object
    ## A raw command-line token, classified only as far as pure string shape
    ## can tell without consulting a `Spec` -- see ADR 0019.
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
      ## The Short-Option Cluster this token was peeled from -- empty when
      ## `raw` *is* what the user typed, which is what `fromCluster` tests.
      ## Peeling destroys the original, so a complaint about `-1.5`'s
      ## leftover has no other way to say where `-.` came from. Read
      ## through `userTyped`, never directly. See ADR 0038.

  Classification* = object
    ## What a `RawToken` actually is, resolved lazily against a `Spec` --
    ## see `classify`, ADR 0019. `consumed`/`remainder` feed `consume`.
    consumed*: int
    remainder*: string
    starvedOpt*: Arg
      ## Set when this token *is* a declared Optional but no value is
      ## available for it. The non-accepting outcome that lets the
      ## leftover-token complaint tell "name unknown" from "name known, no
      ## value" apart -- see `docs/adr/0034-strict-option-checking.md`.
      ## `kind` is still `Positional` here (there is no accepting
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
    ## A token stream together with the `Spec` governing it and whether
    ## `--` has been crossed -- the three pieces of state every
    ## classification question in this file needs together. See ADR 0019.
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

proc userTyped*(token: RawToken): string =
  ## What the user actually put on the command line to produce `token` --
  ## itself, unless it's a peel of something longer. See `RawToken.cluster`.
  if token.cluster.len > 0: token.cluster else: token.raw

proc fromCluster(token: RawToken): bool =
  ## Whether this token is a peeled `-abc` remainder rather than something
  ## the user typed. Derived, not stored: a `cluster` is carried over on
  ## exactly the peel that would have set a flag, and is never empty there
  ## (a peel's parent is a 3+ character dash token). Only the Non-Option
  ## Short exemption asks -- see `exemptFromStrict`.
  token.cluster.len > 0

proc isOptShape*(raw: string): bool =
  ## Pure string-shape recognition needing no `Spec` -- see ADR 0019.
  raw =~ OptionFormat or raw =~ OptionValueFormat or
    (raw.len > 2 and raw[0] == '-' and raw[1] != '-')

proc isNonOptionShort*(raw: string): bool =
  ## A **Non-Option Short**: one leading dash whose second character isn't
  ## an ASCII letter (`-5`, `-.5`, `-1e9`, `-0x1F`, `-+3`, `-5x`). Two
  ## leading dashes never qualify. Shape only, deliberately *not* "parses
  ## as a number" -- that admits `-inf`/`-nan` while rejecting `-0x1F`/
  ## `-+3`. See `docs/adr/0034-strict-option-checking.md`.
  raw.len > 1 and raw[0] == '-' and raw[1] != '-' and
    raw[1] notin {'a'..'z', 'A'..'Z'}

proc exemptFromStrict*(token: RawToken): bool =
  ## Whether Strict Option Checking never applies to `token`. A Non-Option
  ## Short qualifies only when the user actually typed it: a peeled `-abc`
  ## remainder is a cluster continuation, so `-1.5`'s leftover `-.5` is
  ## still an unrecognized option exactly as `-1x`'s `-x` is. See
  ## `RawToken.fromCluster`.
  token.raw.isNonOptionShort and not token.fromCluster

proc mustResolve*(token: RawToken): bool =
  ## Whether `token` has to resolve against the spec or else be an error:
  ## option-shaped, and not exempt. Says nothing about `strictOptions` --
  ## a starved option is an error either way, so callers that only fire
  ## under the setting pair this with it. See ADR 0034.
  token.optShape and not token.exemptFromStrict

proc tokenizeArgs(args: seq[string], start = 0): seq[RawToken] =
  ## Splits `args[start..]` into `RawToken`s by shape only -- never touches
  ## `Spec`, never raises -- see ADR 0019.
  for i in start ..< args.len:
    result.add RawToken(raw: args[i], optShape: args[i].isOptShape, idx: i)

proc initCursor*(spec: Spec, args: seq[string], start = 0): TokenCursor =
  ## Tokenizes `args` (see `tokenizeArgs`) and pairs the result with `spec`,
  ## the root Spec governing position 0 -- a matched `Command` transition
  ## descends `cursor.spec` further as the walk proceeds (`fsm.nim`).
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

proc starved(option: Arg, variant, raw: string): Classification =
  ## A declared Optional with no value available for it -- see
  ## `Classification.starvedOpt`.
  Classification(kind: Positional, argVal: raw, consumed: 1,
    starvedOpt: option, starvedName: variant)

proc classify*(cur: TokenCursor, pos: int): Classification =
  ## Decides what `cur.tokens[pos]` is against `cur.spec`'s tables -- the
  ## lazy half of ADR 0019. Never raises: an unresolved option-shaped token
  ## falls through to the `Positional` fallback at the bottom.
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

proc refusesAsPositional*(cur: TokenCursor, pos: int, c: Classification): bool =
  ## Whether an `Argument` matcher must decline `cur.tokens[pos]` as opaque
  ## literal text -- refuse-to-match, never raise, so the token stays
  ## leftover for `walk` to word and backtracking survives. See ADR 0034.
  ##
  ## A starved declared Optional is refused whatever `strictOptions` says;
  ## otherwise this is ADR 0019 gap 3's case, and `cur.optsEnd` is what
  ## exempts a post-`--` token -- `classify` short-circuits it to a plain
  ## `Positional` that would otherwise look exactly like an unknown option.
  if not c.starvedOpt.isNil:
    return true
  cur.spec.settings.strictOptions and not cur.optsEnd and c.kind == Positional and
    cur[pos].mustResolve

proc consume*(cur: var TokenCursor, pos: int, c: Classification) =
  ## Removes/reinserts the raw token(s) an accepted `Classification`
  ## accounts for at `pos` -- see `classify`'s cluster branch, ADR 0019.
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
  ## Drops a not-yet-consumed literal `--` at `pos` and marks this cursor
  ## past the end of options -- see ADR 0019. Returns whether it did so,
  ## so callers can re-examine `pos` without incrementing.
  if not cur.optsEnd and cur[pos].raw == "--":
    cur.tokens.delete pos
    cur.optsEnd = true
    result = true
