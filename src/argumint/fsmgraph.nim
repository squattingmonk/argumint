## Builds and simplifies the FSM graph (`State`/`Transition`/`Matcher`,
## `backend.nim`) that drives parsing -- `parser.nim` calls these while
## compiling a Usage String, `fsm.nim`/`dot.nim` each call one directly (see
## `docs/architecture.md` §2). The graph's own data model (the types
## themselves) lives in `backend.nim`; this module is purely the
## construction/simplification mechanics layered on top of it.

import std/[algorithm, hashes, sequtils, sets, strformat, strutils, sugar, tables]

import ./backend

func priority(m: Matcher): int {.inline.} =
  ## Returns the priority of the matcher, allowing them to be sorted by
  ## priority.
  ord(m.kind)

proc name*(m: Matcher): string {.inline.} =
  ## Returns the name of the matcher. Usually, this will be the first declared
  ## variant of its arg, but some matchers have special names.
  case m.kind
  of Shortcut: "*"
  of OptsEnd: "--"
  of Command: fmt"Cmd({m.cmd.name})"
  of Argument: fmt"Arg({m.arg.name})"
  of Option: fmt"Opt({m.opt.name})"
  of Options:
    let names = collect:
      for opt in m.opts: opt.name
    fmt"""Opts({names.join(" | ")})"""

func isShortcut*(m: Matcher): bool {.inline.} =
  ## Returns whether a given matcher is a shortcut.
  m.kind == Shortcut

proc underlyingArg*(m: Matcher): Arg =
  ## The Arg an Option or Argument matcher matches directly, or `nil` for any
  ## other kind -- `Options`/`Command`/`Shortcut` don't match a single Arg the
  ## way a caller collapsing a trivial choice alternative needs.
  case m.kind
  of Option: m.opt
  of Argument: m.arg
  else: nil

proc excludeOptions*(m: Matcher, exclude: HashSet[Arg]) =
  ## Removes every Arg in `exclude` from an `Options` matcher's candidate
  ## list -- used so `[options]` can drop an option mentioned explicitly
  ## elsewhere on the same Usage Line (see `parser.genFsm`).
  assert m.kind == Options
  m.opts = m.opts.filterIt(it notin exclude)

proc newShortcut*(): Matcher =
  ## Returns a new shortcut `Matcher`. A shortcut will always match.
  Matcher(kind: Shortcut)

proc newOptsEndMatcher*(): Matcher =
  ## Returns a new end-of-options-marker `Matcher`. Always matches -- see
  ## `docs/adr/0020-usage-string-end-of-options-marker.md`.
  Matcher(kind: OptsEnd)

proc newArgMatcher*(arg: Arg): Matcher =
  ## Creates a new `Matcher` for an argument `arg`.
  assert arg.kind == Positional
  Matcher(kind: Argument, arg: arg)

proc newOptMatcher*(opt: Arg): Matcher =
  ## Creates a new `Matcher` for an option or flag `opt`.
  assert opt.kind in [Optional, Flag]
  Matcher(kind: Option, opt: opt)

proc newOptsMatcher*(opts: openArray[Arg]): Matcher =
  ## Creates a new `Matcher` for an option or flag in `opts`.
  assert opts.allIt(it.kind in [Optional, Flag])
  Matcher(kind: Options, opts: @opts)

proc newCmdMatcher*(cmd: CommandArg): Matcher =
  ## Creates a new `Matcher` for a command `cmd`.
  assert cmd.kind == Command
  Matcher(kind: Command, cmd: cmd)

func newState*(terminal = false): State =
  ## Creates a new `State`. If `terminal` is true and there are no more
  ## arguments to process after the state has been reached, FSM navigation will
  ## be deemed successful.
  State(terminal: terminal)

proc add*(s: State, next: State, matcher: Matcher) =
  ## Creates a transition between two states that can be followed if `matcher`
  ## matches.
  s.transitions.add(Transition(matcher: matcher, next: next))

proc add*(s: State, matcher: Matcher): State =
  ## Creates a new State, adds a transition from `s` to it that can be followed
  ## if `matcher` matches, and returns the new state.
  result = State(terminal: false)
  s.add(result, matcher)

