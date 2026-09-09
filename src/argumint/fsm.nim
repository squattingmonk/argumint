## This module handles the navigation of the FSM based on a set of provided
## command-line arguments.
import std/[algorithm, importutils, options, os, sequtils, strformat, strutils,
  sugar, tables]

import ./[backend, complaints, completion, configsource, errors, matching,
  parser, precedence, tokens]
export ParseError, SpecDefect, CompletionError

# Reaches `Spec`'s private fields (ADR 0030) from non-generic code only -- see
# docs/gotchas.md.
privateAccess(Spec)


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
