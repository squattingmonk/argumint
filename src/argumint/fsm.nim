## This module handles the navigation of the FSM based on a set of provided
## command-line arguments.
import std/[algorithm, importutils, os, sets, sequtils, strformat, strutils, sugar, tables]

# `Option` (the type) deliberately left unqualified-unimported --
# `options.Option[T]` instead, since a bare `import std/options` breaks
# every `case ... of Option:` branch matching `MatcherKind.Option` in this
# file -- see docs/gotchas.md.
from std/options import some, none, isSome, isNone, get

import ./[backend, complaints, configsource, errors, fsmgraph, parser, precedence, tokens]
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

  Reach = tuple[idx, subIdx: int]
    ## How far into the user's input a path got (`CONTEXT.md`): the argv
    ## position of the first token it could not consume, plus how many letters
    ## of that token a Short-Option Cluster peel already accounted for.
    ## Lexicographic, so `subIdx` only ever breaks a tie *within* one physical
    ## argument and never outweighs reaching the next one. See ADR 0036.

  Level = tuple[spec: Spec, command: string]
    ## One entered grammar level: the `Spec` owning it, plus the accumulated
    ## command string naming it (`"app"`, `"app go"`). Recorded root-first on
    ## `ParseContext.levels` as the walk descends, and read afterwards by
    ## `dispatch` and `applyFallbacks` -- see architecture.md §5.

  ParseContext = object
    maxReach: Reach
      ## The greatest Reach of any path explored from this state -- both
      ## the running bar siblings are ranked against and, once the walk
      ## returns, what the parent reads back as this branch's descendant
      ## Reach. See `reach` and ADR 0036
    cursor: TokenCursor
      ## The tokens left to parse, the spec for the *live* walk position,
      ## and whether `--` has been crossed -- consulted by `classify`/
      ## `match` as the walk progresses; `cursor.spec` is never
      ## retroactively overwritten by a failed sibling's own descent (see
      ## `Report.adopt`). See `TokenCursor` (`tokens.nim`)
    command: string
      ## The command string up to the current subcommand, for the live
      ## walk position -- names the level `cursor.spec` governs
    levels: seq[Level]
      ## Every grammar level entered on this path, root-first. Seeded with
      ## the root entry by `parse*` (the completion path neither seeds nor
      ## reads it) and appended to as `match`'s `Command` branch descends;
      ## a losing branch's entry is discarded with the branch, since
      ## `walk` clones the whole context per candidate transition
    report: Report
      ## The furthest-reaching fsm path's own failure -- complaints,
      ## leftovers, and the Spec/command to render them against. See
      ## `complaints.nim` and `docs/architecture.md` §3b.
    matches: MatchTable
      ## A table of processed matches
    tiers: Tiers
      ## Value Precedence's two fallback tiers -- see `Tiers`
      ## (`precedence.nim`)

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
    # Always matches, forcing pc.cursor.optsEnd regardless of whether a
    # literal `--` is actually there to consume -- see ADR 0020.
    if pc.cursor.len > 0:
      discard pc.cursor.consumeOptsEnd(0)
    pc.cursor.optsEnd = true
    result = true
  of Argument:
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
  of Command:
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
  of Option:
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
  of Options:
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

proc reach(pc: ParseContext): Reach =
  ## This path's Reach (`CONTEXT.md`): where the first token it could not
  ## consume sits, or `int.high` if it consumed everything. Ranks failed
  ## branches in `walk` -- see ADR 0036.
  if pc.cursor.len == 0: (int.high, 0)
  else: (pc.cursor[0].idx, pc.cursor[0].subIdx)

