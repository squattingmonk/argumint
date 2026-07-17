## This module parses tokens from the spec lexer and constructs an FSM that will
## support matching of command-line arguments and high-level validation of usage
## patterns.

import std/[pegs, sequtils, sets, strformat, strutils, tables]

import ./[backend, lexer]
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

const CanAtom = {tkParensOpen, tkBracketOpen, tkCommand..tkAnyOption}

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

proc atom(p: SpecParser, seenCommand: bool): tuple[a: State, b: State, hasCommand: bool]

proc trivialArg(child: tuple[a: State, b: State, hasCommand: bool]): Arg =
  ## If `child` is nothing but a single Option or Argument matcher straight
  ## from `a` to `b` (not repeated via `...`, not part of a larger sequence
  ## or a bracket/`[options]` construct -- those all leave more than one
  ## transition on `a`), returns the Arg it matches. Otherwise nil.
  if child.a.transitions.len == 1 and child.b.transitions.len == 0:
    let tr = child.a.transitions[0]
    if tr.next == child.b:
      case tr.matcher.kind
      of Option: return tr.matcher.opt
      of Argument: return tr.matcher.arg
      else: discard

proc choice(p: SpecParser, seenCommand: bool): tuple[a: State, b: State, hasCommand: bool] =
  ## Constructs a choice (e.g., `this | that`). Note `this` is still a choice.
  var children = newSeq[tuple[a: State, b: State, hasCommand: bool]]()
  children.add p.atom(seenCommand)
  while p.peek {tkChoice}:
    p.next()
    children.add p.atom(seenCommand)

  if children.len == 1:
    return children[0]

  var
    a = newState()
    b = newState()
    seenArgs: HashSet[Arg]
    hasCommand = false

  for child in children:
    hasCommand = hasCommand or child.hasCommand
    # A bare `-h`/`--help`-style alternative already matches every variant
    # of its Arg (matching compares Arg identity, not the specific variant
    # string seen), so a later alternative referencing an Arg a previous
    # one already covers contributes nothing new -- skip wiring it in
    # rather than leaving a functionally-redundant parallel branch behind.
    let arg = child.trivialArg
    if arg != nil:
      if arg in seenArgs:
        continue
      seenArgs.incl arg
    a.addShortcut(child.a)
    child.b.addShortcut(b)

  return (a, b, hasCommand)

proc sequence(p: SpecParser, required = true, seenCommand = false): tuple[a: State, b: State, hasCommand: bool] =
  ## Constructs a new sequence (e.g., `this that`). If `required` is `true`, the
  ## sequence must have child nodes.
  var
    a = newState()
    b = a
    hasCmd = seenCommand

  proc add(x, y: State) =
    # Add all transitions in x to b, then set b to y.
    for tr in x.transitions:
      b.add(tr.next, tr.matcher)
    b = y

  if required:
    let child = p.choice(hasCmd) # child.a == a == b
    add(child.a, child.b) # child.a == a, child.b == b
    hasCmd = hasCmd or child.hasCommand

  while p.peek CanAtom:
    let child = p.choice(hasCmd)
    add(child.a, child.b)
    hasCmd = hasCmd or child.hasCommand
  return (a, b, hasCmd)

proc atom(p: SpecParser, seenCommand: bool): tuple[a: State, b: State, hasCommand: bool] =
  ## Generates a partial FSM for the next token if it represents or begins an
  ## atom. Returns a beginning and ending state for the atom.
  result.a = newState()
  if seenCommand:
    p.tok.error("Nothing may follow a Command earlier in the same Usage Line -- a matched Command consumes every remaining argument, so anything after it can never be reached; use '(a | b)' for alternatives, or move it into the earlier Command's own usage")
  let token = p.eat CanAtom
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
    result.b = result.a.add(newOptMatcher(opt))
    if p.peek {tkOptionValue}:
      p.next()
  of tkShortOptions:
    var options = newSeq[Arg]()
    for idx, c in token.literal.substr(1):
      let name = fmt"-{c}"
      if name notin p.spec.options:
        token.error(fmt"Undeclared option in {token.literal}: {name}")
      options.add p.spec.options[name]
    for opt in options:
      p.explicitOptions.incl opt
    result.b = result.a.add(newOptsMatcher(options))
    if p.peek {tkOptionValue}:
      p.next()
  of tkAnyOption:
    # Can't exclude p.explicitOptions here yet -- a later atom on this same
    # line may still name an option that belongs in the exclusion set. Build
    # unfiltered (bar MessageArgs) and let genFsm patch this matcher's opts
    # once the whole line is parsed and explicitOptions is final.
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
  of tkParensOpen:
    result = p.sequence(seenCommand = seenCommand)
    discard p.eat {tkParensClose}
  of tkBracketOpen:
    result = p.sequence(seenCommand = seenCommand)
    result.a.addShortcut(result.b)
    discard p.eat {tkBracketClose}
  else:
    assert false

  if p.peek {tkRepeat}:
    if result.hasCommand:
      token.error("A Command cannot be repeated with '...' -- a matched Command consumes every remaining argument, so a second repetition can never be reached; give the Command's own nested Usage Line a repeatable atom instead if you want to match multiple values there")
    result.b.addShortcut(result.a)
    p.next()

proc genFsm*(spec: Spec): State =
  ## Generates an FSM for `spec` based on its usage strings.
  result = newState()
  if spec.usage.len == 0:
    # An empty usage string means this spec (or subcommand) takes no
    # further input at all -- e.g. `command("status", (), ...)` -- so the
    # root state is trivially already done. `usage.split` yields zero
    # lines for an empty string, so the loop below would otherwise leave
    # `result` neither terminal nor with any transitions: a dead end that
    # can never succeed.
    result.terminal = true
  else:
    let p = SpecParser(spec: spec)
    for line in spec.usage.split(peg"\n!\s"):
      p.explicitOptions.clear()
      p.pendingOptions.setLen(0)
      p.lex.open(line)
      defer: p.lex.close()
      p.tok = p.lex.next()
      let (s, e, _) = p.sequence(false)
      if not p.peek {tkEof}:
        p.tok.error(fmt"Unexpected token {p.tok.literal.escape} ({p.tok.kind})")
      # Only now, with the whole line parsed, is explicitOptions final --
      # patch each [options] atom's matcher to exclude it (see atom's
      # tkAnyOption branch and SpecParser.pendingOptions).
      for matcher in p.pendingOptions:
        matcher.opts = matcher.opts.filterIt(it notin p.explicitOptions)
      result.addShortcut(s)
      e.terminal = true
  result.prepare()
