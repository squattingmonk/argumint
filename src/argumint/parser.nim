## This module parses tokens from the spec lexer and constructs an FSM that will
## support matching of command-line arguments and high-level validation of usage
## patterns.

import std/[pegs, sequtils, strformat, strutils, tables]

import ./[backend, lexer]
export lexer.SpecDefect

type
  SpecParser = ref object
    lex: SpecLexer ## Tokenizer
    tok: SpecToken ## Lookahead token
    spec: Spec

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

proc atom(p: SpecParser): tuple[a: State, b: State]

proc choice(p: SpecParser): tuple[a: State, b: State] =
  ## Constructs a choice (e.g., `this | that`). Note `this` is still a choice.
  var children = newSeq[tuple[a: State, b: State]]()
  children.add p.atom
  while p.peek {tkChoice}:
    p.next()
    children.add p.atom()

  if children.len == 1:
    return children[0]

  var
    a = newState()
    b = newState()

  for child in children:
    a.addShortcut(child.a)
    child.b.addShortcut(b)

  return (a, b)

proc sequence(p: SpecParser, required = true): tuple[a: State, b: State] =
  ## Constructs a new sequence (e.g., `this that`). If `required` is `true`, the
  ## sequence must have child nodes.
  var
    a = newState()
    b = a

  proc add(x, y: State) =
    # Add all transitions in x to b, then set b to y.
    for tr in x.transitions:
      b.add(tr.next, tr.matcher)
    b = y

  if required:
    let (s, e) = p.choice() # s == a == b
    add(s, e) # s == a, e == b

  while p.peek CanAtom:
    let (s, e) = p.choice()
    add(s, e)
  return (a, b)

proc atom(p: SpecParser): tuple[a: State, b: State] =
  ## Generates a partial FSM for the next token if it represents or begins an
  ## atom. Returns a beginning and ending state for the atom.
  result.a = newState()
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
    result.b = result.a.add(newOptsMatcher(p.spec.options.values.toSeq.deduplicate().filterIt(not (it of MessageArg))))
    result.a.addShortcut(result.b) # Make it optional
  of tkCommand:
    if token.literal notin p.spec.commands:
      token.error(fmt"Undeclared command: {token.literal}")
    let cmd = p.spec.commands[token.literal]
    result.b = newState()
    for s in cmd.spec.fsm.terminals:
      s.addShortcut(result.b)
    result.a.add(cmd.spec.fsm, newCmdMatcher(cmd))
  of tkParensOpen:
    result = p.sequence()
    discard p.eat {tkParensClose}
  of tkBracketOpen:
    result = p.sequence()
    result.a.addShortcut(result.b)
    discard p.eat {tkBracketClose}
  else:
    assert false

  if p.peek {tkRepeat}:
    result.b.addShortcut(result.a)
    p.next()

proc genFsm*(spec: Spec): State =
  ## Generates an FSM for `spec` based on its usage strings.
  result = newState()
  let p = SpecParser(spec: spec)
  for line in spec.usage.split(peg"\n!\s"):
    p.lex.open(line)
    defer: p.lex.close()
    p.tok = p.lex.next()
    let (s, e) = p.sequence(false)
    if not p.peek {tkEof}:
      p.tok.error(fmt"Unexpected token {p.tok.literal.escape} ({p.tok.kind})")
    result.addShortcut(s)
    e.terminal = true
  result.prepare()
