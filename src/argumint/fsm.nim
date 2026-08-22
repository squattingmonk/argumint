## This module handles the navigation of the FSM based on a set of provided
## command-line arguments.
import std/[algorithm, importutils, os, pegs, sets, sequtils, strformat, strutils, sugar, tables, unicode]

# `Option` (the type) deliberately left unqualified-unimported --
# `options.Option[T]` instead, since a bare `import std/options` breaks
# every `case ... of Option:` branch matching `MatcherKind.Option` in this
# file -- see docs/gotchas.md.
from std/options import some, none, isSome, get

import ./[backend, configsource, errors, fsmgraph, parser]
export ParseError, SpecDefect, CompletionError

privateAccess(Spec) ## Reaches `Spec`'s private fields (ADR 0030) from
  ## non-generic code only -- see docs/gotchas.md.


type
  Match = tuple[variant: string, value: string, spec: Spec, idx: int]
    ## `idx` is the original CLI argv position of the token this match
    ## consumed -- see `RawToken.idx`. Composition (`parseAllValues`) sorts
    ## by it instead of relying on push order, which is grammar-position
    ## order, not typed order.
  MatchTable = OrderedTable[Arg, seq[Match]]
  Complaint = tuple[kind: string, subject: string, names: bool]
    ## A failure reason, e.g. `missing option: -v`. Structured so same-kind
    ## complaints group at render time; an empty `kind` renders as a bare
    ## sentence. `names` marks one that points at a token the user typed --
    ## a property, never a test on the wording, since ADR 0034's starved
    ## complaint must count. Built via `complaint`, never as a bare tuple.
    ## See ADR 0035.

  Leftover = tuple[tokens: seq[RawToken], spec: Spec, optsEnd: bool]
    ## One failed branch's unconsumed tokens, plus the context to
    ## re-`classify` them. Recorded during the walk, worded in
    ## `finalComplaints`. Whole token list, not just the first -- `classify`
    ## looks ahead, so a slice makes every leftover option look starved.
    ## See ADR 0035.

  ValueCursor = object
    ## Owns one Value Precedence fallback tier (env or Config Source) --
    ## see architecture.md's "Env var mechanics",
    ## `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`, and
    ## `docs/adr/0018-config-source.md`. Shared shape for both tiers:
    ## `probe` resolves and caches an Arg's available values (via a
    ## tier-specific `resolve` closure -- see `resolveEnv`/`resolveConfig`)
    ## the first time it's consulted during the walk, then hands out one
    ## value per subsequent call; `applyFallbacks`'s post-walk sweep reads
    ## `consumed`/`values` back to apply whatever the walk consumed (or
    ## complain about oversupply).
    values: Table[Arg, seq[string]]
    consumed: Table[Arg, int]
    tried: HashSet[Arg]
      ## Ensures `resolve` runs at most once per Arg for the life of this
      ## cursor, including caching a miss -- unlike an env lookup, a
      ## user-supplied `ConfigSource.lookup` may be arbitrarily expensive.
    applied: HashSet[Arg]
      ## Ensures this tier applies to an Arg at most once, even when the Arg
      ## is reachable from more than one spec level. Used to ride on the
      ## `seenBy` gate, which can't do it now that a same-tier Arg is
      ## appended to rather than skipped.
    complained: HashSet[Arg]
      ## Ensures an Arg reachable from two spec levels only draws one
      ## oversupply complaint -- that branch applies nothing, so `seenBy`
      ## can't gate it the way it gates a real application. See ADR 0039.

  Reach = tuple[idx, subIdx: int]
    ## How far into the user's input a path got (`CONTEXT.md`): the argv
    ## position of the first token it could not consume, plus how many letters
    ## of that token a Short-Option Cluster peel already accounted for.
    ## Lexicographic, so `subIdx` only ever breaks a tie *within* one physical
    ## argument and never outweighs reaching the next one. See ADR 0036.

  ParseContext = object
    maxReach: Reach       ## The greatest Reach of any path explored from this state -- both the running bar siblings are ranked against and, once the walk returns, what the parent reads back as this branch's descendant Reach. See `reach` and ADR 0036
    spec: Spec            ## The spec for the *live* walk position -- consulted by classify()/match() as the walk progresses; never retroactively overwritten by a failed sibling's own descent (see errorSpec)
    command: string       ## The command string up to the current subcommand, for the live walk position -- see `spec`
    errorSpec: Spec       ## Spec for the furthest-reaching fsm path's own failure, for the final error message only -- must stay separate from `spec`, see ADR 0019 point 7
    errorCommand: string  ## See `errorSpec`
    messages: seq[Complaint] ## A list of complaints indicating failure reason of the furthest-reaching fsm path
    errorTokens: seq[Leftover] ## What the furthest-reaching fsm path left over, for `finalComplaints` to name. Merged across Reach-tied siblings exactly as `messages` is -- see ADR 0036
    tokens: seq[RawToken]     ## The arguments left to be parsed
    optsEnd: bool          ## Whether this path has crossed a literal `--` -- see ADR 0019
    matches: MatchTable   ## A table of processed matches
    env: ValueCursor        ## Value Precedence's environment-variable tier -- see `ValueCursor`
    configValues: ValueCursor ## Value Precedence's Config Source tier -- see `ValueCursor`

  RawToken = object
    ## A raw command-line token, classified only as far as pure string shape
    ## can tell without consulting a `Spec` -- see ADR 0019.
    raw: string     ## The literal token as typed
    optShape: bool  ## True if `raw` looks like `-o`/`--opt`/`-o=val`/
      ## `--opt=val`, or a `-xyz`-shaped cluster candidate
    idx: int        ## Original position in the CLI argv -- a peeled
      ## cluster remainder inherits its parent token's `idx` rather than
      ## getting a fresh one. Lets Flag Operation composition sort by true
      ## typed order instead of grammar/push order -- see `parseAllValues`.
    subIdx: int     ## How many letters have been peeled off this token's
      ## parent cluster -- 0 for anything the user typed. Ranking-only, and
      ## deliberately separate from `idx`, which must keep naming the whole
      ## physical argument for composition order. See `Reach`.
    cluster: string ## The Short-Option Cluster this token was peeled from --
      ## empty when `raw` *is* what the user typed, which is what
      ## `fromCluster` tests. Peeling destroys the original, so a complaint
      ## about `-1.5`'s leftover has no other way to say where `-.` came
      ## from. Read through `userTyped`, never directly. See ADR 0038.

  Classification = object
    ## What a `RawToken` actually is, resolved lazily against a `Spec` --
    ## see `classify`, ADR 0019. `consumed`/`remainder` feed `consume`.
    consumed: int
    remainder: string
    starvedOpt: Arg ## Set when this token *is* a declared Optional but no
      ## value is available for it. The non-accepting outcome that lets the
      ## leftover-token complaint tell "name unknown" from "name known, no
      ## value" apart -- see `docs/adr/0034-strict-option-checking.md`.
      ## `kind` is still `Positional` here (there is no accepting
      ## classification to report), so consult this before trusting it.
    starvedName: string ## The variant `starvedOpt` was spelled as
    case kind: ArgKind
    of Command:
      cmd: CommandArg
      cmdName: string
    of Optional:
      opt: Arg
      optName: string
      optVal: string
      optSep: string
    of Flag:
      flag: Arg
      flagName: string
    of Positional:
      argVal: string

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

proc complaint(kind, subject: string, names = false): Complaint =
  ## Builds a `Complaint`. Pass `names = true` for a Naming Complaint, one
  ## pointing at a specific token the user typed -- see `Complaint.names`
  ## and ADR 0035.
  (kind, subject, names)

proc osaDistance(a, b: seq[Rune]): int =
  ## Damerau-Levenshtein, optimal string alignment: an adjacent
  ## transposition costs 1. Hand-rolled over `Rune`s -- `std/editdistance`
  ## has no transposition variant and its ASCII one splits multi-byte
  ## characters. See ADR 0035.
  var d = newSeq[seq[int]](a.len + 1)
  for i in 0 .. a.len:
    d[i] = newSeq[int](b.len + 1)
    d[i][0] = i
  for j in 0 .. b.len:
    d[0][j] = j
  for i in 1 .. a.len:
    for j in 1 .. b.len:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      d[i][j] = min(min(d[i - 1][j] + 1, d[i][j - 1] + 1), d[i - 1][j - 1] + cost)
      if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
        d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
  d[a.len][b.len]

proc bareName(variant: string): string =
  ## `variant` with its leading dashes stripped -- measuring the full
  ## spelling inflates every threshold. See ADR 0035.
  variant.strip(trailing = false, chars = {'-'})

