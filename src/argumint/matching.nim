## Owns "what happens when one `Matcher` is applied to the live parse state" --
## `Match`, `MatchTable`, `Reach`, `Level`, and `ParseContext` are the data
## model; `push` and `match` are the only two procs that touch them. Both
## `fsm.nim`'s `walk` (real parsing) and `completion.nim`'s `collectFrontier`
## (shell completion) call `match` directly and share `ParseContext` -- `match`
## mutates its `.report`/`.tiers`/`.matches` fields as a side effect regardless
## of which caller is driving it, so this module sits below both rather than
## belonging to either. `reach` stays behind in `fsm.nim`: only `walk`'s Reach-
## ranking (ADR 0036) needs it, `collectFrontier` never does. See
## `docs/architecture.md` §3 and issue #78.

import std/[strformat, sequtils, tables]

import ./[backend, complaints, fsmgraph, precedence, tokens]

type
  Match* = tuple[variant: string, value: string, spec: Spec, idx: int]
    ## `idx` is the original CLI argv position of the token this match
    ## consumed -- see `RawToken.idx`. Composition (`parseAllValues`) sorts
    ## by it instead of relying on push order, which is grammar-position
    ## order, not typed order.

  MatchTable* = OrderedTable[Arg, seq[Match]]

  Reach* = tuple[idx, subIdx: int]
    ## How far into the user's input a path got (`CONTEXT.md`): the argv
    ## position of the first token it could not consume, plus how many letters
    ## of that token a Short-Option Cluster peel already accounted for.
    ## Lexicographic, so `subIdx` only ever breaks a tie *within* one physical
    ## argument and never outweighs reaching the next one. See ADR 0036.

  Level* = tuple[spec: Spec, command: string]
    ## One entered grammar level: the `Spec` owning it, plus the accumulated
    ## command string naming it (`"app"`, `"app go"`). Recorded root-first on
    ## `ParseContext.levels` as the walk descends, and read afterwards by
    ## `dispatch` and `applyFallbacks` -- see architecture.md §5.

  ParseContext* = object
    maxReach*: Reach
      ## The greatest Reach of any path explored from this state -- both
      ## the running bar siblings are ranked against and, once the walk
      ## returns, what the parent reads back as this branch's descendant
      ## Reach. See `reach` and ADR 0036
    cursor*: TokenCursor
      ## The tokens left to parse, the spec for the *live* walk position,
      ## and whether `--` has been crossed -- consulted by `classify`/
      ## `match` as the walk progresses; `cursor.spec` is never
      ## retroactively overwritten by a failed sibling's own descent (see
      ## `Report.adopt`). See `TokenCursor` (`tokens.nim`)
    command*: string
      ## The command string up to the current subcommand, for the live
      ## walk position -- names the level `cursor.spec` governs
    levels*: seq[Level]
      ## Every grammar level entered on this path, root-first. Seeded with
      ## the root entry by `parse*` (the completion path neither seeds nor
      ## reads it) and appended to as `match`'s `Command` branch descends;
      ## a losing branch's entry is discarded with the branch, since
      ## `walk` clones the whole context per candidate transition
    report*: Report
      ## The furthest-reaching fsm path's own failure -- complaints,
      ## leftovers, and the Spec/command to render them against. See
      ## `complaints.nim` and `docs/architecture.md` §3b.
    matches*: MatchTable
      ## A table of processed matches
    tiers*: Tiers
      ## Value Precedence's two fallback tiers -- see `Tiers`
      ## (`precedence.nim`)

proc push*(matches: var MatchTable, arg: Arg, spec: Spec, variant: string, value = "", idx = 0) =
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

