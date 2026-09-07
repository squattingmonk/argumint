## Owns "what does the user see when a parse fails" -- ADR 0035 (parse-failure
## reporting), 0036 (rank by Reach), 0037 (missing-argument suppression), 0038
## (name the short option that failed), and the Did-You-Mean rule. `Report`
## is the data model: `fsm.nim`'s `walk` records into it during the walk
## (`missingArgument`/`missingOption`/`missingCommand`/`leftover`/`starved`),
## never wording anything itself, then words and renders it once the walk is
## over (`finalComplaints`/`failureMessage`/`raiseParseFailure`). See
## `docs/architecture.md` §3b.
import std/[algorithm, importutils, sequtils, strformat, strutils, tables, unicode]

import ./[backend, errors, help, tokens]

# Reaches `Spec`'s private `usage`/`options`/`commands` (ADR 0030) --
# non-generic code only, see docs/gotchas.md.
privateAccess(Spec)

type
  Complaint = tuple[kind: string, subject: string, names: bool]
    ## A failure reason, e.g. `missing option: -v`. Structured so same-kind
    ## complaints group at render time; an empty `kind` renders as a bare
    ## sentence. `names` marks one that points at a token the user typed -- a
    ## property, never a test on the wording, since ADR 0034's starved complaint
    ## must count. Built via `complaint`, never as a bare tuple. See ADR 0035.

  Leftover = TokenCursor
    ## One failed branch's unconsumed tokens, plus the context to
    ## re-`classify` them. Recorded during the walk, worded in
    ## `finalComplaints`. Whole token list, not just the first -- `classify`
    ## looks ahead, so a slice makes every leftover option look starved.
    ## See ADR 0035.

  ReportMark* = tuple[messages, leftovers: int]
    ## A `Report`'s size at some point during the walk, for `rollback` to
    ## restore -- see `mark`.

  Report* = object
    ## Everything accumulated about why a parse branch failed: what the
    ## grammar wanted (`messages`) and what the input left over
    ## (`leftovers`), plus the `Spec`/command string the eventual message's
    ## usage block is rendered against. `spec`/`command` travel with the
    ## complaints rather than living beside them on `ParseContext`, since
    ## all four are written together at `walk`'s one adoption site
    ## (`adopt`) and read together at the one raise site
    ## (`raiseParseFailure`). Fields unexported -- callers go through the
    ## verbs below, never the fields directly.
    messages: seq[Complaint]
    leftovers: seq[Leftover]
    spec: Spec
    command: string

proc initReport*(spec: Spec, command: string): Report =
  ## A `Report` with nothing recorded yet, for `spec`/`command`'s usage
  ## block -- see `Report`.
  Report(spec: spec, command: command)

proc complaint(kind, subject: string, names = false): Complaint =
  ## Builds a `Complaint`. Pass `names = true` for a Naming Complaint, one
  ## pointing at a specific token the user typed -- see `Complaint.names`
  ## and ADR 0035.
  (kind, subject, names)

proc osaDistance(a, b: seq[Rune]): int =
  ## Damerau-Levenshtein, optimal string alignment: an adjacent transposition
  ## costs 1. Hand-rolled over `Rune`s because `std/editdistance` has no
  ## transposition variant and its ASCII one splits multi-byte characters. See
  ## ADR 0035.
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
  ## `variant` with its leading dashes stripped -- measuring the full spelling
  ## inflates every threshold. See ADR 0035.
  variant.strip(trailing = false, chars = {'-'})

proc isShortForm(variant: string): bool =
  ## Whether `variant` is written as a short option -- exactly one leading
  ## dash. A Command name (no dash at all) is never short-form.
  variant.len > 1 and variant[0] == '-' and variant[1] != '-'