const MinSuggestable = 2
  ## Shortest dash-stripped name did-you-mean will offer: a one-character
  ## name is one edit from every other, so it carries no signal. By the
  ## option PEGs' shapes this is exactly "never suggest a short option".
  ## See ADR 0035.

proc didYouMean(typed: string, candidates: seq[string]): string =
  ## `"; did you mean --port?"` for whichever of `candidates` sit within
  ## `min(2, max(1, n div 4))` of `typed`, `n` being the candidate's own
  ## dash-stripped length; all tied at the best distance, sorted. The cap is
  ## load-bearing. Eligibility of `typed` is `unknownOption`'s call, not
  ## this one's. See ADR 0035.
  let word = typed.bareName.toRunes
  var best = high(int)
  var hits: seq[string]
  for candidate in candidates.sorted:
    let name = candidate.bareName.toRunes
    if name.len < MinSuggestable:
      continue
    # Known but unusable *here* rather than misspelled; "did you mean add?"
    # for a token spelled `add` is nonsense.
    if candidate == typed:
      continue
    let distance = osaDistance(word, name)
    if distance > min(2, max(1, name.len div 4)):
      continue
    if distance < best:
      (best, hits) = (distance, @[candidate])
    elif distance == best:
      hits.add candidate
  if hits.len == 0: ""
  elif hits.len == 1: "; did you mean {hits[0]}?".fmt
  else: "; did you mean {hits[0 ..^ 2].join(\", \")} or {hits[^1]}?".fmt

proc isShortForm(variant: string): bool =
  ## Whether `variant` is written as a short option -- exactly one leading
  ## dash. A Command name (no dash at all) is never short-form.
  variant.len > 1 and variant[0] == '-' and variant[1] != '-'

proc userTyped(token: RawToken): string =
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

proc unknownOption(token: RawToken, spec: Spec): Complaint =
  ## Names an option-shaped token nothing in `spec` declares. The two arms
  ## are exclusive by construction: only a short form is narrowed and carries
  ## an origin, only a long form draws a suggestion. See ADR 0038.
  let subject =
    if token.raw.isShortForm:
      # Cluster syntax, so the failing unit is one letter: name that, and say
      # which typed token it came out of, since the letter may be neither
      # what they typed nor something they'd recognize. The tail past it is
      # never named -- untested, and may hold declared options. It draws no
      # suggestion for the same reason: `--ab` is not what `-ab` meant, at
      # most `-a` is (ADR 0035).
      let name = if token.raw.len > 2: token.raw[0 .. 1] else: token.raw
      if token.userTyped == name: name
      else: "{name} (in {token.userTyped})".fmt
    else:
      token.raw & didYouMean(token.raw, toSeq(spec.options.keys))
  complaint("unrecognized option", subject, names = true)

proc unknownCommand(word: string, spec: Spec): Complaint =
  ## Names a token sitting where `spec` expected one of its commands.
  complaint("unrecognized command",
    word & didYouMean(word, toSeq(spec.commands.keys)), names = true)

proc isOptShape(raw: string): bool =
  ## Pure string-shape recognition needing no `Spec` -- see ADR 0019.
  raw =~ OptionFormat or raw =~ OptionValueFormat or
    (raw.len > 2 and raw[0] == '-' and raw[1] != '-')

proc isNonOptionShort(raw: string): bool =
  ## A **Non-Option Short**: one leading dash whose second character isn't
  ## an ASCII letter (`-5`, `-.5`, `-1e9`, `-0x1F`, `-+3`, `-5x`). Two
  ## leading dashes never qualify. Shape only, deliberately *not* "parses
  ## as a number" -- that admits `-inf`/`-nan` while rejecting `-0x1F`/
  ## `-+3`. See `docs/adr/0034-strict-option-checking.md`.
  raw.len > 1 and raw[0] == '-' and raw[1] != '-' and
    raw[1] notin {'a'..'z', 'A'..'Z'}

proc exemptFromStrict(token: RawToken): bool =
  ## Whether Strict Option Checking never applies to `token`. A Non-Option
  ## Short qualifies only when the user actually typed it: a peeled `-abc`
  ## remainder is a cluster continuation, so `-1.5`'s leftover `-.5` is
  ## still an unrecognized option exactly as `-1x`'s `-x` is. See
  ## `RawToken.fromCluster`.
  token.raw.isNonOptionShort and not token.fromCluster

proc mustResolve(token: RawToken): bool =
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

proc refusesAsValue(spec: Spec, token: RawToken): bool =
  ## Whether Strict Option Checking stops `token` filling a declared
  ## Optional's value slot, so `--name --help` starves rather than setting
  ## `name` to `"--help"`. Same setting as the positional slot
  ## (`refusesAsPositional`); with strict off an option-shaped token still
  ## counts as a value and starvation needs end of input.
  spec.settings.strictOptions and token.mustResolve

proc starved(option: Arg, variant, raw: string): Classification =
  ## A declared Optional with no value available for it -- see
  ## `Classification.starvedOpt`.
  Classification(kind: Positional, argVal: raw, consumed: 1,
    starvedOpt: option, starvedName: variant)

proc classify(spec: Spec, tokens: seq[RawToken], pos: int, optsEnd: bool): Classification =
  ## Decides what `tokens[pos]` is against `spec`'s tables -- the lazy half
  ## of ADR 0019. Never raises: an unresolved option-shaped token falls
  ## through to the `Positional` fallback at the bottom.
  let token = tokens[pos]
  if optsEnd:
    return Classification(kind: Positional, argVal: token.raw, consumed: 1)
  if token.raw in spec.commands:
    return Classification(kind: Command, cmd: spec.commands[token.raw], cmdName: token.raw, consumed: 1)
  if token.optShape:
    # Bare `-o`/`--option`; an Optional's value comes from the next token.
    if token.raw =~ OptionFormat:
      let variant = token.raw
      if variant in spec.options:
        let option = spec.options[variant]
        case option.kind
        of Flag:
          return Classification(kind: Flag, flag: option, flagName: variant, consumed: 1)
        of Optional:
          if pos + 1 < tokens.len and not spec.refusesAsValue(tokens[pos + 1]):
            return Classification(kind: Optional, opt: option, optName: variant, optVal: tokens[pos + 1].raw, consumed: 2)
          # Declared, but nothing usable follows -- a starved option, not an
          # unknown name. Errors under both settings.
          return starved(option, variant, token.raw)
        else: discard
    # `-o=val` / `--option=value`.
    elif token.raw =~ OptionValueFormat:
      let (variant, sep, value) = (matches[0], matches[1], matches[2])
      if variant in spec.options and spec.options[variant].kind == Optional:
        return Classification(kind: Optional, opt: spec.options[variant], optName: variant, optSep: sep, optVal: value, consumed: 1)
    # A cluster of short options (`-abc`). Only the first letter resolves
    # here -- a Flag leaves the rest as `remainder` for `consume` to
    # reinsert; an Optional swallows the rest as its value. See ADR 0019
    # point 2 on why this can't be decided eagerly.
    elif token.raw.len > 2 and token.raw[0] == '-' and token.raw[1] != '-':
      let variant = "-" & token.raw[1]
      if variant in spec.options:
        let option = spec.options[variant]
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

proc refusesAsPositional(pc: ParseContext, pos: int, c: Classification): bool =
  ## Whether an `Argument` matcher must decline `pc.tokens[pos]` as opaque
  ## literal text -- refuse-to-match, never raise, so the token stays
  ## leftover for `walk` to word and backtracking survives. See ADR 0034.
  ##
  ## A starved declared Optional is refused whatever `strictOptions` says;
  ## otherwise this is ADR 0019 gap 3's case, and `pc.optsEnd` is what
  ## exempts a post-`--` token -- `classify` short-circuits it to a plain
  ## `Positional` that would otherwise look exactly like an unknown option.
  if not c.starvedOpt.isNil:
    return true
  pc.spec.settings.strictOptions and not pc.optsEnd and c.kind == Positional and
    pc.tokens[pos].mustResolve

proc consume(pc: var ParseContext, pos: int, c: Classification) =
  ## Removes/reinserts the raw token(s) an accepted `Classification`
  ## accounts for at `pos` -- see `classify`'s cluster branch, ADR 0019.
  let parent = pc.tokens[pos]
  pc.tokens.delete pos
  if c.consumed == 2:
    pc.tokens.delete pos # the value that was tokens[pos + 1]
  elif c.remainder.len > 0:
    # Inherits the parent token's idx -- it's the same physical CLI argument,
    # just partially consumed -- but advances `subIdx`, one more letter of it
    # now being accounted for. See `RawToken.idx`/`.subIdx`.
    pc.tokens.insert(RawToken(raw: c.remainder, optShape: c.remainder.isOptShape,
      idx: parent.idx, subIdx: parent.subIdx + 1,
      # Carried so a complaint can say which typed token this came out of;
      # peeling destroys it otherwise. Also what makes `fromCluster` true.
      cluster: parent.userTyped), pos)

