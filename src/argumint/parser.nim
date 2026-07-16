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
      ## current Usage Line, so `[options]` can exclude them (see `atom`'s
      ## `tkAnyOption` branch) rather than making them separately repeatable.
      ## Recomputed per line by `genFsm`, since `[options]` only excludes
      ## what's explicit on its own Usage Line, not elsewhere in the Usage
      ## String.

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
    result.b = result.a.add(newOptMatcher(p.spec.options[token.literal]))
    if p.peek {tkOptionValue}:
      p.next()
  of tkShortOptions:
    var options = newSeq[Arg]()
    for idx, c in token.literal.substr(1):
      let name = fmt"-{c}"
      if name notin p.spec.options:
        token.error(fmt"Undeclared option in {token.literal}: {name}")
      options.add p.spec.options[name]
    result.b = result.a.add(newOptsMatcher(options))
    if p.peek {tkOptionValue}:
      p.next()
  of tkAnyOption:
    result.b = result.a.add(newOptsMatcher(p.spec.options.values.toSeq.deduplicate()
      .filterIt(not (it of MessageArg) and it notin p.explicitOptions)))
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
    result.b.addShortcut(result.a)
    p.next()

proc collectExplicitOptions(spec: Spec, line: string): HashSet[Arg] =
  ## Scans a single Usage Line for options mentioned by name (`-o`,
  ## `--option`, or a `-abc`-style cluster), as opposed to picked up only via
  ## the `[options]` catch-all. Used so `[options]` can exclude options
  ## that are handled explicitly elsewhere on the *same* Usage Line, rather
  ## than making them independently (and repeatably) matchable through both.
  var lex: SpecLexer
  lex.open(line)
  defer: lex.close()
  while true:
    let tok = lex.next()
    case tok.kind
    of tkEof:
      break
    of tkShortOption, tkLongOption:
      if tok.literal in spec.options:
        result.incl spec.options[tok.literal]
    of tkShortOptions:
      for c in tok.literal.substr(1):
        let name = fmt"-{c}"
        if name in spec.options:
          result.incl spec.options[name]
    else:
      discard

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
      p.explicitOptions = spec.collectExplicitOptions(line)
      p.lex.open(line)
      defer: p.lex.close()
      p.tok = p.lex.next()
      let (s, e, _) = p.sequence(false)
      if not p.peek {tkEof}:
        p.tok.error(fmt"Unexpected token {p.tok.literal.escape} ({p.tok.kind})")
      result.addShortcut(s)
      e.terminal = true
  result.prepare()