proc didYouMean(typed: string, candidates: seq[string]): string =
  ## `"; did you mean --port?"` for whichever of `candidates` sit within
  ## `min(2, max(1, n div 4))` of `typed`, `n` being the candidate's own dash-
  ## stripped length; all tied at the best distance, sorted. The cap is load-
  ## bearing. Eligibility of `typed` is `unknownOption`'s call, not this one's.
  ## See ADR 0035.
  if typed.isShortForm:
    return ""
  var
    best = high(int)
    hits: seq[string]

  let word = typed.bareName.toRunes
  for candidate in candidates.sorted:
    if candidate == typed or candidate.isShortForm:
      continue
    let
      name = candidate.bareName.toRunes
      distance = osaDistance(word, name)
    if distance > min(2, max(1, name.len div 4)):
      continue
    if distance < best:
      (best, hits) = (distance, @[candidate])
    elif distance == best:
      hits.add candidate

  case hits.len
  of 0: ""
  of 1: "; did you mean {hits[0]}?".fmt
  of 2: "; did you mean {hits[0]} or {hits[1]}?".fmt
  else: "; did you mean {hits[0 ..^ 2].join(\", \")}, or {hits[^1]}?".fmt

proc unknownOption(token: RawToken, spec: Spec): Complaint =
  ## Names an option-shaped token nothing in `spec` declares. The two arms are
  ## exclusive by construction: only a short form is narrowed and carries an
  ## origin, only a long form draws a suggestion. See ADR 0038.
  let subject =
    if token.raw.isShortForm:
      # Cluster syntax, so the failing unit is one letter: name that, and say
      # which typed token it came out of, since the letter may be neither what
      # they typed nor something they'd recognize. The tail past it is never
      # named -- untested, and may hold declared options.
      let name = token.raw[0..1]
      if token.userTyped == name: name
      else: "{name} (in {token.userTyped})".fmt
    else:
      token.raw & didYouMean(token.raw, toSeq(spec.options.keys))
  complaint("unrecognized option", subject, names = true)

proc unknownCommand(word: string, spec: Spec): Complaint =
  ## Names a token sitting where `spec` expected one of its commands.
  complaint("unrecognized command",
    word & didYouMean(word, toSeq(spec.commands.keys)), names = true)

proc addUnique(r: var Report, entry: Complaint) =
  ## Adds `entry` unless already present -- a starved option is reachable
  ## down more than one branch, and the same line twice reads as a bug in
  ## the parser rather than in the input.
  if entry notin r.messages:
    r.messages.add entry

proc addLeftoverRaw(r: var Report, leftover: Leftover) =
  ## Records `leftover` unless one naming the same token is already there --
  ## two branches failing on the same token mustn't produce the line twice.
  if not r.leftovers.anyIt(it.tokens[0].raw == leftover.tokens[0].raw):
    r.leftovers.add leftover

proc missingArgument*(r: var Report, name: string) =
  ## Records that a required positional `name` had nothing left to match --
  ## see ADR 0037 on when this is suppressed instead (never reached here;
  ## the caller only calls this when it wasn't).
  r.messages.add complaint("missing argument", name)

proc missingCommand*(r: var Report, name: string) =
  ## Records that a `Command` matcher found nothing at the one position it
  ## ever looks -- see `docs/architecture.md` §3.
  r.messages.add complaint("missing command", name)

proc missingOption*(r: var Report, variant: string) =
  ## Records that a required `opt`/`flag` was never matched. Unconditional
  ## on purpose -- see ADR 0035's rejected third rule.
  r.messages.add complaint("missing option", variant)

proc unexpected*(r: var Report, arg: Arg) =
  ## Records a Value Precedence fallback tier oversupplying `arg` beyond
  ## what the walk actually consumed -- see `docs/adr/0005-env-supplied-
  ## multi-value-options-and-flags.md` and `docs/adr/0018-config-source.md`.
  let kind = if arg.kind == Flag: "unexpected flag" else: "unexpected option"
  r.messages.add complaint(kind, arg.name, names = true)

proc note*(r: var Report, msg: string) =
  ## Records a bare, kindless sentence -- the shape a conversion/validation
  ## failure's own message takes, having no complaint kind of its own. See
  ## ADR 0035.
  r.messages.add complaint("", msg)