proc consumeOptsEnd(pc: var ParseContext, pos: int): bool =
  ## Drops a not-yet-consumed literal `--` at `pos` and marks this path
  ## past the end of options -- see ADR 0019. Returns whether it did so,
  ## so callers can re-examine `pos` without incrementing.
  if not pc.optsEnd and pc.tokens[pos].raw == "--":
    pc.tokens.delete pos
    pc.optsEnd = true
    result = true

proc push(matches: var MatchTable, arg: Arg, spec: Spec, variant: string, value = "", idx = 0) =
  ## Adds a matched arg's seen variant and value to the table of matches,
  ## tagged with the Spec it was matched under (`spec`, i.e. the spec
  ## level whose own grammar this match's Matcher belongs to) -- needed so
  ## `dispatch` (`Spec.parse`'s tail) can tell apart two independent real
  ## matches of the same `Arg` reachable at two different grammar levels
  ## from one match seen twice. See
  ## `docs/adr/0009-command-before-action-after-hooks.md`. `idx` is the
  ## originating token's `RawToken.idx`, or `0` for a Command match (never
  ## composed, so its ordering doesn't matter -- see `Match`).
  if matches.hasKeyOrPut(arg, @[(variant, value, spec, idx)]):
    matches[arg].add (variant, value, spec, idx)

proc resolveEnv(arg: Arg, spec: Spec): options.Option[seq[string]] =
  ## Resolver for `ValueCursor.probe`'s env tier -- see architecture.md's
  ## "Env var mechanics".
  let envName = arg.envName
  if envName.len == 0 or not existsEnv(envName):
    none(seq[string])
  else:
    some(splitEnvValue(getEnv(envName), arg.envDelim, spec.settings.envDelim))

proc resolveConfig(arg: Arg, spec: Spec): options.Option[seq[string]] =
  ## Resolver for `ValueCursor.probe`'s Config Source tier -- see
  ## `docs/adr/0018-config-source.md`.
  let key = arg.configKey
  if key.len == 0:
    none(seq[string])
  else:
    lookupConfigSources(spec.settings.configSources, key)

proc probe(cursor: var ValueCursor, arg: Arg, resolve: proc (): options.Option[seq[string]]): bool =
  ## Lets a fallback tier's value stand in for a missing CLI value during
  ## the walk -- see `ValueCursor`. `resolve` is called at most once per
  ## `arg` for the life of `cursor` (see `ValueCursor.tried`). Returning
  ## `false` just lets the walk fail normally; the actual value-setting
  ## happens later, in `applyFallbacks`'s post-walk sweep.
  if arg notin cursor.tried:
    cursor.tried.incl arg
    let found = resolve()
    if found.isSome:
      cursor.values[arg] = found.get
  if arg notin cursor.values:
    return false
  let consumed = cursor.consumed.getOrDefault(arg, 0)
  if consumed < cursor.values[arg].len:
    cursor.consumed[arg] = consumed + 1
    return true

proc addUnique(pc: var ParseContext, entry: Complaint) =
  ## Adds `entry` unless already present -- a starved option is reachable
  ## down more than one branch, and the same line twice reads as a bug in
  ## the parser rather than in the input.
  if entry notin pc.messages:
    pc.messages.add entry

proc addLeftover(pc: var ParseContext, leftover: Leftover) =
  ## Records `leftover` unless one naming the same token is already there --
  ## two branches failing on the same token mustn't produce the line twice.
  if not pc.errorTokens.anyIt(it.tokens[0].raw == leftover.tokens[0].raw):
    pc.errorTokens.add leftover

proc addLeftover(pc: var ParseContext) =
  ## Records what this branch couldn't consume, for `finalComplaints` to
  ## word later.
  if pc.tokens.len > 0:
    pc.addLeftover((pc.tokens, pc.spec, pc.optsEnd))

proc starvedComplaint(c: Classification): Complaint =
  ## The unconditional "declared, but nothing to give it" complaint -- see
  ## `docs/adr/0034-strict-option-checking.md`.
  complaint("missing value", "option {c.starvedName} requires a value".fmt, names = true)

proc addStarved(pc: var ParseContext): bool =
  ## Complains that the leading token is a declared option left without a
  ## value, when that's what it is, plus the option-shaped token that
  ## starved it when there is one -- both, never one masking the other.
  ## Returns whether it complained, so callers can fall back to recording a
  ## plain leftover for `finalComplaints` to word.
  ##
  ## Classifies for itself rather than taking a `Classification`: the
  ## `[options]` catch-all has to re-ask after rolling its own per-probe
  ## messages back. See ADR 0034.
  if pc.tokens.len == 0 or not pc.tokens[0].optShape:
    return false
  let c = classify(pc.spec, pc.tokens, 0, pc.optsEnd)
  if c.starvedOpt.isNil:
    return false
  pc.addUnique starvedComplaint(c)
  if pc.tokens.len > 1 and pc.tokens[1].mustResolve:
    # Named only when genuinely unknown -- the token that starved this one
    # may be a declared option itself (`--port --port 80`), and calling
    # *that* unrecognized is the wording ADR 0034 exists to fix.
    let starver = classify(pc.spec, pc.tokens, 1, pc.optsEnd)
    if starver.kind == Positional and starver.starvedOpt.isNil:
      pc.addUnique unknownOption(pc.tokens[1], pc.spec)
  true