proc addShortcut*(s: State, next: State) =
  ## Adds a shortcut between two states.
  s.add(next, newShortcut())

proc terminals(s: State, states: var seq[State], visited = newTable[State, bool]()) =
  visited[s] = true
  for tr in s.transitions:
    if tr.next notin visited:
      if tr.next.terminal:
        states.add tr.next
      tr.next.terminals(states, visited)

iterator terminals*(s: State): State =
  ## Iterates over all terminal states in the fsm with root note `s` using a
  ## depth-first approach.
  var states: seq[State] = @[]
  s.terminals(states)
  for state in states:
    yield state

proc collectArgs(s: State, args: var HashSet[Arg], visited = newTable[State, bool]()) =
  if visited.hasKeyOrPut(s, true):
    return
  for tr in s.transitions:
    case tr.matcher.kind
    of Argument: args.incl tr.matcher.arg
    of Option: args.incl tr.matcher.opt
    of Options:
      for opt in tr.matcher.opts:
        args.incl opt
    of Command: args.incl tr.matcher.cmd
    of OptsEnd: discard
    of Shortcut: discard
    tr.next.collectArgs(args, visited)

proc referencedArgs*(s: State): HashSet[Arg] =
  ## Returns every `Arg` referenced by a matcher reachable from `s`. Used to
  ## detect whether a declared arg (e.g. one created by `help()`) is actually
  ## reachable via the usage grammar, so it can be added automatically if not.
  s.collectArgs(result)

proc sortTransitions(s: State, visited = newTable[State, bool]()) =
  ## Recursively sorts all transitions for `s` by their matchers' priorities.
  ## `visited` tracks whether the state has been sorted already to avoid an
  ## infinite loop.
  if visited.hasKeyOrPut(s, true):
    return

  s.transitions.sort((a, b: Transition) => cmp(a.matcher.priority, b.matcher.priority))
  for t in s.transitions:
    sortTransitions(t.next, visited)

proc shortcutClosure(s: State): tuple[states: seq[State], terminal: bool] =
  ## Every state reachable from `s` via zero or more Shortcut-kind
  ## transitions (the epsilon-closure), in discovery order, plus whether any
  ## of them is terminal. `states` grows as it's scanned (a queue via
  ## index, not `.pop()`), preserving the same left-to-right discovery order
  ## `simplifySelf` used to produce, so downstream ordering (e.g. grouped
  ## error messages) doesn't depend on `HashSet[State]`'s unspecified
  ## iteration order. Bounded by `seen`, so this always terminates
  ## regardless of shortcut chains or cycles -- see docs/gotchas.md.
  var seen: HashSet[State]
  seen.incl s
  result.states.add s
  result.terminal = s.terminal
  var idx = 0
  while idx < result.states.len:
    let cur = result.states[idx]
    for tr in cur.transitions:
      if tr.matcher.isShortcut and tr.next notin seen:
        seen.incl tr.next
        result.states.add tr.next
        if tr.next.terminal:
          result.terminal = true
    idx.inc

proc simplifySelf(s: State) =
  ## Collapses every shortcut chain or cycle reachable from `s` directly
  ## onto `s`'s own transitions, via `s`'s shortcut-closure.
  let closure = s.shortcutClosure()
  var newTransitions: seq[Transition]
  for st in closure.states:
    for tr in st.transitions:
      if not tr.matcher.isShortcut and tr notin newTransitions:
        newTransitions.add tr
  s.transitions = newTransitions
  s.terminal = closure.terminal

proc simplify(s: State, visited = newTable[State, bool]()) =
  ## Recursively simplifies the transitions of `s` -- see `simplifySelf`.
  ## `visited` tracks whether the state has been simplified already to avoid
  ## an infinite loop.
  if visited.hasKeyOrPut(s, true):
    return

  for tr in s.transitions:
    tr.next.simplify(visited)

  s.simplifySelf()

proc prepare*(s: State) =
  ## Simplifies the fsm with root node `s` and recursively sorts all transitions
  ## according to their matchers' priorities.
  s.simplify()
  s.sortTransitions()