proc leftover*(r: var Report, cur: TokenCursor) =
  ## Records what a failed branch couldn't consume, for `finalComplaints` to
  ## word later -- a no-op if `cur` is empty. See `addLeftoverRaw`.
  if cur.len > 0:
    r.addLeftoverRaw(cur)

proc starvedComplaint(c: Classification): Complaint =
  ## The unconditional "declared, but nothing to give it" complaint -- see
  ## `docs/adr/0034-strict-option-checking.md`.
  complaint("missing value", "option {c.starvedName} requires a value".fmt, names = true)

proc starved*(r: var Report, cur: TokenCursor): bool =
  ## Complains that `cur`'s leading token is a declared option left without a
  ## value, when that's what it is, plus the option-shaped token that starved it
  ## when there is one -- both, never one masking the other. Returns whether it
  ## complained, so callers can fall back to recording a plain leftover for
  ## `finalComplaints` to word.
  ##
  ## Classifies for itself rather than taking a `Classification`: the
  ## `[options]` catch-all has to re-ask after rolling its own per-probe
  ## messages back. See ADR 0034.
  if cur.len == 0 or not cur[0].optShape:
    return false
  let c = cur.classify(0)
  if c.starvedOpt.isNil:
    return false
  r.addUnique starvedComplaint(c)
  if cur.len > 1 and cur[1].mustResolve:
    # Named only when genuinely unknown -- the token that starved this one
    # may be a declared option itself (`--port --port 80`), and calling
    # *that* unrecognized is the wording ADR 0034 exists to fix.
    let starver = cur.classify(1)
    if starver.kind == Positional and starver.starvedOpt.isNil:
      r.addUnique unknownOption(cur[1], cur.spec)
  true

proc isEmpty*(r: Report): bool =
  ## Whether nothing has been recorded at all -- `walk`'s "nothing has
  ## complained yet" guard, and the fallback sweep's "was there anything to
  ## raise" check.
  r.messages.len == 0 and r.leftovers.len == 0

proc hasLeftovers*(r: Report): bool =
  ## Whether any leftover has been recorded -- `walk`'s tail asks this alone
  ## (not `isEmpty`): a terminal state with unconsumed input still needs its
  ## own leftover recorded even if a sibling already complained, as long as
  ## none of them named a leftover token yet.
  r.leftovers.len > 0

proc clear*(r: var Report) =
  ## Empties `messages`/`leftovers` only -- `spec`/`command` survive, since a
  ## successful match doesn't change which level is live. Called on a branch
  ## that just matched, so whatever an *earlier* transition on this same branch
  ## complained about is moot. See `docs/architecture.md` §3b.
  r.messages.setLen(0)
  r.leftovers.setLen(0)

proc mark*(r: Report): ReportMark =
  ## This `Report`'s current size, for `rollback` to restore -- the `Options`
  ## catch-all probes a candidate and rolls its complaints back on failure,
  ## since a catch-all option is optional by construction (ADR 0035's rule 1).
  (r.messages.len, r.leftovers.len)

proc rollback*(r: var Report, m: ReportMark) =
  ## Discards everything recorded since `m` -- see `mark`.
  r.messages.setLen(m.messages)
  r.leftovers.setLen(m.leftovers)

proc adopt*(r: var Report, other: Report, spec: Spec, command: string) =
  ## Replaces `r`'s complaints with `other`'s, for `spec`/`command` --
  ## `spec`/`command` are taken as explicit arguments rather than read off
  ## `other` itself, because the failing position comes from the branch's own
  ## *live* cursor, which must never retroactively overwrite `pc.cursor.spec` --
  ## see ADR 0019 point 7. Used when a sibling branch's Reach exceeds the
  ## running best, or nothing has complained yet -- see ADR 0036.
  r.messages = other.messages
  r.leftovers = other.leftovers
  r.spec = spec
  r.command = command