proc match(m: Matcher, pc: var ParseContext, atTerminal = false): bool =
  ## Checks if `m` matches a token in `tokens`. May consume a token and may add
  ## a variant and value to `matches`. Returns whether the match was successful.
  ##
  ## `atTerminal` is whether the state this transition leaves was terminal --
  ## the grammar could have stopped here, so an `Argument` that finds nothing
  ## was never owed. See ADR 0037.
  case m.kind:
  of Shortcut:
    # A shortcut consumes no tokens and always indicates success.
    result = true
  of OptsEnd:
    # Always matches, forcing pc.optsEnd regardless of whether a literal
    # `--` is actually there to consume -- see ADR 0020.
    if pc.tokens.len > 0:
      discard pc.consumeOptsEnd(0)
    pc.optsEnd = true
    result = true
  of Argument:
    # Skip Option/Flag-classified tokens (order-independent -- see ADR
    # 0019). A Command-classified token is accepted as literal text just
    # like a Positional one -- the scan must not skip past it looking
    # further ahead, see ADR 0019 point 6 on why that breaks ordering.
    var pos = 0
    while pos < pc.tokens.len:
      if pc.consumeOptsEnd(pos):
        continue
      let c = classify(pc.spec, pc.tokens, pos, pc.optsEnd)
      case c.kind
      of Positional, Command:
        if pc.refusesAsPositional(pos, c):
          # Left unconsumed so it survives as a leftover for `walk` to name
          # -- see `refusesAsPositional`.
          pos.inc
        else:
          pc.matches.push(m.arg, pc.spec, m.arg.name, pc.tokens[pos].raw, pc.tokens[pos].idx)
          pc.consume(pos, c)
          result = true
          break
      else:
        pos.inc
    if not result and pc.matches.getOrDefault(m.arg).len == 0:
      # Only report a genuinely-unmatched arg -- if this arg already matched
      # at least once (a satisfied `<arg>...` repeat), a failed attempt at
      # *another* repeat isn't a real deficiency worth reporting.
      if not atTerminal:
        pc.messages.add complaint("missing argument", m.arg.name)
      # A starved option is why nothing was left to match, and this path
      # never reaches `walk`'s tail -- see `addStarved`. Asked whether or not
      # the complaint above was suppressed: that's about this arg, not it.
      discard pc.addStarved()
  of Command:
    # If the next token classifies as this specific command, consume it and
    # return true. Otherwise return false -- a Command matcher never scans
    # past position 0 (see `docs/architecture.md`).
    if pc.tokens.len > 0 and not pc.consumeOptsEnd(0):
      let c = classify(pc.spec, pc.tokens, 0, pc.optsEnd)
      if c.kind == Command and c.cmd == m.cmd:
        pc.matches.push(m.cmd, pc.spec, c.cmdName, idx = pc.tokens[0].idx)
        pc.command = fmt"{pc.command} {c.cmdName}"
        pc.spec = m.cmd.spec
        pc.consume(0, c)
        result = true
    if not result:
      pc.messages.add complaint("missing command", m.cmd.name)
      # A Command matcher never scans past position 0, so it's the one place
      # that knows a Command was expected *here* -- see ADR 0035.
      pc.addLeftover()
  of Option:
    # Skip tokens that don't classify as *this* opt so option/arg order
    # doesn't matter -- see the Argument branch above on why a
    # Command-classified token doesn't need special-casing here either.
    var pos = 0
    while pos < pc.tokens.len:
      if pc.consumeOptsEnd(pos):
        continue
      let c = classify(pc.spec, pc.tokens, pos, pc.optsEnd)
      case c.kind
      of Optional:
        if c.opt == m.opt:
          pc.matches.push(c.opt, pc.spec, c.optName, c.optVal, pc.tokens[pos].idx)
          pc.consume(pos, c)
          return true
      of Flag:
        if c.flag == m.opt:
          # If m.variant == "", this flag was reached through the [options]
          # catch-all. Otherwise, we want to see if the seen variant is an
          # alias for the one in the usage line (aliases() is reflexive, so
          # this also covers an exact literal match). A mismatch just skips
          # (falls through to pos.inc below) rather than blocking the scan --
          # composition order is handled downstream by `RawToken.idx`, not by
          # forcing this scan to find tokens in grammar-declaration order.
          if m.variant == "" or m.opt.aliases(m.variant, c.flagName):
            pc.matches.push(c.flag, pc.spec, c.flagName, c.flagName, pc.tokens[pos].idx)
            pc.consume(pos, c)
            return true
      else:
        discard
      pos.inc

    # No CLI token matched; let the configured env var, then a Config
    # Source, stand in instead -- see architecture.md's "Env var
    # mechanics" and `docs/adr/0018-config-source.md`. `spec` is copied
    # out to a local `let` first -- the closures below can't capture `pc`
    # itself (a `var ParseContext` parameter) without violating memory
    # safety.
    let spec = pc.spec
    if pc.env.probe(m.opt, () => resolveEnv(m.opt, spec)):
      return true
    if pc.configValues.probe(m.opt, () => resolveConfig(m.opt, spec)):
      return true

    # Unconditional on purpose -- a `m.opt notin pc.matches` guard can't tell
    # one occurrence from two; see ADR 0035's rejected third rule.
    pc.messages.add complaint("missing option",
      if m.variant.len > 0: m.variant else: m.opt.name)
    # A failed Option matcher never reaches `walk`'s tail, so it records its
    # own leftover -- see ADR 0035, and ADR 0019 point 4 on why this can't
    # live in tokenization.
    if not pc.addStarved() and pc.tokens.len > 0 and pc.tokens[0].optShape:
      if classify(pc.spec, pc.tokens, 0, pc.optsEnd).kind == Positional:
        pc.addLeftover()
  of Options:
    # Try each option in m.opts (see ADR 0002 for the catch-all repeat rule).
    for (opt, variant) in zip(m.opts, m.variants):
      # Probe only: roll a failed probe's complaints and leftovers back, and
      # add nothing in their place -- a catch-all option is optional by
      # construction, so it can never be missing (ADR 0035's rule 1).
      let (before, beforeTokens) = (pc.messages.len, pc.errorTokens.len)
      if newOptMatcher(opt, variant).match(pc):
        result = true
      else:
        pc.messages.setLen(before)
        pc.errorTokens.setLen(beforeTokens)
    if not result:
      # Re-asked past the rollback above: a starved option can never be
      # consumed as anything else, so it's the real error however the
      # probes went -- see `addStarved`.
      discard pc.addStarved()

proc reach(pc: ParseContext): Reach =
  ## This path's Reach (`CONTEXT.md`): where the first token it could not
  ## consume sits, or `int.high` if it consumed everything. Ranks failed
  ## branches in `walk` -- see ADR 0036.
  if pc.tokens.len == 0: (int.high, 0)
  else: (pc.tokens[0].idx, pc.tokens[0].subIdx)

proc walk(s: State, pc: var ParseContext): bool =
  ## Recursively matches each transition in `s` until a terminal state is
  ## reached or all branches have been tried. Returns `true` if a terminal state
  ## was reached. Matched values may be stored in `pc` by matchers.
  if s.terminal and pc.tokens.len == 0:
    return true

  # Try each transition. If it matches, recursively descend into the next state.
  for idx, tr in s.transitions:
    var fresh = pc
    # `pc.maxReach` is this level's running best across siblings; the copy
    # re-purposes the field as the descent's own output, so start it fresh.
    fresh.maxReach = (0, 0)
    if tr.matcher.match(fresh, atTerminal = s.terminal):
      fresh.messages = @[]
      fresh.errorTokens = @[]
      if tr.next.walk(fresh):
        pc = fresh
        return true

    # A failed descent leaves `fresh.tokens` where this transition left them,
    # so the branch's real Reach is whatever its deepest descendant managed.
    let branchReach = max(fresh.reach, fresh.maxReach)
    if branchReach > pc.maxReach or (pc.messages.len == 0 and pc.errorTokens.len == 0):
      # `maxReach` only ever rises -- adopting a lesser branch's complaints
      # must not lower the bar later siblings tie against. See ADR 0036.
      pc.maxReach = max(pc.maxReach, branchReach)
      pc.errorSpec = fresh.spec
      pc.messages = fresh.messages
      pc.errorTokens = fresh.errorTokens
      pc.errorCommand = fresh.command
    elif branchReach == pc.maxReach:
      # A Reach-tied sibling merges its complaints into the running set
      # instead of replacing it outright -- two same-kind failures (e.g.
      # both `-h` and `--verbose` missing at the same [options] position)
      # are meant to accumulate onto one grouped line via formatComplaints.
      # Without the merge, whichever sibling happens to run last would
      # silently discard an equally-valid earlier complaint. See ADR 0036 for
      # why the exclusivity case this used to be justified by no longer is.
      for msg in fresh.messages:
        if msg notin pc.messages:
          pc.messages.add msg
      # Same terms, same reason.
      for leftover in fresh.errorTokens:
        pc.addLeftover leftover

  # Every transition failed at a state the grammar would have stopped at, so
  # what's left is the token the user got wrong. Starved goes first (ADR
  # 0034); the guard keeps a deeper offender surfacing over this one (0035).
  if s.terminal and pc.tokens.len > 0 and pc.errorTokens.len == 0:
    if not pc.addStarved():
      pc.addLeftover()

type
  Frontier = seq[tuple[state: State, pc: ParseContext]]
    ## Every `State` simultaneously still reachable after consuming a given
    ## prefix of tokens, paired with the `ParseContext` that reached it --
    ## see `collectFrontier`.

proc collectFrontier(s: State, pc: ParseContext, acc: var Frontier, seen: var HashSet[State]) =
  ## Generalizes `walk` into "every live branch, not just the first to
  ## succeed" for shell completion -- see architecture.md §6.
  ##
  ## `seen` only bounds zero-token transitions (a `Shortcut`, or an
  ## env-satisfied `Option`); anything that consumes a real token recurses
  ## with a fresh `seen`, since that's a strictly smaller sub-problem.
  ## Revisiting a `State` within one zero-token layer can't discover
  ## anything new, since its transitions and `pc.tokens` are unchanged --
  ## so skipping it is safe, not just an optimization.
  if s in seen:
    return
  seen.incl s

  if pc.tokens.len == 0:
    acc.add (s, pc)

  for tr in s.transitions:
    var fresh = pc
    # `atTerminal` stays false: completion collects live branches, never
    # complaints, so the suppression it gates is moot here -- see ADR 0037.
    if tr.matcher.match(fresh, atTerminal = false):
      if fresh.tokens.len < pc.tokens.len:
        var freshSeen: HashSet[State]
        collectFrontier(tr.next, fresh, acc, freshSeen)
      else:
        collectFrontier(tr.next, fresh, acc, seen)

type
  CompletionCandidate* = tuple[value: string, help: string]
    ## One shell-completion candidate -- `value` is the literal word offered,
    ## `help` is a short description (possibly `""`) for shells that can
    ## render one (fish, zsh) -- see `docs/adr/0022-completion-candidate-
    ## help-text.md`. `help` is only ever non-empty for an Arg's own name
    ## (option/flag/command); a *value* candidate (an enumerable
    ## positional's or Choice validator's own values) always carries `""`,
    ## since there's no per-value description in the data model to draw
    ## from -- see architecture.md §6.