proc match*(m: Matcher, pc: var ParseContext, atTerminal = false): bool =
  ## Checks if `m` matches a token in `tokens`. May consume a token and may add
  ## a variant and value to `matches`. Returns whether the match was successful.
  ##
  ## `atTerminal` is whether the state this transition leaves was terminal --
  ## the grammar could have stopped here, so an `Argument` that finds nothing
  ## was never owed. See ADR 0037.
  case m.kind:
  of mkShortcut:
    # A shortcut consumes no tokens and always indicates success.
    result = true
  of mkOptsEnd:
    # Always matches, forcing pc.cursor.optsEnd regardless of whether a
    # literal `--` is actually there to consume -- see ADR 0020.
    if pc.cursor.len > 0:
      discard pc.cursor.consumeOptsEnd(0)
    pc.cursor.optsEnd = true
    result = true
  of mkArgument:
    # Skip Option/Flag-classified tokens (order-independent -- see ADR
    # 0019). A Command-classified token is accepted as literal text just
    # like a Positional one -- the scan must not skip past it looking
    # further ahead, see ADR 0019 point 6 on why that breaks ordering.
    var pos = 0
    while pos < pc.cursor.len:
      if pc.cursor.consumeOptsEnd(pos):
        continue
      let c = pc.cursor.classify(pos)
      case c.kind
      of Positional, Command:
        if pc.cursor.refusesAsPositional(pos, c):
          # Left unconsumed so it survives as a leftover for `walk` to name
          # -- see `refusesAsPositional`.
          pos.inc
        else:
          pc.matches.push(m.arg, pc.cursor.spec, m.arg.name, pc.cursor[pos].raw, pc.cursor[pos].idx)
          pc.cursor.consume(pos, c)
          result = true
          break
      else:
        pos.inc
    if not result and pc.matches.getOrDefault(m.arg).len == 0:
      # Only report a genuinely-unmatched arg -- if this arg already matched
      # at least once (a satisfied `<arg>...` repeat), a failed attempt at
      # *another* repeat isn't a real deficiency worth reporting.
      if not atTerminal:
        pc.report.missingArgument(m.arg.name)
      # A starved option is why nothing was left to match, and this path
      # never reaches `walk`'s tail -- see `Report.starved`. Asked whether or
      # not the complaint above was suppressed: that's about this arg, not it.
      discard pc.report.starved(pc.cursor)
  of mkCommand:
    # If the next token classifies as this specific command, consume it and
    # return true. Otherwise return false -- a Command matcher never scans
    # past position 0 (see `docs/architecture.md`).
    if pc.cursor.len > 0 and not pc.cursor.consumeOptsEnd(0):
      let c = pc.cursor.classify(0)
      if c.kind == Command and c.cmd == m.cmd:
        pc.matches.push(m.cmd, pc.cursor.spec, c.cmdName, idx = pc.cursor[0].idx)
        pc.command = fmt"{pc.command} {c.cmdName}"
        pc.cursor.spec = m.cmd.spec
        pc.levels.add (spec: pc.cursor.spec, command: pc.command)
        pc.cursor.consume(0, c)
        result = true
    if not result:
      pc.report.missingCommand(m.cmd.name)
      # A Command matcher never scans past position 0, so it's the one place
      # that knows a Command was expected *here* -- see ADR 0035.
      pc.report.leftover(pc.cursor)
  of mkOption:
    # Skip tokens that don't classify as *this* opt so option/arg order
    # doesn't matter -- see the Argument branch above on why a
    # Command-classified token doesn't need special-casing here either.
    var pos = 0
    while pos < pc.cursor.len:
      if pc.cursor.consumeOptsEnd(pos):
        continue
      let c = pc.cursor.classify(pos)
      case c.kind
      of Optional:
        if c.opt == m.opt:
          pc.matches.push(c.opt, pc.cursor.spec, c.optName, c.optVal, pc.cursor[pos].idx)
          pc.cursor.consume(pos, c)
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
            pc.matches.push(c.flag, pc.cursor.spec, c.flagName, c.flagName, pc.cursor[pos].idx)
            pc.cursor.consume(pos, c)
            return true
      else:
        discard
      pos.inc

    # No CLI token matched; let the configured env var, then a Config
    # Source, stand in instead -- see architecture.md's "Env var
    # mechanics" and `docs/adr/0018-config-source.md`.
    if pc.tiers.probe(m.opt, pc.cursor.spec):
      return true

    # Unconditional on purpose -- a `m.opt notin pc.matches` guard can't tell
    # one occurrence from two; see ADR 0035's rejected third rule.
    pc.report.missingOption(if m.variant.len > 0: m.variant else: m.opt.name)
    # A failed Option matcher never reaches `walk`'s tail, so it records its
    # own leftover -- see ADR 0035, and ADR 0019 point 4 on why this can't
    # live in tokenization.
    if not pc.report.starved(pc.cursor) and pc.cursor.len > 0 and pc.cursor[0].optShape:
      if pc.cursor.classify(0).kind == Positional:
        pc.report.leftover(pc.cursor)
  of mkOptions:
    # Try each option in m.opts (see ADR 0002 for the catch-all repeat rule).
    for (opt, variant) in zip(m.opts, m.variants):
      # Probe only: roll a failed probe's complaints and leftovers back, and
      # add nothing in their place -- a catch-all option is optional by
      # construction, so it can never be missing (ADR 0035's rule 1).
      let mark = pc.report.mark()
      if newOptMatcher(opt, variant).match(pc):
        result = true
      else:
        pc.report.rollback(mark)
    if not result:
      # Re-asked past the rollback above: a starved option can never be
      # consumed as anything else, so it's the real error however the
      # probes went -- see `Report.starved`.
      discard pc.report.starved(pc.cursor)
