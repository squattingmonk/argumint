## This module parses tokens from the spec lexer and constructs an FSM that will
## support matching of command-line arguments and high-level validation of usage
## patterns.

import std/[pegs, sequtils, sets, strformat, strutils, tables]

import ./[backend, fsmgraph, lexer]
export lexer.SpecDefect

type
  SpecParser = ref object
    lex: SpecLexer ## Tokenizer
    tok: SpecToken ## Lookahead token
    spec: Spec
    explicitOptions: HashSet[Arg] ## Options explicitly mentioned on the
      ## current Usage Line, populated as a side effect of atom's own
      ## tkShortOption/tkLongOption/tkShortOptions branches as it parses that
      ## line, so `[options]` can exclude them (see `tkAnyOption` below)
      ## rather than making them separately repeatable. Reset per line by
      ## `genFsm`, since `[options]` only excludes what's explicit on its own
      ## Usage Line, not elsewhere in the Usage String.
    pendingOptions: seq[Matcher] ## Matchers created by the current line's
      ## `tkAnyOption` atoms, deferred here because `explicitOptions` isn't
      ## complete until the whole line has been parsed (a later atom on the
      ## same line can still name an option `[options]` needs to exclude).
      ## `genFsm` patches each one's `opts` once the line is done, then
      ## clears this for the next line. Holds the `Matcher` itself, not the
      ## `Transition` it started out on -- see `Matcher`'s own doc comment
      ## (`backend.nim`) for why that distinction matters.

const CanAtom = {tkParensOpen, tkBracketOpen, tkCommand..tkAnyOption, tkOptsEnd}

proc next(p: SpecParser) =
  ## Advance the spec parser to the next token.
  p.tok = p.lex.next

proc peek(p: SpecParser, kinds: set[SpecTokenKind]): bool =
  ## Returns whether the next spec token is in `kinds`.
  p.tok.kind in kinds

proc eat(p: SpecParser, kinds: set[SpecTokenKind]): SpecToken =
  ## If the next spec token is in `kinds`, return it and advance the spec parser
  ## to the next token. Otherwise, throw an error.
  let expected = if kinds.len > 1: fmt"one of {kinds}" else: $kinds
  if p.peek {tkEof}:
    p.tok.error(fmt"Unexpected end of input; expected {expected}")

  if not p.peek kinds:
    p.tok.error(fmt"Expected {expected} but got {p.tok.literal.escape} ({p.tok.kind})")

  result = p.tok
  p.next

proc atom(p: SpecParser, seenCommand: bool, seenOptsEnd: bool): tuple[a: State, b: State, hasCommand: bool, hasOptsEnd: bool]

proc trivialArg(child: tuple[a: State, b: State, hasCommand: bool, hasOptsEnd: bool]): tuple[arg: Arg, variant: string] =
  ## If `child` is nothing but a single Option or Argument matcher straight
  ## from `a` to `b` (not repeated via `...`, not part of a larger sequence
  ## or a bracket/`[options]` construct -- those all leave more than one
  ## transition on `a`), returns the Arg it matches and the variant it was
  ## declared with (`""` for Argument, which has no variant concept). `arg`
  ## is nil for anything else, including an Options-kind cluster (`-abc`)
  ## -- not reducible to one Arg/variant, so `choice` never dedups it away.
  if child.a.transitions.len == 1 and child.b.transitions.len == 0:
    let tr = child.a.transitions[0]
    if tr.next == child.b:
      case tr.matcher.kind
      of Option: result = (tr.matcher.opt, tr.matcher.variant)
      of Argument: result = (tr.matcher.arg, "")
      else: discard