proc bareVariants(spec: Spec, arg: Arg, variant = ""): seq[string] =
  ## The bare option/flag spellings actually typed on the command line for
  ## `arg` (e.g. "--log-level", never "--log-level=<level>"). Reads
  ## `spec.options`, the same canonical bare-name -> Arg map `classify`
  ## itself looks up against, rather than re-deriving stripping logic from
  ## `arg.variants` -- for an Optional-kind `ValueArg` (`opt`/`args`),
  ## `variants` stores the *declared* string verbatim, including any
  ## `=<placeholder>` suffix used only for help-text rendering (`FlagArg`
  ## already stores bare names at construction time, so this is a no-op for
  ## it, but reusing one rule for both is simpler than branching by kind).
  ##
  ## When `variant` is non-empty, only variants that are `arg.aliases` of it
  ## are returned (`aliases` is reflexive, so this covers an exact literal
  ## match too) -- so a specific `Option`-kind transition (`candidateWords`)
  ## offers just its own FlagOp Alias set (e.g. `-u`'s completion never
  ## includes `-d`'s), rather than every variant `arg` has anywhere on the
  ## usage line. A no-op for non-Flag Args, whose base `aliases` always
  ## returns true for any two of their own variants. Leave `variant` blank
  ## for a catch-all context (e.g. `[options]`'s `Options`-kind matcher, or
  ## `pendingOptionalArgs`'s "was this bare word typed at all" check) where
  ## every variant genuinely applies.
  for k, v in spec.options:
    if v == arg and (variant.len == 0 or arg.aliases(variant, k)):
      result.add k

proc describeVariants(arg: Arg, variants: seq[string]): seq[CompletionCandidate] =
  ## Pairs each of `arg`'s own `variants` with its most useful description.
  ## `arg.variantDesc(v)` (e.g. a flag's auto-generated "Increase by 5", or
  ## a `flagOp*` call's own `help` override -- see `flag*`) is only trusted when `arg`'s
  ## variants genuinely diverge in what they do, i.e. `variantDesc` returns
  ## more than one distinct value across them; otherwise every variant
  ## shares `arg.help`. This mirrors `help.variantGroups`'s own
  ## "collapse to one group whenever every variant agrees" rule (used by
  ## `genHelp`) -- without it, an ordinary flag with no divergent variants
  ## (e.g. a bare bool `flag("--verbose", help = "Be noisy")`) would show
  ## its type's auto-generated blank-op description ("Toggle the value")
  ## instead of its own `help`, since `variantDesc`'s base case for a
  ## non-divergent flag still returns that blank description, not `""`.
  var descs: seq[string]
  for v in variants:
    descs.add arg.variantDesc(v)
  let divergent = descs.toHashSet.len > 1
  for i, v in variants:
    let desc = descs[i]
    result.add (v, if divergent and desc.len > 0: desc else: arg.help)

proc addUnseen(result: var seq[CompletionCandidate], seen: var HashSet[string],
    candidates: openArray[CompletionCandidate], prefix: string) =
  ## Appends each of `candidates` whose `.value` starts with `prefix` and
  ## hasn't already been seen (via `seen`, keyed on `.value` alone) into
  ## `result`, preserving first-seen-wins order -- the dedup rule shared by
  ## `candidateWords` and `completeArgs*`'s own pending-value branch.
  for c in candidates:
    if c.value.startsWith(prefix) and c.value notin seen:
      seen.incl c.value
      result.add c

proc candidateWords(frontier: Frontier, prefix: string): seq[CompletionCandidate] =
  ## Reads every live frontier state's own outgoing transitions for literal
  ## next-word spellings (option/flag variants, command variants, or an
  ## enumerable positional's `completions()`), keeping only ones starting
  ## with `prefix` and deduplicating while preserving first-seen (== FSM
  ## priority/declaration) order.
  var seen: HashSet[string]
  for (state, pc) in frontier:
    for tr in state.transitions:
      let candidates =
        case tr.matcher.kind
        of Option: describeVariants(tr.matcher.opt, pc.spec.bareVariants(tr.matcher.opt, tr.matcher.variant))
        of Options:
          collect:
            for opt in tr.matcher.opts:
              for c in describeVariants(opt, pc.spec.bareVariants(opt)): c
        of Command: describeVariants(tr.matcher.cmd, tr.matcher.cmd.variants)
        of Argument:
          collect:
            for v in tr.matcher.arg.completions(): (v, "")
        of OptsEnd: newSeq[CompletionCandidate]() # invisible -- see ADR 0020 point 8
        of Shortcut: newSeq[CompletionCandidate]()
      result.addUnseen(seen, candidates, prefix)

proc pendingOptionalArgs(frontier: Frontier, name: string): seq[Arg] =
  ## Every distinct `Optional`-kind (value-taking, not `Flag`) Arg reachable
  ## from a live frontier state whose variants include `name` exactly --
  ## used by `completeArgs` to detect "the last already-typed word is itself
  ## a bare option name still awaiting its value" (e.g. `--log-level` typed
  ## with nothing after it yet).
  var seenArgs: HashSet[Arg]
  for (state, pc) in frontier:
    for tr in state.transitions:
      var candidates: seq[Arg]
      case tr.matcher.kind
      of Option: candidates = @[tr.matcher.opt]
      of Options: candidates = tr.matcher.opts
      else: discard
      for arg in candidates:
        if arg.kind == Optional and name in pc.spec.bareVariants(arg) and arg notin seenArgs:
          seenArgs.incl arg
          result.add arg

proc completeArgs*(spec: Spec, words: seq[string], command: string): seq[CompletionCandidate] =
  ## Returns shell-completion candidates for `words` -- everything typed
  ## after the `__complete` marker (see `parse*`). The last element of
  ## `words` is the word currently being completed (possibly `""` if the
  ## cursor follows a space with nothing typed for this word yet); every
  ## earlier element is already complete. Never raises -- an unparseable
  ## prefix simply yields no candidates (`collectFrontier` just finds no
  ## live transitions for it), leaving the shell's own file-completion
  ## fallback to take over. See `docs/adr/0012-fsm-driven-shell-completion.md`
  ## and `docs/adr/0022-completion-candidate-help-text.md`.
  let wordBeingCompleted = if words.len > 0: words[^1] else: ""
  let priorWords = if words.len > 0: words[0 ..< words.high] else: newSeq[string]()

  # Case (b): last word is a bare option name awaiting its value --
  # short-circuit to that Arg's completions() (see architecture.md §6).
  if priorWords.len > 0:
    let committed = priorWords[0 ..< priorWords.high]
    var frontier: Frontier
    var seen: HashSet[State]
    var pc = ParseContext(spec: spec, command: command, tokens: tokenizeArgs(committed))
    collectFrontier(spec.fsm, pc, frontier, seen)
    let pending = frontier.pendingOptionalArgs(priorWords[^1])
    if pending.len > 0:
      var seenValues: HashSet[string]
      for arg in pending:
        let candidates = collect:
          for c in arg.completions(): (c, "")
        result.addUnseen(seenValues, candidates, wordBeingCompleted)
      return result

  # Case (a): ordinary "what word can come next" completion.
  var frontier: Frontier
  var seen: HashSet[State]
  var pc = ParseContext(spec: spec, command: command, tokens: tokenizeArgs(priorWords))
  collectFrontier(spec.fsm, pc, frontier, seen)
  result = frontier.candidateWords(wordBeingCompleted)

proc parseMessageArgs(spec: Spec, matches: MatchTable, command: string) =
  ## Parses (and raises on) any matched MessageArg/HelpArg at `spec`'s own
  ## level (per `Match.spec` provenance -- see `push`). Called after
  ## `before`, inside `dispatch`'s try/finally, so a `before`-time mutation
  ## is visible in this level's own message/help output, and `after` still
  ## fires as a guaranteed cleanup even though this raises instead of
  ## returning. Unlike `parseAllValues`, this stays per-level: a shared
  ## MessageArg must fire at the level it was typed at, not the shallowest
  ## one declaring it -- see
  ## `docs/adr/0032-parse-all-values-before-dispatch.md`.
  # Iterates `matches` rather than `spec.args`: a match tagged with this
  # spec can only have come from its own FSM region, so `matchSpec != spec`
  # below already subsumes "declared at this level".
  for arg, ms in matches:
    if not (arg of MessageArg):
      continue
    # See `parseAllValues` on sorting by `Match.idx` instead of push order.
    for (variant, value, matchSpec, _) in ms.sortedByIt(it.idx):
      if matchSpec != spec:
        continue
      arg.action(command, spec, variant)