proc merge*(r: var Report, other: Report) =
  ## Folds `other`'s complaints into `r` instead of replacing them -- for a
  ## Reach-tied sibling, so two same-kind failures (e.g. both `-h` and
  ## `--verbose` missing at the same `[options]` position) accumulate onto one
  ## grouped line via `formatComplaints` rather than the sibling that happens to
  ## run last silently discarding an earlier one. See ADR 0036.
  for msg in other.messages:
    if msg notin r.messages:
      r.messages.add msg
  for lo in other.leftovers:
    r.addLeftoverRaw(lo)

proc handleLeftovers(complaints: var seq[Complaint], leftovers: seq[Leftover]): bool =
  ## Generates complaints for any leftover tokens if there are no naming
  ## complaints in `complaints`. Returns whether any such complaints were
  ## generated.
  result = complaints.anyIt(it.names)
  if not result:
    let wantedCommand = complaints.anyIt(it.kind == "missing command")
    for leftover in leftovers:
      let c = leftover.classify(0)
      # Only a token that could have *been* a command qualifies: an option-
      # shaped one is an option problem, and past a `--` nothing is a command
      # name. Both guards are needed or this arm swallows every leftover.
      let mistypedCommand = wantedCommand and c.kind != Command and
        not leftover.optsEnd and not leftover.tokens[0].optShape
      complaints.add:
        if not c.starvedOpt.isNil:
          starvedComplaint(c)
        elif mistypedCommand:
          unknownCommand(leftover.tokens[0].raw, leftover.spec)
        else:
          case c.kind
          of Command:
            complaint("unexpected command", c.cmdName, names = true)
          of Flag:
            complaint("unexpected flag", c.flagName, names = true)
          of Optional:
            complaint("unexpected option", "{c.optName}{c.optSep}{c.optVal}".fmt, names = true)
          of Positional:
            # If we have not passed a literal `--` and the token looks
            # option-shaped, we can report it an as unrecognized option.
            # Otherwise, the token must be treated as a positional argument.
            if leftover.tokens[0].optShape and not leftover.optsEnd:
              unknownOption(leftover.tokens[0], leftover.spec)
            else:
              complaint("unexpected argument", c.argVal, names = true)
      result = true

proc finalComplaints(r: Report): seq[Complaint] =
  ## The message the user actually sees, built from what the walk accumulated:
  ## name the offending token, then drop the complaints that naming makes
  ## redundant. See ADR 0035.
  result = r.messages
  if not result.handleLeftovers(r.leftovers):
    return

  # ADR 0035 rule 2: once something is named, what the FSM had left to try is
  # noise. "missing command" is supressed only when the named token stood in a
  # command's position; the valid set stays visible in the usage block.
  result = result.filterIt(it.kind != "missing option")
  if result.anyIt(it.kind in ["unrecognized command", "unexpected command"]):
    result = result.filterIt(it.kind != "missing command")

proc formatComplaints(messages: seq[Complaint]): string =
  ## Renders `messages` as a bulleted block, grouping same-kind complaints
  ## onto one " | "-joined line. No leading newline -- the caller owns the
  ## separation from its own prefix (see `parseOrQuit*`, `argumint.nim`).
  var subjectsByKind = initOrderedTable[string, seq[string]]()
  for (kind, subject, _) in messages:
    if subjectsByKind.hasKeyOrPut(kind, @[subject]) and
      subject notin subjectsByKind[kind]:
        subjectsByKind[kind].add subject

  var lines: seq[string]
  for kind, subjects in subjectsByKind.pairs:
    if kind.len > 0:
      let
        joined = subjects.join(" | ")
        subject = if subjects.len > 1: "({joined})".fmt else: joined
      lines.add "  - {kind}: {subject}".fmt
    else:
      for subject in subjects:
        lines.add "  - {subject}".fmt
  lines.join("\n")

proc failureMessage*(r: Report): string =
  ## The complaint list plus the usage block -- what `raiseParseFailure` raises
  ## verbatim, and what a reshaped conversion/validation failure (`fsm.parse*`)
  ## uses for its own exception instead. See ADR 0035.
  let msg = formatComplaints(r.finalComplaints)
  "{msg}\n\n{r.spec.usage.formatUsage(r.command, r.spec.settings.width)}".fmt

