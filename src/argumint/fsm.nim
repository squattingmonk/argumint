import std/[algorithm, hashes, sequtils, strutils, sugar, tables]

# import std/strutils

import blarg
import args

type
  UsageError = object of CatchableError

  State = ref object
    ## The basic building block of the FSM. A state can be final or not, and has
    ## transitions to other states.
    terminal*: bool
    transitions*: seq[Transition]
    name: string

  Transition = ref object
    ## If a transition's matcher matches, the next state can be reached.
    matcher: Matcher
    next: State

  MatcherKind = enum
    mkOpt
    mkArg
    mkShortcut

  Matcher = ref object
    case kind: MatcherKind
    of mkArg: arg: Arg ## The argument to match
    of mkOpt: opt: Arg ## The option to match
    else: discard

  Match = tuple[variant: string, value: string]

  ParseContext* = object of OptParser
    ## Holds the state of argument parsing (i.e., the arguments and options seen
    ## and their associated values).
    optsIdx: Table[string, Arg]    ## Maps variants to opts
    seen: Table[Arg, seq[Match]] ## Maps args to a seen variant and its value

func priority(m: Matcher): int {.inline.} =
  ord(m.kind)

func name(m: Matcher): string {.inline.} =
  case m.kind
  of mkShortcut: "*"
  of mkArg: "Arg($#)" % m.arg.name
  of mkOpt: "Opt($#)" % m.opt.name

proc newArgMatcher*(arg: Arg): Matcher =
  ## Creates a new Matcher for an argument `arg`.
  assert(arg.kind == akPositional)
  Matcher(kind: mkArg, arg: arg)

proc newOptMatcher*(opt: Arg): Matcher =
  ## Creates a new Matcher for an option `opt`.
  assert(opt.kind == akOptional)
  Matcher(kind: mkOpt, opt: opt)

proc newShortcut*(): Matcher =
  ## Creates a new shortcut matcher. A shortcut will always match.
  Matcher(kind: mkShortcut)

proc isShortcut(m: Matcher): bool {.inline.} =
  ## Returns whether a given matcher is a shortcut.
  m.kind == mkShortcut

proc match(m: Matcher, p: var ParseContext): bool =
  case m.kind
  of mkShortcut:
    result = true
  of mkArg:
    if p.kind == cmdArgument:
      result = true
      if p.seen.hasKeyOrPut(m.arg, @[(m.arg.name, p.key)]):
        p.seen[m.arg].add((m.arg.name, p.key))
      p.next
  of mkOpt:
    case p.kind
    of cmdShortOption, cmdLongOption:
      let key = (if p.kind == cmdShortOption: "-" else: "--") & p.key
      if key in p.optsIdx and p.optsIdx[key] == m.opt:
        result = true
        if p.seen.hasKeyOrPut(m.opt, @[(key, p.val)]):
          p.seen[m.opt].add((key, p.val))
        p.next
    of cmdEnd:
      return m.opt.setByEnv
    else: discard

proc hash(s: State): Hash {.used.} =
  hash(s.name)

proc newState(name: string = "", terminal: bool = false): State =
  result = new State
  result.name = name
  result.terminal = terminal

proc `==`(t1, t2: Transition): bool =
  t1.matcher == t2.matcher and t1.next == t2.next

proc shortcutTo(t: Transition, s: varargs[State]): bool =
  t.matcher.isShortcut and t.next in s

proc add*(s, next: State, matcher: Matcher): State =
  ## Creates a new transition between two states.
  s.transitions.add(Transition(matcher: matcher, next: next))
  result = next

proc addShortcut*(s, next: State): State =
  ## Creates a shortcut transition between two states
  result = s.add(next, newShortcut())

proc sortTransitions(s: State, visited = newTable[State, bool]()) =
  ## Recursively sorts all transitions for `s` by their matcher's priorities.
  ## `visited` tracks whether the state has been sorted already to avoid an
  ## infinite loop.
  if visited[].hasKeyOrPut(s, true):
    return

  s.transitions.sort((a, b: Transition) => cmp(a.matcher.priority, b.matcher.priority))
  for t in s.transitions:
    sortTransitions(t.next, visited)