proc matchedCommand(spec: Spec, matches: MatchTable): tuple[cmd: CommandArg, variant: string] =
  ## The Command actually matched at this spec's own level for this
  ## invocation, if any -- `cmd` is nil if this spec is the dynamic leaf.
  ## At most one Command can ever be matched per spec level: `match`'s own
  ## `Command` branch permanently reassigns `pc.spec` to the matched
  ## command's own nested spec, so a sibling command word can never be
  ## recognized afterward.
  # Iterates `matches` rather than `spec.args`, like `parseMessageArgs`:
  # `matchSpec == spec` already subsumes "declared at this level". Safe to
  # search in table order rather than declaration order precisely because
  # of the at-most-one invariant above -- there is only ever one hit.
  for arg, ms in matches:
    if arg.kind != Command:
      continue
    for (variant, _, matchSpec, _) in ms:
      if matchSpec == spec:
        return (CommandArg(arg), variant)

proc parseAllValues(matches: MatchTable) =
  ## Parses every non-Command, non-MessageArg match across the *whole*
  ## matched tree, before `dispatch` fires any hook -- so no hook runs for
  ## an invocation carrying an unconvertible or invalid value, on any Value
  ## Precedence tier. The env and Config Source tiers already parsed up
  ## front in `applyFallbacks`; this brings the command-line tier in line.
  ## See `docs/adr/0032-parse-all-values-before-dispatch.md`.
  ##
  ## MessageArgs stay behind for `parseMessageArgs`, which `dispatch` still runs
  ## per level after that level's `before` -- see
  ## `docs/adr/0013-message-args-fire-after-before.md`.
  for arg, ms in matches:
    # Sorted by true CLI-token order (`Match.idx`), not push/grammar-position
    # order -- Flag Operations are stateful and often non-commutative (e.g.
    # `clamp`), so composition must follow the order the user actually typed
    # them in, regardless of which usage-line position matched which token.
    for (variant, value, _, _) in ms.sortedByIt(it.idx):
      arg.parse(value, variant, some(byCli))

proc matchedArgs(matches: MatchTable): seq[Arg] =
  ## Every Arg with at least one match in `matches`, across every spec
  ## level -- the raw data behind `HookInfo.matched` (`backend.nim`).
  for arg, ms in matches:
    if ms.len > 0:
      result.add arg

proc dispatch(spec: Spec, matches: MatchTable, command: string, info: HookInfo) =
  ## Recursively dispatches `spec` and, if a Command was matched at its own
  ## level, whichever nested spec that routes to -- firing `before`/
  ## `action`/`after` per `docs/adr/0009-command-before-action-after-hooks.md`.
  ## `info` is computed once by `parse*` and threaded through unchanged, so
  ## every level's hooks see the same whole-invocation view -- see
  ## `docs/adr/0021-hook-info-matched-args.md`.
  ##
  ## Values are already parsed for every matched level by the time this
  ## runs (`parseAllValues`, called from `parse*`), so a hook at any depth
  ## sees the whole tree's values, not just its own level's -- see
  ## `docs/adr/0032-parse-all-values-before-dispatch.md`.
  if not spec.before.isNil:
    spec.before(info)
  try:
    parseMessageArgs(spec, matches, command)
    let (cmd, variant) = matchedCommand(spec, matches)
    if cmd.isNil:
      if not spec.action.isNil:
        spec.action(info)
    else:
      dispatch(cmd.spec, matches, "{command} {variant}".fmt, info)
  finally:
    if not spec.after.isNil:
      spec.after(info)

proc formatComplaints(messages: seq[Complaint]): string =
  ## Renders `messages` as a bulleted block, grouping same-kind complaints
  ## onto one " | "-joined line. No leading newline -- the caller owns the
  ## separation from its own prefix (see `parseOrQuit*`, `argumint.nim`).
  var subjectsByKind = initOrderedTable[string, seq[string]]()
  for (kind, subject, _) in messages:
    if subject notin subjectsByKind.getOrDefault(kind, @[]):
      subjectsByKind.mgetOrPut(kind, @[]).add subject
  var lines: seq[string]
  for kind, subjects in subjectsByKind.pairs:
    let joined = subjects.join(" | ")
    let subject = if subjects.len > 1: "({joined})".fmt else: joined
    lines.add (if kind.len > 0: "  - {kind}: {subject}".fmt else: "  - {subject}".fmt)
  lines.join("\n")

proc finalComplaints(pc: ParseContext): seq[Complaint] =
  ## The message the user actually sees, built from what the walk
  ## accumulated: name the offending token, then drop the complaints that
  ## naming makes redundant. See `docs/adr/0035-parse-failure-reporting.md`.
  result = pc.messages
  var named = result.anyIt(it.names)
  if not named:
    # Worded from what the grammar expected here, not the token's shape --
    # `shp` is lexically a positional. See ADR 0035.
    let wantedCommand = result.anyIt(it.kind == "missing command")
    for leftover in pc.errorTokens:
      let (tokens, spec, optsEnd) = leftover
      let c = classify(spec, tokens, 0, optsEnd)
      # Only a token that could have *been* a command qualifies: an
      # option-shaped one is an option problem, and past a `--` nothing is a
      # command name. Both guards needed, or this arm swallows every leftover.
      let mistypedCommand = wantedCommand and c.kind != Command and
        not optsEnd and not tokens[0].optShape
      result.add:
        if not c.starvedOpt.isNil: starvedComplaint(c)
        elif mistypedCommand: unknownCommand(tokens[0].raw, spec)
        else:
          case c.kind
          of Command: complaint("unexpected command", c.cmdName, names = true)
          of Flag: complaint("unexpected flag", c.flagName, names = true)
          of Optional: complaint("unexpected option",
            "{c.optName}{c.optSep}{c.optVal}".fmt, names = true)
          of Positional:
            # `optsEnd` consulted directly: past a `--` everything
            # classifies `Positional`, whatever it looks like.
            if tokens[0].optShape and not optsEnd: unknownOption(tokens[0], spec)
            else: complaint("unexpected argument", c.argVal, names = true)
      named = true
  if not named:
    return
  # Once something is named, what the FSM had left to try is noise -- ADR
  # 0035's rule 2. `missing command` goes only when the named token stood in
  # a command's position; the valid set stays visible in the usage block.
  result = result.filterIt(it.kind != "missing option")
  if result.anyIt(it.kind in ["unrecognized command", "unexpected command"]):
    result = result.filterIt(it.kind != "missing command")

proc applyTier(cursor: var ValueCursor, arg: Arg, resolve: proc (): options.Option[seq[string]],
    setValue: proc (values: seq[string]), complaints: var seq[Complaint]): bool =
  ## Applies one Value Precedence fallback tier's contribution to `arg` in
  ## `applyFallbacks`'s post-walk sweep, mirroring `probe`'s own
  ## consumption-count semantics: if the walk actually visited `arg`'s
  ## matcher and pulled values from this tier (`arg in cursor.consumed`),
  ## apply everything the tier had available, or complain if the walk
  ## didn't consume all of it (more values than the grammar had positions
  ## for). If the matcher was visited but `resolve` found nothing (`arg in
  ## cursor.tried` but not `cursor.consumed`), there's nothing to apply --
  ## and, per `ValueCursor.tried`'s own contract, `resolve` must not be
  ## called again here even though it would return the same answer, since
  ## it may be an arbitrarily expensive user-supplied `ConfigSource.lookup`.
  ## Only when the matcher was never visited at all this walk (reachable
  ## only via a different, unmatched Usage Line -- `arg notin cursor.tried`)
  ## does this resolve fresh and apply every available value -- recording
  ## that in `cursor.tried` too, so an Arg reachable from two spec levels
  ## still only resolves once. Returns whether this tier had anything at
  ## all for `arg` -- a real application, or an oversupply complaint --
  ## telling the caller whether to fall through to the next-lower tier.
  if arg in cursor.applied:
    return true
  if arg in cursor.consumed:
    result = true
    let consumed = cursor.consumed[arg]
    let total = cursor.values[arg].len
    if consumed < total:
      if arg notin cursor.complained:
        cursor.complained.incl arg
        let kind = if arg.kind == Flag: "unexpected flag" else: "unexpected option"
        complaints.add complaint(kind, arg.name, names = true)
    else:
      cursor.applied.incl arg
      setValue(cursor.values[arg])
  elif arg notin cursor.tried:
    cursor.tried.incl arg
    let found = resolve()
    if found.isSome:
      result = true
      cursor.applied.incl arg
      setValue(found.get)