proc choice(p: SpecParser, seenCommand: bool, seenOptsEnd: bool): tuple[a: State, b: State, hasCommand: bool, hasOptsEnd: bool] =
  ## Constructs a choice (e.g., `this | that`). Note `this` is still a choice.
  var children = newSeq[tuple[a: State, b: State, hasCommand: bool, hasOptsEnd: bool]]()
  children.add p.atom(seenCommand, seenOptsEnd)
  while p.peek {tkChoice}:
    p.next()
    children.add p.atom(seenCommand, seenOptsEnd)

  if children.len == 1:
    return children[0]

  var
    a = newState()
    b = newState()
    seen = newSeq[tuple[arg: Arg, variant: string]]()
    hasCommand = false
    hasOptsEnd = false

  for child in children:
    hasCommand = hasCommand or child.hasCommand
    hasOptsEnd = hasOptsEnd or child.hasOptsEnd
    # A later alternative is redundant only if some earlier one already
    # covers its exact (Arg, variant) via Arg.aliases -- so FlagOp Alias
    # Flag variants (-v/--verbose) still collapse, but non-aliased ones
    # (--boost/--dampen) stay independently reachable.
    let (arg, variant) = child.trivialArg
    if arg != nil:
      if seen.anyIt(it.arg == arg and arg.aliases(it.variant, variant)):
        continue
      seen.add (arg, variant)
    a.addShortcut(child.a)
    child.b.addShortcut(b)

  return (a, b, hasCommand, hasOptsEnd)

proc sequence(p: SpecParser, required = true, seenCommand = false, seenOptsEnd = false): tuple[a: State, b: State, hasCommand: bool, hasOptsEnd: bool] =
  ## Constructs a new sequence (e.g., `this that`). If `required` is `true`, the
  ## sequence must have child nodes.
  var
    a = newState()
    b = a
    hasCmd = seenCommand
    hasOpts = seenOptsEnd

  proc add(x, y: State) =
    # Add all transitions in x to b, then set b to y.
    for tr in x.transitions:
      b.add(tr.next, tr.matcher)
    b = y

  if required:
    let child = p.choice(hasCmd, hasOpts) # child.a == a == b
    add(child.a, child.b) # child.a == a, child.b == b
    hasCmd = hasCmd or child.hasCommand
    hasOpts = hasOpts or child.hasOptsEnd

  while p.peek CanAtom:
    let child = p.choice(hasCmd, hasOpts)
    add(child.a, child.b)
    hasCmd = hasCmd or child.hasCommand
    hasOpts = hasOpts or child.hasOptsEnd
  return (a, b, hasCmd, hasOpts)