proc walk(s: State, pc: var ParseContext): bool =
  ## Recursively matches each transition in `s` until a terminal state is
  ## reached or all branches have been tried. Returns `true` if a terminal state
  ## was reached. Matched values may be stored in `pc` by matchers.
  if s.terminal and pc.cursor.len == 0:
    return true

  # Try each transition. If it matches, recursively descend into the next state.
  for idx, tr in s.transitions:
    var fresh = pc
    # `pc.maxReach` is this level's running best across siblings; the copy
    # re-purposes the field as the descent's own output, so start it fresh.
    fresh.maxReach = (0, 0)
    if tr.matcher.match(fresh, atTerminal = s.terminal):
      fresh.report.clear()
      if tr.next.walk(fresh):
        pc = fresh
        return true

    # A failed descent leaves `fresh.cursor`'s tokens where this transition
    # left them, so the branch's real Reach is whatever its deepest
    # descendant managed.
    let branchReach = max(fresh.reach, fresh.maxReach)
    if branchReach > pc.maxReach or pc.report.isEmpty:
      # `maxReach` only ever rises -- adopting a lesser branch's complaints
      # must not lower the bar later siblings tie against. See ADR 0036.
      pc.maxReach = max(pc.maxReach, branchReach)
      pc.report.adopt(fresh.report, fresh.cursor.spec, fresh.command)
    elif branchReach == pc.maxReach:
      # A Reach-tied sibling merges its complaints into the running set
      # instead of replacing it outright -- two same-kind failures (e.g.
      # both `-h` and `--verbose` missing at the same [options] position)
      # are meant to accumulate onto one grouped line via formatComplaints.
      # Without the merge, whichever sibling happens to run last would
      # silently discard an equally-valid earlier complaint. See ADR 0036 for
      # why the exclusivity case this used to be justified by no longer is.
      pc.report.merge(fresh.report)

  # Every transition failed at a state the grammar would have stopped at, so
  # what's left is the token the user got wrong. Starved goes first (ADR
  # 0034); the guard keeps a deeper offender surfacing over this one (0035).
  if s.terminal and pc.cursor.len > 0 and not pc.report.hasLeftovers:
    if not pc.report.starved(pc.cursor):
      pc.report.leftover(pc.cursor)

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
  ## anything new, since its transitions and `pc.cursor`'s tokens are
  ## unchanged -- so skipping it is safe, not just an optimization.
  if s in seen:
    return
  seen.incl s

  if pc.cursor.len == 0:
    acc.add (s, pc)

  for tr in s.transitions:
    var fresh = pc
    # `atTerminal` stays false: completion collects live branches, never
    # complaints, so the suppression it gates is moot here -- see ADR 0037.
    if tr.matcher.match(fresh, atTerminal = false):
      if fresh.cursor.len < pc.cursor.len:
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
        of Option: describeVariants(tr.matcher.opt, pc.cursor.spec.bareVariants(tr.matcher.opt, tr.matcher.variant))
        of Options:
          collect:
            for opt in tr.matcher.opts:
              for c in describeVariants(opt, pc.cursor.spec.bareVariants(opt)): c
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
        if arg.kind == Optional and name in pc.cursor.spec.bareVariants(arg) and arg notin seenArgs:
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
    var pc = ParseContext(cursor: initCursor(spec, committed), command: command)
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
  var pc = ParseContext(cursor: initCursor(spec, priorWords), command: command)
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

proc dispatch(levels: seq[Level], idx: int, matches: MatchTable, info: HookInfo) =
  ## Recursively dispatches `levels[idx]` and, if the walk descended past it,
  ## whichever level it routes to -- firing `before`/`action`/`after` per
  ## `docs/adr/0009-command-before-action-after-hooks.md`. Stays recursive
  ## rather than looping: the nested `try`/`finally` is what unwinds `after`
  ## leaf-to-root. `info` is computed once by `parse*` and threaded through
  ## unchanged, so every level's hooks see the same whole-invocation view --
  ## see `docs/adr/0021-hook-info-matched-args.md`.
  ##
  ## Values are already parsed for every matched level by the time this
  ## runs (`parseAllValues`, called from `parse*`), so a hook at any depth
  ## sees the whole tree's values, not just its own level's -- see
  ## `docs/adr/0032-parse-all-values-before-dispatch.md`.
  let (spec, command) = levels[idx]
  if not spec.before.isNil:
    spec.before(info)
  try:
    parseMessageArgs(spec, matches, command)
    if idx == levels.high:
      if not spec.action.isNil:
        spec.action(info)
    else:
      dispatch(levels, idx + 1, matches, info)
  finally:
    if not spec.after.isNil:
      spec.after(info)

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

  var pc = ParseContext(cursor: initCursor(spec, args), command: command,
    report: initReport(spec, command), levels: @[(spec: spec, command: command)])
  if not spec.fsm.walk(pc):
    pc.report.raiseParseFailure()

  # A conversion/validation failure gets the same complaint-plus-usage shape
  # as any other. Reshaped here because `arg.parse` has no view of its spec
  # -- see ADR 0035.
  template reshaped(body: untyped) =
    try:
      body
    except ParseError as e:
      var r = initReport(pc.cursor.spec, pc.command)
      r.note(e.msg)
      r.raiseParseFailure()
    except ValidationError as e:
      var r = initReport(pc.cursor.spec, pc.command)
      r.note(e.msg)
      raise newException(ValidationError, r.failureMessage)

  # Tiers applied strongest-first, which is Value Precedence read top-down.
  # Consequence: a bad command-line value now surfaces before a bad env one,
  # where it used to be the other way round -- see ADR 0039.
  reshaped:
    parseAllValues(pc.matches)

  var fallback = initReport(pc.cursor.spec, pc.command)
  reshaped:
    applyFallbacks(pc.tiers, pc.levels.mapIt(it.spec), fallback)
  if not fallback.isEmpty:
    fallback.raiseParseFailure()

  let info = HookInfo(matched: matchedArgs(pc.matches))
  dispatch(pc.levels, 0, pc.matches, info)