proc applyFallbacks(env, configValues: var ValueCursor, spec: Spec, matches: MatchTable,
    complaints: var seq[Complaint]) =
  ## Recurses through every spec level actually entered during this parse
  ## (mirroring `dispatch`'s own recursion -- see architecture.md §5),
  ## falling back to each not-yet-supplied Arg's env var, then (only if env
  ## had nothing) its Config Source value. Deliberately outside `walk`'s
  ## FSM/backtracking, so an Arg only reachable via `[options]` still
  ## picks up its fallback values -- see architecture.md's "Env var
  ## mechanics", `docs/adr/0005-env-supplied-multi-value-options-and-
  ## flags.md`, and `docs/adr/0018-config-source.md` for the
  ## value-count/`ParseError` rules, shared identically by both tiers.
  ##
  ## Each tier is gated on `Arg.seenBy`, which the command-line tier has
  ## already written by the time this runs (`parseAllValues`). The gate skips
  ## only a *strictly* stronger tier: an Arg already at this tier is appended
  ## to, not skipped, so a pre-seed declaring `byEnv` still collects the env
  ## var's own values. Clearing a weaker pre-seed happens where the write
  ## does (`parse`), not here -- a tier consulted but resolving nothing must
  ## leave a pre-seed intact. `ValueCursor.applied`, not this gate, is what
  ## stops an Arg reachable from two spec levels being applied twice.
  ## See `docs/adr/0039-per-arg-provenance.md` and
  ## `docs/adr/0041-parse-is-the-write-surface.md`.
  ##
  ## Runs to completion (or raises) entirely before `dispatch` is called --
  ## so a fallback problem at any level blocks every level's hooks from
  ## firing at all, not just that level's, since `dispatch` never starts.
  for a in spec.args:
    let arg = a # local copy -- a `for` loop's `lent Arg` can't be captured by the closures below
    if arg.seenBy > byEnv:
      continue
    let envHad = applyTier(env, arg, () => resolveEnv(arg, spec),
      proc (values: seq[string]) =
        for v in values:
          arg.parse(v, arg.envName, some(byEnv)),
        complaints)
    if not envHad and arg.seenBy <= byConfig:
      discard applyTier(configValues, arg, () => resolveConfig(arg, spec),
        proc (values: seq[string]) =
          for v in values:
            arg.parse(v, arg.configKey.join, some(byConfig)),
          complaints)

  let (cmd, _) = matchedCommand(spec, matches)
  if not cmd.isNil:
    applyFallbacks(env, configValues, cmd.spec, matches, complaints)

proc parse*(spec: Spec, args: seq[string] = commandLineParams(),
    command = extractFilename(getAppFilename())) =
  ## Creates an FSM for `spec` and attempts to navigate it using `args`. If a
  ## terminal state was reached and all args were consumed, the parse was
  ## successful and each match is parsed into its arg. Raises `ParseError`,
  ## `ValidationError`, `HelpError`, `MessageError`, or `CompletionError` on
  ## failure -- use `parseOrQuit*` (`argumint.nim`) if you want those to
  ## print a message and `quit()` instead.
  ##
  ## `spec` is **single-use**: parsing more than once accumulates into the
  ## same Args rather than starting fresh -- a repeated `opts` appends, a
  ## `flag` keeps applying its Flag Operation, and an `opt` retains an
  ## earlier value into a later parse that never mentioned it. A built
  ## `Spec` has no `parsed*` counterpart (that takes a spec-tuple builder,
  ## `argumint.nim`), so build a fresh `Spec` per parse. See
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  ##
  ## `args[0] == "__complete"` is a shell-completion request (see
  ## `docs/adr/0012-fsm-driven-shell-completion.md`): short-circuits before
  ## any real FSM matching, env fallback, or dispatch (so no `before`/
  ## `action`/`after` hook fires), raising `CompletionError` with the
  ## candidates as its `msg` -- one per line, each `"value\thelp"` (`help`
  ## possibly empty, but the tab always present -- see
  ## `docs/adr/0022-completion-candidate-help-text.md`).
  if args.len > 0 and args[0] == "__complete":
    let lines = collect:
      for c in spec.completeArgs(args[1 ..< args.len], command): "{c.value}\t{c.help}".fmt
    raise newException(CompletionError, lines.join("\n"))

  var pc = ParseContext(spec: spec, command: command, errorSpec: spec, errorCommand: command,
    tokens: tokenizeArgs(args))
  if not spec.fsm.walk(pc):
    raiseParseError(formatComplaints(pc.finalComplaints), pc.errorCommand, pc.errorSpec)

  var fallbackComplaints: seq[Complaint]
  # A conversion/validation failure gets the same complaint-plus-usage shape
  # as any other. Reshaped here because `arg.parse` has no view of its spec
  # -- see ADR 0035.
  template reshaped(body: untyped) =
    try:
      body
    except ParseError as e:
      raiseParseError(formatComplaints(@[complaint("", e.msg)]), pc.command, pc.spec)
    except ValidationError as e:
      raise newException(ValidationError,
        formatComplaints(@[complaint("", e.msg)]).withUsage(pc.command, pc.spec))

  # Tiers applied strongest-first, which is Value Precedence read top-down.
  # Consequence: a bad command-line value now surfaces before a bad env one,
  # where it used to be the other way round -- see ADR 0039.
  reshaped:
    parseAllValues(pc.matches)

  reshaped:
    applyFallbacks(pc.env, pc.configValues, spec, pc.matches, fallbackComplaints)
  if fallbackComplaints.len > 0:
    raiseParseError(formatComplaints(fallbackComplaints), pc.command, pc.spec)

  let info = HookInfo(matched: matchedArgs(pc.matches))
  dispatch(spec, pc.matches, command, info)