proc atom(p: SpecParser, seenCommand: bool, seenOptsEnd: bool): tuple[a: State, b: State, hasCommand: bool, hasOptsEnd: bool] =
  ## Generates a partial FSM for the next token if it represents or begins an
  ## atom. Returns a beginning and ending state for the atom.
  result.a = newState()
  if seenCommand:
    p.tok.error("Nothing may follow a Command earlier in the same Usage " &
      "Line -- a matched Command consumes every remaining argument, so " &
      "anything after it can never be reached; use '(a | b)' for " &
      "alternatives, or move it into the earlier Command's own usage")
  let token = p.eat CanAtom
  if seenOptsEnd and token.kind notin {tkArgument, tkParensOpen, tkBracketOpen}:
    token.error("Only a Positional Argument may follow the End-of-Options " &
      "Marker ('--') earlier in the same Usage Line -- an Option, Flag, " &
      "[options], Command, or a second '--' can never be reached there, " &
      "since a matched Marker forces every later token to be treated as " &
      "a positional value")
  case token.kind
  of tkArgument:
    if token.literal notin p.spec.arguments:
      token.error(fmt"Undeclared argument: {token.literal}")
    result.b = result.a.add(newArgMatcher(p.spec.arguments[token.literal]))
  of tkShortOption, tkLongOption:
    if token.literal notin p.spec.options:
      token.error(fmt"Undeclared option: {token.literal}")
    let opt = p.spec.options[token.literal]
    p.explicitOptions.incl opt
    result.b = result.a.add(newOptMatcher(opt, token.literal))
    if p.peek {tkOptionValue}:
      p.next()
  of tkShortOptions:
    # Sugar for the sequence `-a -b -c` -- chains one Option matcher per
    # letter instead of one shared Options matcher, so every letter is its
    # own mandatory, single-match atom (see docs/adr/0025).
    result.b = result.a
    for c in token.literal.substr(1):
      let name = fmt"-{c}"
      if name notin p.spec.options:
        token.error(fmt"Undeclared option in {token.literal}: {name}")
      let opt = p.spec.options[name]
      p.explicitOptions.incl opt
      result.b = result.b.add(newOptMatcher(opt, name))
    if p.peek {tkOptionValue}:
      p.next()
  of tkAnyOption:
    # Built unfiltered; genFsm patches this matcher's opts once
    # explicitOptions is final for the line -- see architecture.md §2.
    let matcher = newOptsMatcher(p.spec.options.values.toSeq.deduplicate()
      .filterIt(not (it of MessageArg)))
    p.pendingOptions.add matcher
    result.b = result.a.add(matcher)
    result.a.addShortcut(result.b) # Make it optional
    result.b.addShortcut(result.a) # Make it repeatable by default (ADR 0002)
  of tkCommand:
    if token.literal notin p.spec.commands:
      token.error(fmt"Undeclared command: {token.literal}")
    let cmd = p.spec.commands[token.literal]
    result.b = newState()
    for s in cmd.spec.fsm.terminals:
      s.addShortcut(result.b)
    result.a.add(cmd.spec.fsm, newCmdMatcher(cmd))
    result.hasCommand = true
  of tkOptsEnd:
    result.b = result.a.add(newOptsEndMatcher())
    result.hasOptsEnd = true
  of tkParensOpen:
    result = p.sequence(seenCommand = seenCommand, seenOptsEnd = seenOptsEnd)
    discard p.eat {tkParensClose}
  of tkBracketOpen:
    result = p.sequence(seenCommand = seenCommand, seenOptsEnd = seenOptsEnd)
    result.a.addShortcut(result.b)
    discard p.eat {tkBracketClose}
  else:
    assert false

  if p.peek {tkRepeat}:
    if result.hasCommand:
      token.error("A Command cannot be repeated with '...' -- a matched " &
        "Command consumes every remaining argument, so a second " &
        "repetition can never be reached; give the Command's own nested " &
        "Usage Line a repeatable atom instead if you want to match " &
        "multiple values there")
    if result.hasOptsEnd:
      token.error("The End-of-Options Marker ('--') cannot be repeated " &
        "with '...' -- the position it marks can never be meaningfully " &
        "re-entered")
    result.b.addShortcut(result.a)
    p.next()

proc addUsageLines*(spec: Spec, root: State, lines: seq[string]) =
  ## Parses each of `lines` as a Usage Line and splices its FSM onto `root`
  ## via `addShortcut` -- the shared line-building step behind both `genFsm`
  ## (the initial build) and `autoFillUsage` (`argumint.nim`, which splices
  ## auto-generated lines onto an already-built `spec.fsm` instead of
  ## re-parsing the whole usage string from scratch). Recomputes `root.
  ## terminal` afterwards rather than leaving it a stateful flag -- see
  ## docs/gotchas.md's "terminal flag" entry for why this needs both a
  ## before-splice snapshot and an after-splice transition count, not just
  ## the latter.
  let hadTransitions = root.transitions.len > 0
  let wasTerminal = root.terminal
  let p = SpecParser(spec: spec)
  for line in lines:
    p.explicitOptions.clear()
    p.pendingOptions.setLen(0)
    p.lex.open(line)
    defer: p.lex.close()
    p.tok = p.lex.next()
    let (s, e, _, _) = p.sequence(false)
    if not p.peek {tkEof}:
      p.tok.error(fmt"Unexpected token {p.tok.literal.escape} ({p.tok.kind})")
    # Only now, with the whole line parsed, is explicitOptions final --
    # patch each [options] atom's matcher to exclude it (see atom's
    # tkAnyOption branch and SpecParser.pendingOptions).
    for matcher in p.pendingOptions:
      matcher.excludeOptions(p.explicitOptions)
    root.addShortcut(s)
    e.terminal = true
  root.terminal = root.transitions.len == 0 or (hadTransitions and wasTerminal)

proc genFsm*(spec: Spec): State =
  ## Generates an FSM for `spec` based on its usage strings.
  result = newState()
  let lines = if spec.usage.len == 0: newSeq[string]() else: spec.usage.split(peg"\n!\s")
  spec.addUsageLines(result, lines)
  result.prepare()
