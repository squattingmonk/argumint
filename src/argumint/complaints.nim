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

privateAccess(Spec) ## Reaches `Spec`'s private `usage`/`options`/`commands`
  ## (ADR 0030) -- non-generic code only, see docs/gotchas.md.

type
  Complaint = tuple[kind: string, subject: string, names: bool]
    ## A failure reason, e.g. `missing option: -v`. Structured so same-kind
    ## complaints group at render time; an empty `kind` renders as a bare
    ## sentence. `names` marks one that points at a token the user typed --
    ## a property, never a test on the wording, since ADR 0034's starved
    ## complaint must count. Built via `complaint`, never as a bare tuple.
    ## See ADR 0035.

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

proc osaDistance*(a, b: seq[Rune]): int =
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

proc didYouMean*(typed: string, candidates: seq[string]): string =
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

proc unknownOption*(token: RawToken, spec: Spec): Complaint =
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
  ## Complains that `cur`'s leading token is a declared option left without
  ## a value, when that's what it is, plus the option-shaped token that
  ## starved it when there is one -- both, never one masking the other.
  ## Returns whether it complained, so callers can fall back to recording a
  ## plain leftover for `finalComplaints` to word.
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
  ## that just matched, so whatever an *earlier* transition on this same
  ## branch complained about is moot. See `docs/architecture.md` §3b.
  r.messages.setLen(0)
  r.leftovers.setLen(0)

proc mark*(r: Report): ReportMark =
  ## This `Report`'s current size, for `rollback` to restore -- the
  ## `Options` catch-all probes a candidate and rolls its complaints back
  ## on failure, since a catch-all option is optional by construction (ADR
  ## 0035's rule 1).
  (r.messages.len, r.leftovers.len)

proc rollback*(r: var Report, m: ReportMark) =
  ## Discards everything recorded since `m` -- see `mark`.
  r.messages.setLen(m.messages)
  r.leftovers.setLen(m.leftovers)

proc adopt*(r: var Report, other: Report, spec: Spec, command: string) =
  ## Replaces `r`'s complaints with `other`'s, for `spec`/`command` --
  ## `spec`/`command` are taken as explicit arguments rather than read off
  ## `other` itself, because the failing position comes from the branch's
  ## own *live* cursor, which must never retroactively overwrite
  ## `pc.cursor.spec` -- see ADR 0019 point 7. Used when a sibling branch's
  ## Reach exceeds the running best, or nothing has complained yet -- see
  ## ADR 0036.
  r.messages = other.messages
  r.leftovers = other.leftovers
  r.spec = spec
  r.command = command

proc merge*(r: var Report, other: Report) =
  ## Folds `other`'s complaints into `r` instead of replacing them -- for a
  ## Reach-tied sibling, so two same-kind failures (e.g. both `-h` and
  ## `--verbose` missing at the same `[options]` position) accumulate onto
  ## one grouped line via `formatComplaints` rather than the sibling that
  ## happens to run last silently discarding an earlier one. See ADR 0036.
  for msg in other.messages:
    if msg notin r.messages:
      r.messages.add msg
  for lo in other.leftovers:
    r.addLeftoverRaw(lo)

proc finalComplaints*(r: Report): seq[Complaint] =
  ## The message the user actually sees, built from what the walk
  ## accumulated: name the offending token, then drop the complaints that
  ## naming makes redundant. See `docs/adr/0035-parse-failure-reporting.md`.
  result = r.messages
  var named = result.anyIt(it.names)
  if not named:
    # Worded from what the grammar expected here, not the token's shape --
    # `shp` is lexically a positional. See ADR 0035.
    let wantedCommand = result.anyIt(it.kind == "missing command")
    for leftover in r.leftovers:
      let c = leftover.classify(0)
      # Only a token that could have *been* a command qualifies: an
      # option-shaped one is an option problem, and past a `--` nothing is a
      # command name. Both guards needed, or this arm swallows every leftover.
      let mistypedCommand = wantedCommand and c.kind != Command and
        not leftover.optsEnd and not leftover.tokens[0].optShape
      result.add:
        if not c.starvedOpt.isNil: starvedComplaint(c)
        elif mistypedCommand: unknownCommand(leftover.tokens[0].raw, leftover.spec)
        else:
          case c.kind
          of Command: complaint("unexpected command", c.cmdName, names = true)
          of Flag: complaint("unexpected flag", c.flagName, names = true)
          of Optional: complaint("unexpected option",
            "{c.optName}{c.optSep}{c.optVal}".fmt, names = true)
          of Positional:
            # `optsEnd` consulted directly: past a `--` everything
            # classifies `Positional`, whatever it looks like.
            if leftover.tokens[0].optShape and not leftover.optsEnd:
              unknownOption(leftover.tokens[0], leftover.spec)
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

proc formatComplaints*(messages: seq[Complaint]): string =
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

proc failureMessage*(r: Report): string =
  ## The complaint list plus the usage block -- what `raiseParseFailure`
  ## raises verbatim, and what a reshaped conversion/validation failure
  ## (`fsm.parse*`) uses for its own exception instead. See ADR 0035.
  let msg = formatComplaints(r.finalComplaints)
  "{msg}\n\n{r.spec.usage.formatUsage(r.command, r.spec.settings.width)}".fmt

proc raiseParseFailure*(r: Report) =
  ## Raises `ParseError` with `r.failureMessage`.
  raise newException(ParseError, r.failureMessage)
