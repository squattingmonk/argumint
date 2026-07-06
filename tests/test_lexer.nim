import std/unittest

import argumint/lexer

proc tokenize(spec: string): seq[SpecTokenKind] =
  var lex: SpecLexer
  lex.open(spec)
  defer: lex.close()
  while true:
    let tok = lex.next()
    result.add tok.kind
    if tok.kind == tkEof:
      break

proc literals(spec: string): seq[string] =
  var lex: SpecLexer
  lex.open(spec)
  defer: lex.close()
  while true:
    let tok = lex.next()
    if tok.kind == tkEof:
      break
    result.add tok.literal

suite "SpecLexer":
  test "positional argument":
    check tokenize("<src>") == @[tkArgument, tkEof]
    check literals("<src>") == @["<src>"]

  test "uppercase positional argument":
    check tokenize("SRC-2") == @[tkArgument, tkEof]
    check literals("SRC-2") == @["SRC-2"]

  test "lowercase word is a command, not an argument":
    check tokenize("move") == @[tkCommand, tkEof]

  test "short and long options":
    check tokenize("-r --recursive") == @[tkShortOption, tkLongOption, tkEof]

  test "clustered short options":
    check tokenize("-abc") == @[tkShortOptions, tkEof]

  test "[options] keyword":
    check tokenize("[options]") == @[tkAnyOption, tkEof]

  test "option with a value placeholder":
    check tokenize("--speed=<speed>") == @[tkLongOption, tkOptionValue, tkEof]

  test "brackets, parens, choice, and repeat":
    check tokenize("[-r] (a | b) <src>...") == @[
      tkBracketOpen, tkShortOption, tkBracketClose,
      tkParensOpen, tkCommand, tkChoice, tkCommand, tkParensClose,
      tkArgument, tkRepeat, tkEof
    ]

  test "raises SpecDefect on an unexpected character":
    var lex: SpecLexer
    lex.open("$bad")
    defer: lex.close()
    expect SpecDefect:
      discard lex.next()