proc simplifySelf(s: State): bool =
  ## Simplifies the transitions of `s`. If `s` has a shortcut to another state
  ## `e`, will copy all transitions from `e` to `s` and remove the shortcut. If
  ## `e` was terminal, `s` will be marked as terminal as well. Returns whether
  ## any shortcuts were removed.
  # echo "Evaluating transitions for ", s.name
  for (idx, tr) in s.transitions.pairs.toSeq.filterIt(it.val.matcher.isShortcut):
  # var idx = 0
  # while idx < s.transitions.len:
  #   let tr = s.transitions[idx]
    # echo "  $1$2 ($3) -> $4" % [s.name, $idx, tr.matcher.name, tr.next.name]
  #   if tr.matcher.shortcut:
    # echo "    $1$2 is a shortcut. Removing..." % [s.name, $idx]
    s.transitions.del(idx)

    # Copy all transtions from tr.next to s that are not:
    # - already present in s or
    # - shorcuts to s or tr.next
    for tr in tr.next.transitions.filterIt(it notin s.transitions and not it.shortcutTo(tr.next, s)):
    # echo "    Copying transitions from $1 to $2" % [next.name, s.name]
    # for tr in next.transitions:
      # echo "      Checking transition $1$2 ($3) -> $4" % [next.name, $idx, tr.matcher.name, tr.next.name]
      # Don't copy any transitions that already exist
      # if tr in s.transitions:
      #   # echo "        $1$2 matches a transition in $3. Skipping..." % [next.name, $idx, s.name]
      #   continue
      # Don't copy the transition if it's a shortcut to its own state or to s
      # if tr.matcher.shortcut and (tr.next == next or tr.next == s):
      #   # echo "        $1$2 is a shortcut to $3. Skipping..." % [next.name, $idx, tr.next.name]
      #   continue
      # echo "copying ", next.name, idx, " to ", s.name, s.transitions.len
      # echo "        Copying $1$2 ($3) to $4" % [next.name, $idx, tr.matcher.name, s.name]
      s.transitions.add(tr)
      result = true

    # If s has a shortcut to a terminal state e, s should be terminal as well
    if tr.next.terminal:
      # echo "    $1 is terminal. Setting $2 to terminal..." % [next.name, s.name]
      s.terminal = true
  #   idx.inc
  # echo "  No shortcuts found"

proc simplify(s: State, visited = newTable[State, bool]()) =
  ## Recursively simplifies the transitions of `s`. If `s` has a shortcut to
  ## another state `e`, will copy all transitions from `e` to `s` and remove the
  ## shortcut. If `e` was terminal, `s` will be marked as terminal as well.
  ## `visited` tracks whether the state has been simplified already to avoid an
  ## infinite loop. The implementation is based on
  ## https://jawher.me/parsing-command-line-arguments-finite-state-machine-backtracking/#simplification
  if visited[].hasKeyOrPut(s, true):
    # echo "  $1 has already been visited. Skipping..." % s.name
    return

  # echo "Simplifying ", s.name
  for tr in s.transitions:
    # echo "  $1 has a transition to $2. Simplifying $2..." % [s.name, tr.next.name]
    tr.next.simplify(visited)

  # echo "  We cannot go any lower. Simplifying $1" % s.name
  while s.simplifySelf:
    discard
    # echo s.transitions.len

proc prepare(s: State) =
  ## Simplifies the FSM and sorts transitions according to their matchers'
  ## priorities.
  s.simplify
  s.sortTransitions

proc apply(s: State, pc: var ParseContext): bool =
  ## Recursively matches each transition in `s` until a terminal state is
  ## reached or all branches have been tried. Returns `true` if the parse was
  ## successful. The parsed values will be stored in `pc`.
  if s.terminal and pc.kind == cmdEnd:
    echo s.name, " is terminal"
    return true

  # Try each transition. If it matches, recursively descend into the next state.
  for idx, tr in s.transitions:
    echo "Trying transition ", s.name, $idx, ": ", tr.matcher.name, " to ", tr.next.name
    var fresh = pc
    if tr.matcher.match(fresh) and tr.next.apply(fresh):
      pc = fresh
      return true
    # a usage message to send to the parent's scope
    pc.message = fresh.message

proc parse*(s: State, pc: var ParseContext) =
  ## Attempts to navigate the FSM according to the provided parser.
  if not s.apply(pc):
    raise newException(UsageError, pc.message)

  for arg, matches in pc.seen:
    for (variant, value) in matches:
      arg.set(value, variant)
    arg.setByEnv = false
    arg.setByUser = true




when isMainModule:
  proc dumpTransitions(states: openarray[State]) =
    for state in states:
      echo "\nState ", state.name, if state.terminal: " (terminal)" else: " (non-terminal)"
      for idx, tr in state.transitions:
        echo state.name, idx, " (", tr.matcher.name, ") -> ", tr.next.name, " (priority: ", tr.matcher.priority, ")"

  let
    s: State = newState("s")
    e: State = newState("e", terminal = true)
    arg = newStringArg(@["<src>"], "A string arg") {.explain.}

  var p: ParseContext
  p.initOptParser(cmdLine = @["foo", "bar"])
  p.next
  echo p.kind, ": ", p.key, " -> ", p.val

  discard s.add(e, newArgMatcher(arg))
  # discard s.add(e, Matcher(priority: 1))
  discard s.addShortcut(e)
  # discard e.addShortcut(s)
  # discard e.add(s, Matcher(priority: 0))

  dumpTransitions([s, e])
  echo ""

  s.prepare

  echo ""
  dumpTransitions([s, e])

  echo ""
  s.parse(p)

  echo arg.value