when isMainModule:
  import std/unittest

  type
    TestArg = ref object of Arg
      ## A minimal concrete Arg for exercising ValueCursor.probe/
      ## applyFallbacks directly, without going through argumint.nim's
      ## ValueArg/FlagArg (which import this module, so the reverse import
      ## isn't available here).
      env: string
      delim: options.Option[string]
      cfg: ConfigKey
      recorded: seq[string]
      configRecorded: seq[string]

    FakeSource = ref object of ConfigSource
      data: seq[(ConfigKey, seq[string])]

    CountingSource = ref object of ConfigSource
      ## Counts `lookup` calls, to verify `ValueCursor.probe` only ever
      ## resolves once per Arg even across several `probe` calls.
      lookups: int

  method envName(self: TestArg): string = self.env
  method envDelim(self: TestArg): options.Option[string] = self.delim
  method configKey(self: TestArg): ConfigKey = self.cfg
  method parse(self: TestArg, value: string, variant = "",
               seenBy: options.Option[SeenBy] = none(SeenBy)) =
    ## Records per tier, so the fallback sweep's two paths stay
    ## distinguishable once each tier writes through `parse`.
    self.arbitrate(seenBy)
    if seenBy == some(byConfig): self.configRecorded.add value
    else: self.recorded.add value

  method lookup(self: FakeSource, key: ConfigKey): options.Option[seq[string]] =
    for (k, v) in self.data:
      if k == key:
        return some(v)
    none(seq[string])

  method lookup(self: CountingSource, key: ConfigKey): options.Option[seq[string]] =
    self.lookups.inc
    some(@["x"])

  proc newTestArg(name: string, env = "", delim = none(string), cfg: ConfigKey = noConfigKey()): TestArg =
    TestArg(kind: Optional, variants: @[name], env: env, delim: delim, cfg: cfg)

  proc specWithConfig(sources: seq[ConfigSource] = @[], args: seq[Arg] = @[]): Spec =
    Spec(settings: SpecSettings(envDelim: ":", configSources: sources), args: args)

  suite "ValueCursor.probe (env tier)":
    test "false when the arg has no env var configured":
      var cursor: ValueCursor
      let arg = newTestArg("--foo")
      let spec = specWithConfig()
      check not cursor.probe(arg, () => resolveEnv(arg, spec))

    test "false when the configured env var isn't set":
      delEnv("ARGUMINT_TEST_UNSET")
      var cursor: ValueCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_UNSET")
      let spec = specWithConfig()
      check not cursor.probe(arg, () => resolveEnv(arg, spec))

    test "hands out a single value once, then reports exhausted":
      putEnv("ARGUMINT_TEST_SINGLE", "hello")
      defer: delEnv("ARGUMINT_TEST_SINGLE")
      var cursor: ValueCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_SINGLE")
      let spec = specWithConfig()
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check not cursor.probe(arg, () => resolveEnv(arg, spec))

    test "hands out each delimiter-split value in order":
      putEnv("ARGUMINT_TEST_MULTI", "a:b:c")
      defer: delEnv("ARGUMINT_TEST_MULTI")
      var cursor: ValueCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_MULTI")
      let spec = specWithConfig()
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check not cursor.probe(arg, () => resolveEnv(arg, spec))

    test "a per-arg delim override is used instead of Spec.settings.envDelim":
      putEnv("ARGUMINT_TEST_OVERRIDE", "a;b;c")
      defer: delEnv("ARGUMINT_TEST_OVERRIDE")
      var cursor: ValueCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_OVERRIDE", some(";"))
      let spec = specWithConfig()
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check not cursor.probe(arg, () => resolveEnv(arg, spec))

    test "an empty per-arg delim override means the whole value is a single element":
      putEnv("ARGUMINT_TEST_NOSPLIT", "a:b")
      defer: delEnv("ARGUMINT_TEST_NOSPLIT")
      var cursor: ValueCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_NOSPLIT", some(""))
      let spec = specWithConfig()
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check not cursor.probe(arg, () => resolveEnv(arg, spec))

  suite "ValueCursor.probe (config tier)":
    test "false when the arg has no config key configured":
      var cursor: ValueCursor
      let arg = newTestArg("--foo")
      let spec = specWithConfig(@[ConfigSource FakeSource(data: @[(configKey("foo"), @["x"])])])
      check not cursor.probe(arg, () => resolveConfig(arg, spec))

    test "false when no configured source has the key":
      var cursor: ValueCursor
      let arg = newTestArg("--foo", cfg = configKey("foo"))
      let spec = specWithConfig(@[ConfigSource FakeSource(data: @[])])
      check not cursor.probe(arg, () => resolveConfig(arg, spec))

    test "hands out each value in order, then reports exhausted":
      var cursor: ValueCursor
      let arg = newTestArg("--foo", cfg = configKey("foo"))
      let spec = specWithConfig(@[ConfigSource FakeSource(data: @[(configKey("foo"), @["a", "b"])])])
      check cursor.probe(arg, () => resolveConfig(arg, spec))
      check cursor.probe(arg, () => resolveConfig(arg, spec))
      check not cursor.probe(arg, () => resolveConfig(arg, spec))

    test "a later source's hit fully replaces an earlier one's":
      var cursor: ValueCursor
      let arg = newTestArg("--foo", cfg = configKey("foo"))
      let spec = specWithConfig(@[
        ConfigSource FakeSource(data: @[(configKey("foo"), @["a", "b"])]),
        ConfigSource FakeSource(data: @[(configKey("foo"), @["c"])]),
      ])
      check cursor.probe(arg, () => resolveConfig(arg, spec))
      check not cursor.probe(arg, () => resolveConfig(arg, spec))

    test "resolve runs at most once per arg, even across several probes":
      var cursor: ValueCursor
      let arg = newTestArg("--foo", cfg = configKey("foo"))
      let source = CountingSource()
      let spec = specWithConfig(@[ConfigSource source])
      check cursor.probe(arg, () => resolveConfig(arg, spec))
      check not cursor.probe(arg, () => resolveConfig(arg, spec))
      check source.lookups == 1

  suite "applyFallbacks (env tier)":
    test "sets an unconsulted arg's value directly from env":
      putEnv("ARGUMINT_TEST_DIRECT", "hi")
      defer: delEnv("ARGUMINT_TEST_DIRECT")
      let arg = newTestArg("--foo", "ARGUMINT_TEST_DIRECT")
      let spec = specWithConfig(args = @[Arg arg])
      var env, configValues: ValueCursor
      var matches: MatchTable
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, complaints)
      check complaints.len == 0
      check arg.recorded == @["hi"]

    test "applies every split value once the walk fully consumed them":
      putEnv("ARGUMINT_TEST_CONSUMED", "a:b")
      defer: delEnv("ARGUMINT_TEST_CONSUMED")
      let arg = newTestArg("--foo", "ARGUMINT_TEST_CONSUMED")
      let spec = specWithConfig(args = @[Arg arg])
      var env, configValues: ValueCursor
      check env.probe(arg, () => resolveEnv(arg, spec))
      check env.probe(arg, () => resolveEnv(arg, spec))
      var matches: MatchTable
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, complaints)
      check complaints.len == 0
      check arg.recorded == @["a", "b"]

    test "complains about env values the walk didn't consume":
      putEnv("ARGUMINT_TEST_LEFTOVER", "a:b:c")
      defer: delEnv("ARGUMINT_TEST_LEFTOVER")
      let arg = newTestArg("--foo", "ARGUMINT_TEST_LEFTOVER")
      let spec = specWithConfig(args = @[Arg arg])
      var env, configValues: ValueCursor
      discard env.probe(arg, () => resolveEnv(arg, spec)) # consumes only 1 of the 3 available values
      var matches: MatchTable
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, complaints)
      check complaints == @[complaint("unexpected option", arg.name, names = true)]

    test "an arg reachable from two spec levels only complains once":
      # The oversupply branch applies nothing, so `seenBy` stays `byNone` and
      # can't gate the second visit -- `cursor.complained` does. See ADR 0039.
      putEnv("ARGUMINT_TEST_TWICE", "a:b:c")
      defer: delEnv("ARGUMINT_TEST_TWICE")
      let arg = newTestArg("--foo", "ARGUMINT_TEST_TWICE")
      let spec = specWithConfig(args = @[Arg arg])
      var env, configValues: ValueCursor
      discard env.probe(arg, () => resolveEnv(arg, spec)) # consumes only 1 of 3
      var matches: MatchTable
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, complaints)
      applyFallbacks(env, configValues, spec, matches, complaints) # second level
      check complaints == @[complaint("unexpected option", arg.name, names = true)]

    test "skips an arg already explicitly matched on the command line":
      putEnv("ARGUMINT_TEST_SKIP", "hi")
      defer: delEnv("ARGUMINT_TEST_SKIP")
      let arg = newTestArg("--foo", "ARGUMINT_TEST_SKIP")
      let spec = specWithConfig(args = @[Arg arg])
      var env, configValues: ValueCursor
      var matches: MatchTable
      # The gate is the Arg's own tier, which `parse*` sets from the match
      # table before calling this -- not a `matches` lookup here. See ADR 0039.
      arg.seenBy = byCli
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, complaints)
      check complaints.len == 0
      check arg.recorded.len == 0

  suite "applyFallbacks (config tier)":
    test "sets an unconsulted arg's value directly from a Config Source":
      let arg = newTestArg("--foo", cfg = configKey("foo"))
      let source = FakeSource(data: @[(configKey("foo"), @["hi"])])
      let spec = specWithConfig(@[ConfigSource source], args = @[Arg arg])
      var env, configValues: ValueCursor
      var matches: MatchTable
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, complaints)
      check complaints.len == 0
      check arg.configRecorded == @["hi"]

    test "complains about config values the walk didn't consume":
      let arg = newTestArg("--foo", cfg = configKey("foo"))
      let source = FakeSource(data: @[(configKey("foo"), @["a", "b", "c"])])
      let spec = specWithConfig(@[ConfigSource source], args = @[Arg arg])
      var env, configValues: ValueCursor
      discard configValues.probe(arg, () => resolveConfig(arg, spec)) # consumes only 1 of 3
      var matches: MatchTable
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, complaints)
      check complaints == @[complaint("unexpected option", arg.name, names = true)]

    test "env present takes precedence, config is never consulted":
      putEnv("ARGUMINT_TEST_PRECEDENCE", "from-env")
      defer: delEnv("ARGUMINT_TEST_PRECEDENCE")
      let arg = newTestArg("--foo", "ARGUMINT_TEST_PRECEDENCE", cfg = configKey("foo"))
      let source = FakeSource(data: @[(configKey("foo"), @["from-config"])])
      let spec = specWithConfig(@[ConfigSource source], args = @[Arg arg])
      var env, configValues: ValueCursor
      var matches: MatchTable
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, complaints)
      check arg.recorded == @["from-env"]
      check arg.configRecorded.len == 0

    test "falls through to config when env is unset":
      let arg = newTestArg("--foo", "ARGUMINT_TEST_ABSENT", cfg = configKey("foo"))
      let source = FakeSource(data: @[(configKey("foo"), @["from-config"])])
      let spec = specWithConfig(@[ConfigSource source], args = @[Arg arg])
      var env, configValues: ValueCursor
      var matches: MatchTable
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, complaints)
      check complaints.len == 0
      check arg.recorded.len == 0
      check arg.configRecorded == @["from-config"]