proc raiseParseFailure*(r: Report) =
  ## Raises `ParseError` with `r.failureMessage`.
  raise newException(ParseError, r.failureMessage)

when isMainModule:
  ## Direct tests for failure reporting -- ADR 0035 (parse-failure reporting),
  ## 0036 (rank by Reach), 0037 (missing-argument suppression), 0038 (name the
  ## short option that failed), and the Did-You-Mean rule. Until now this was
  ## verified only indirectly, through full-parse error-string assertions in
  ## test_parse_errors.nim/ test_strict_options.nim/test_cli_syntax.nim; those
  ## pin the wording, these pin the rule. See issue #63.
  import std/[unittest]

  import ../argumint

  suite "osaDistance":
    test "empty strings are distance 0":
      check osaDistance("".toRunes, "".toRunes) == 0

    test "identical strings are distance 0":
      check osaDistance("abc".toRunes, "abc".toRunes) == 0

    test "substitution costs 1":
      check osaDistance("ab".toRunes, "ac".toRunes) == 1

    test "insertion or deletion costs 1":
      check osaDistance("ab".toRunes, "abc".toRunes) == 1
      check osaDistance("abc".toRunes, "ab".toRunes) == 1

    test "adjacent transposition costs 1, not 2":
      check osaDistance("ab".toRunes, "ba".toRunes) == 1

    test "a multi-byte rune counts as one character, not one per byte":
      # "café" vs "cafe" differ by a single rune (é vs e) -- a byte-wise
      # distance would be larger, since é is two UTF-8 bytes.
      check osaDistance("café".toRunes, "cafe".toRunes) == 1

  suite "didYouMean":
    test "an empty candidate list returns no suggestions":
      check didYouMean("foo", @[]) == ""

    test "a candidate equal to the typed string is never offered":
      check didYouMean("foo", @["foo"]) == ""
      check didYouMean("foo", @["foo", "fox"]) == "; did you mean fox?"

    test "equality check is based on non-dash-stripped forms":
      check didYouMean("foo", @["--foo"]) == "; did you mean --foo?"
      check didYouMean("---foo", @["--foo"]) == "; did you mean --foo?"

    test "suggestions are never offered for short options":
      # Every short option is 1 editdistance away from every other short option,
      # so any suggestions would be useless. This must be based on the shape of
      # the typed word rather than its dash-stripped length, since commands
      # could be one-character long and thus making suggestions for them makes
      # sense.
      check didYouMean("-a", @["b", "-b"]) == ""
      check didYouMean("a", @["b"]) == "; did you mean b?"

    test "short options are never offered as suggestions":
      # Same reasoning as above.
      check didYouMean("a", @["-b"]) == ""

    test "the distance threshold is keyed on the candidate's length, not the typed word's":
      # "abcdefg" (7, dash-stripped) has threshold min(2, max(1, 7 div 4)) == 1.
      # "abcdxfgh" (8) is distance 2 from it -- over that candidate's own
      # threshold, so no suggestion. Were the threshold wrongly keyed on the
      # *typed* word's length instead (8 -> threshold 2), this would wrongly
      # suggest.
      check didYouMean("abcdxfgh", @["abcdefg"]) == ""

    test "offered once inside the candidate's own threshold":
      check didYouMean("porta", @["port"]) == "; did you mean port?"

    test "declined once outside the candidate's own threshold":
      check didYouMean("portla", @["port"]) == ""

    test "the closest candidates are suggested":
      check didYouMean("--longoption", @["--long-options"]) == "; did you mean --long-options?"
      check didYouMean("--longoption", @["--long-options", "--long-option"]) == "; did you mean --long-option?"

    test "multiple suggestions are joined by commas, with the final pair being joined by \"or\"":
      check didYouMean("foo", @["fox", "poo"]) == "; did you mean fox or poo?"
      check didYouMean("foo", @["foot", "fox", "poo"]) == "; did you mean foot, fox, or poo?"

    test "all best-distance ties are offered, sorted, never by declaration order":
      check didYouMean("cab", @["cat", "car"]) == "; did you mean car or cat?"

  suite "unknownOption":
    let spec = newSpec((verbose: flag("-v, --verbose"),), usage = "[options]")

    test "a long option token can get a suggestion":
      check unknownOption(RawToken(raw: "--verbse", optShape: true), spec) ==
        (kind: "unrecognized option", subject: "--verbse; did you mean --verbose?", names: true)
      check unknownOption(RawToken(raw: "--quiet", optShape: true), spec) ==
        (kind: "unrecognized option", subject: "--quiet", names: true)

    test "a short option token gets no suggestion":
      let token = RawToken(raw: "-x", optShape: true)
      check unknownOption(token, spec) ==
        (kind: "unrecognized option", subject: "-x", names: true)

    test "a short option cluster is narrowed to its first option, listing the cluster origin instead of a suggestion":
      let token = RawToken(raw: "-xyz", optShape: true)
      check unknownOption(token, spec) ==
        (kind: "unrecognized option", subject: "-x (in -xyz)", names: true)

    test "a peeled short option cluster remainder's origin is the whole typed cluster":
      let token = RawToken(raw: "-yz", cluster: "-xyz", optShape: true)
      check unknownOption(token, spec) ==
        (kind: "unrecognized option", subject: "-y (in -xyz)", names: true)

  suite "unknownCommand":
    let spec = newSpec((ship: command("s, ship", (name: arg("<name>")))))

    test "an unknown command with no suggestions gets a basic complaint":
      check unknownCommand("mine", spec) ==
        (kind: "unrecognized command", subject: "mine", names: true)

    test "an unknown command can have suggestions":
      check unknownCommand("shp", spec) ==
        (kind: "unrecognized command", subject: "shp; did you mean ship?", names: true)

    test "one-character commands can have suggestions":
      check unknownCommand("S", spec) ==
        (kind: "unrecognized command", subject: "S; did you mean s?", names: true)

  suite "handleLeftovers":
    let spec = newSpec((
      go: command("go", (rest: args("<rest>"),)),
      stop: command("stop", (rest: args("<rest>"),)),
      foo: opt("--foo=<value>"),
      bar: flag("--bar"),
    ), usage = "(go|stop)\n[options]")

    proc leftoverComplaints(r: Report): seq[Complaint] =
      result = r.messages
      discard result.handleLeftovers(r.leftovers)

    test "yields an empty seq for a report with no complaints":
      check leftoverComplaints(Report()).len == 0

    test "a leftover flag generates an \"unexpected flag\" Naming Complaint":
      var r = initReport(spec, "app")
      r.leftover(initCursor(spec, @["--bar"]))
      check r.leftoverComplaints == @[(kind: "unexpected flag", subject: "--bar", names: true)]

    test "a leftover option generates an \"unexpected option\" Naming Complaint listing the name, separator, and value":
      var r = initReport(spec, "app")
      r.leftover(initCursor(spec, @["--foo=bar"]))
      check r.leftoverComplaints ==
        @[(kind: "unexpected option", subject: "--foo=bar", names: true)]

    test "a leftover option with no value generates a \"missing value\" Naming Complaint":
      var r = initReport(spec, "app")
      r.leftover(initCursor(spec, @["--foo"]))
      check r.leftoverComplaints ==
        @[(kind: "missing value", subject: "option --foo requires a value", names: true)]

    test "a leftover command generates an \"unexpected command\" Naming Complaint":
      var r = initReport(spec, "app")
      r.leftover(initCursor(spec, @["stop"]))
      check r.leftoverComplaints == @[(kind: "unexpected command", subject: "stop", names: true)]

    test "a leftover token that may be a mistyped command generates an \"unrecognized command\" complaint possibly with a \"did you mean...?\" suffix":
      var r = initReport(spec, "app")
      r.missingCommand("stop")
      r.leftover(initCursor(spec, @["stp"]))
      check r.leftoverComplaints == @[
        (kind: "missing command", subject: "stop", names: false),
        (kind: "unrecognized command", subject: "stp; did you mean stop?", names: true)]

    test "a leftover token that may be a mistyped option generates an \"unrecognized option\" complaint possibly with a \"did you mean...?\" suffix":
      var r = initReport(spec, "app")
      r.leftover(initCursor(spec, @["--fop"]))
      check r.leftoverComplaints == @[(kind: "unrecognized option", subject: "--fop; did you mean --foo?", names: true)]

    test "a leftover token that doesn't classify as anything else generates an \"unexpected argument\" Naming Complaint":
      var r = initReport(spec, "app")
      r.leftover(initCursor(spec, @["name"]))
      check r.leftoverComplaints == @[(kind: "unexpected argument", subject: "name", names: true)]

  suite "finalComplaints":
    let spec = newSpec((
      go: command("go", (rest: args("<rest>"),)),
      stop: command("stop", (rest: args("<rest>"),)),
      foo: opt("--foo=<value>"),
      bar: flag("--bar"),
    ), usage = "(go|stop)\n[options]")

    test "a Naming Complaint drops every \"missing option\"":
      var r = initReport(spec, "app")
      r.missingOption("--foo")
      r.missingOption("--bar")
      r.messages.add ("", "", true)
      check r.finalComplaints == @[("", "", true)]

    test "an \"unrecognized command\" suppresses \"missing command\"":
      var r = initReport(spec, "app")
      r.missingCommand("go")
      r.missingCommand("stop")
      r.leftover(initCursor(spec, @["nope"]))
      check r.finalComplaints == @[(kind: "unrecognized command", subject: "nope", names: true)]

    test "a Command-classified leftover reports \"unexpected command\" regardless of wantedCommand":
      var r = initReport(spec, "app")
      r.missingOption("--foo") # no "missing command" recorded -- wantedCommand is false
      r.leftover(initCursor(spec, @["go"])) # "go" is itself a declared command
      # The naming complaint drops "missing option" (unconditional, ADR 0035's
      # rule 2) whether or not it's command-related.
      check r.finalComplaints == @[(kind: "unexpected command", subject: "go", names: true)]

    test "suppressed past `--`: missing command survives alongside the real wording":
      var r = initReport(spec, "app")
      r.missingCommand("go")
      var cur = initCursor(spec, @["nope"])
      cur.optsEnd = true
      r.leftover(cur)
      # Only a command-labeled naming complaint drops "missing command" (the
      # second filter in `finalComplaints`) -- an ordinary one doesn't, unlike
      # "missing option", which the first filter drops unconditionally.
      check r.finalComplaints == @[
        (kind: "missing command", subject: "go", names: false),
        (kind: "unexpected argument", subject: "nope", names: true),
      ]

    test "suppressed for an option-shaped token: missing command survives too":
      var r = initReport(spec, "app")
      r.missingCommand("go")
      r.leftover(initCursor(spec, @["--nope"]))
      check r.finalComplaints == @[
        (kind: "missing command", subject: "go", names: false),
        (kind: "unrecognized option", subject: "--nope", names: true),
      ]

  suite "formatComplaints":
    test "no complaint messages yields an empty string":
      check formatComplaints(@[]) == ""

    test "a kindless complaint renders as a bare bullet":
      check formatComplaints(@[(kind: "", subject: "bad value", names: false)]) ==
        "  - bad value"

    test "a kinded complaint renders a bullet in \"kind: subject\" format":
      check formatComplaints(@[(kind: "missing option", subject: "-a", names: true)]) ==
        "  - missing option: -a"

    test "same-kind complaints group onto one \" | \"-joined, parenthesized line":
      check formatComplaints(@[
        (kind: "missing option", subject: "-a", names: true),
        (kind: "missing option", subject: "-b", names: true),
      ]) == "  - missing option: (-a | -b)"

    test "a complaint that shares the same kind and subject as a previous complaint is dropped":
      check formatComplaints(@[
        (kind: "missing option", subject: "-a", names: true),
        (kind: "missing option", subject: "-a", names: true),
        (kind: "missing option", subject: "-a", names: false),
      ]) == "  - missing option: -a"

    test "multiple complaint kinds are each shown on their own line":
      check formatComplaints(@[
        (kind: "missing option", subject: "-a", names: true),
        (kind: "missing option", subject: "-b", names: true),
        (kind: "missing argument", subject: "<name>", names: true),
        (kind: "missing command", subject: "ship", names: true),
        (kind: "missing command", subject: "mine", names: true),
      ]) == "  - missing option: (-a | -b)\n  - missing argument: <name>\n  - missing command: (ship | mine)"

    test "multiple kindless complaints each render as their own bullet":
      check formatComplaints(@[
        (kind: "", subject: "bad value", names: false),
        (kind: "", subject: "also bad", names: false)
      ]) == "  - bad value\n  - also bad"

  suite "Report bookkeeping":
    let spec = newSpec((
      name: opt("--name=<s>", default = ""),
      verbose: flag("--verbose"),
    ), usage = "[options]")

    test "leftover is a no-op on an empty cursor":
      var r = initReport(spec, "")
      r.leftover(initCursor(spec, newSeq[string]()))
      check r.isEmpty

    test "leftover dedups by the first raw token":
      var r = initReport(spec, "")
      r.leftover(initCursor(spec, @["nope", "extra"]))
      r.leftover(initCursor(spec, @["nope"])) # same leading token -- dropped
      check r.finalComplaints.len == 1

    test "distinct leftovers both survive":
      var r = initReport(spec, "")
      r.leftover(initCursor(spec, @["nope"]))
      r.leftover(initCursor(spec, @["other"]))
      check r.finalComplaints.len == 2

    test "starved returns false on a non-option leading token":
      var r = initReport(spec, "")
      check not r.starved(initCursor(spec, @["plain"]))
      check r.isEmpty

    test "starved returns false on an empty cursor":
      var r = initReport(spec, "")
      check not r.starved(initCursor(spec, newSeq[string]()))

    test "starved names the starver only when it's genuinely unknown":
      var r = initReport(spec, "")
      check r.starved(initCursor(spec, @["--name", "--nope"]))
      check r.finalComplaints == @[
        (kind: "missing value", subject: "option --name requires a value", names: true),
        (kind: "unrecognized option", subject: "--nope", names: true),
      ]

    test "starved stays silent about a starver that's itself a declared option":
      var r = initReport(spec, "")
      check r.starved(initCursor(spec, @["--name", "--verbose"]))
      check r.finalComplaints ==
        @[(kind: "missing value", subject: "option --name requires a value", names: true)]

    test "mark/rollback discards everything recorded since the mark":
      var r = initReport(spec, "")
      r.missingOption("--foo")
      let m = r.mark()
      r.missingOption("--bar")
      r.leftover(initCursor(spec, @["extra"]))
      r.rollback(m)
      check r.finalComplaints == @[(kind: "missing option", subject: "--foo", names: false)]

    test "merge dedups exact-duplicate messages but keeps new ones":
      var a = initReport(spec, "")
      a.missingOption("--foo")
      var b = initReport(spec, "")
      b.missingOption("--foo")
      b.missingOption("--bar")
      a.merge(b)
      check a.finalComplaints.len == 2

    test "merge dedups leftovers by first raw token too":
      var a = initReport(spec, "")
      a.leftover(initCursor(spec, @["nope"]))
      var b = initReport(spec, "")
      b.leftover(initCursor(spec, @["nope", "extra"]))
      a.merge(b)
      check a.finalComplaints.len == 1

    test "clear empties messages/leftovers but leaves spec/command intact":
      var r = initReport(spec, "app")
      r.missingOption("--foo")
      r.leftover(initCursor(spec, @["extra"]))
      r.clear()
      check r.isEmpty
      r.note("boom")
      check "app" in r.failureMessage
