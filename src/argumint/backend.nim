import std/[algorithm, hashes, pegs, sequtils, strformat, strutils, sugar, tables]


type
  ParseError* = object of CatchableError
  MessageError* = object of CatchableError
  HelpError* = object of MessageError

  ArgKind* {.pure.} = enum
    Command ## A subcommand (e.g., `clone`)
    Positional ## A positional argument (e.g., `<arg>`)
    Optional ## An optional argument that takes a value (e.g., `-o value` or `--option value`)
    Flag ## An optional argument that takes no value (e.g., `-f` or `--flag`)

  Arg* = ref object of RootObj
    kind*: ArgKind
    variants*: seq[string] ## The forms in which the argument may appear
    help*: string ## The help string for the argument
    group*: string ## The group where the argument should appear in help messages

  CommandArg* = ref object of Arg
    spec*: Spec
    handler*: proc ()

  MessageArg* = ref object of Arg
    message*: string

  HelpArg* = ref object of MessageArg

  Spec* = ref object
    prolog*: string ## Front matter for a help message
    epilog*: string ## Back matter for a help message
    usage*: string ## Usage string used to build the FSM for parsing
    args*: seq[Arg] ## List of all args known to this spec
    commands*: OrderedTable[string, CommandArg] ## Maps command variants to args
    arguments*: OrderedTable[string, Arg] ## Maps positional arg variants to args
    options*: OrderedTable[string, Arg] ## Maps option and flag arg variants to args
    groups*: OrderedTable[string, seq[Arg]] ## List of args in each group
    fsm*: State ## The initial state for the FSM used for parsing

  State* = ref object
    ## The basic building block of the FSM. A state can be final or not and has
    ## transitions to other states.
    terminal*: bool
    transitions*: seq[Transition]

  Transition = ref object
    ## If a transition's matcher matches, the next state can be reached.
    matcher*: Matcher
    next*: State

  MatcherKind* {.pure.} = enum
    Option, Options, Command, Argument, Shortcut

  Matcher* = object
    case kind*: MatcherKind
    of Argument:
      arg*: Arg
    of Option:
      opt*: Arg
    of Options:
      opts*: seq[Arg]
    of Command:
      cmd*: CommandArg
    else:
      discard

proc formatUsage*(usage: string, command: string): string =
  var lines = @["Usage:"]
  for line in usage.split(peg"\n!\s"):
    lines.add fmt"  {command} {line}"
  result = lines.join("\n")

proc raiseParseError*(msg: string) =
  raise newException(ParseError, msg)

proc raiseParseError*(msg: string, command: string, spec: Spec) =
  raiseParseError("{msg}\n\n{spec.usage.formatUsage(command)}".fmt)

proc name*(self: Arg, variant = ""): string =
  ## Returns the seen name `variant` or the first name of `self` if blank.
  if variant.len > 0: variant else: self.variants[0]

proc hash*(self: Arg): Hash =
  ## Hash function for args so they can be used as keys in tables.
  hash(self.name)

method parse*(self: Arg, value: string, variant = "") {.base.} =
  raise newException(Defect, fmt"parse() is not defined for {self.name(variant)}")

method parse*(self: Arg, command: string, spec: Spec, variant = "") {.base.} =
  raise newException(Defect, fmt"parse() is not defined for {self.name(variant)}")

func priority(m: Matcher): int {.inline.} =
  ## Returns the priority of the matcher, allowing them to be sorted by
  ## priority.
  ord(m.kind)

proc name*(m: Matcher): string {.inline.} =
  ## Returns the name of the matcher. Usually, this will be the first declared
  ## variant of its arg, but some matchers have special names.
  case m.kind
  of Shortcut: "*"
  of Command: fmt"Cmd({m.cmd.name})"
  of Argument: fmt"Arg({m.arg.name})"
  of Option: fmt"(Opt({m.opt.name})"
  of Options:
    let names = collect:
      for opt in m.opts: opt.name
    fmt"""Opts({names.join(" | ")})"""

func isShortcut*(m: Matcher): bool {.inline.} =
  ## Returns whether a given matcher is a shortcut.
  m.kind == Shortcut

proc newShortcut*(): Matcher =
  ## Returns a new shortcut `Matcher`. A shortcut will always match.
  Matcher(kind: Shortcut)

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

proc sortTransitions(s: State, visited = newTable[State, bool]()) =
  ## Recursively sorts all transitions for `s` by their matchers' priorities.
  ## `visited` tracks whether the state has been sorted already to avoid an
  ## infinite loop.
  if visited.hasKeyOrPut(s, true):
    return

  s.transitions.sort((a, b: Transition) => cmp(a.matcher.priority, b.matcher.priority))
  for t in s.transitions:
    sortTransitions(t.next, visited)

proc simplifySelf(s: State): bool =
  ## Simplifies the transitions of `s`. If `s` has a shortcut to another state
  ## `e`, will copy all transitions from `e` to `s` and remove the shortcut. If
  ## `e` was terminal, `s` will be marked as terminal as well. Returns whether
  ## any shortcuts were removed.
  if s.transitions.len == 0:
    return false

  var idx = 0
  while idx < s.transitions.len:
    let
      tr = s.transitions[idx]
      next = tr.next
    if tr.matcher.isShortcut:
      s.transitions.delete idx

      # Copy all transitions from tr.next to s that are not:
      # - already present in s or
      # - shortcuts to s or tr.next
      for idx, tr in next.transitions:
        # Don't copy any transitions that already exist
        if tr in s.transitions:
          continue

        # Don't copy the transition if it's a shortcut to its own state or to s
        if tr.matcher.isShortcut and tr.next in [s, next]:
          continue

        s.transitions.add tr
        result = true

      # If s has a shortcut to a terminal state e, s short be terminal as well
      if next.terminal:
        s.terminal = true
    idx.inc

proc simplify(s: State, visited = newTable[State, bool]()) =
  ## Recursively simplifies the transitions of `s`. If `s` has a shortcut to
  ## another state `e`, will copy all transitions from `e` to `s` and remove the
  ## shortcut. If `e` was terminal, `s` will be marked as terminal as well.
  ## `visited` tracks whether the state has been simplified already to avoid an
  ## infinite loop.
  if visited.hasKeyOrPut(s, true):
    return

  for tr in s.transitions:
    tr.next.simplify(visited)

  while s.simplifySelf:
    discard

proc prepare*(s: State) =
  ## Simplifies the fsm with root node `s` and recursively sorts all transitions
  ## according to their matchers' priorities.
  s.simplify()
  s.sortTransitions()
