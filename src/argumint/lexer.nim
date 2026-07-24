## This module tokenizes a spec string so it can be parsed into an FSM that can
## be navigated by command-line arguments.
import std/[lexbase, pegs, streams, strformat, strutils]

type
  SpecDefect* = object of Defect

  SpecTokenKind* = enum
    ## The kind of tokens in a parser spec
    tkInvalid
    tkEof = "[EOF]"
    tkParensOpen = "("
    tkParensClose = ")"
    tkBracketOpen = "["
    tkBracketClose = "]"
    tkChoice = "|"
    tkRepeat = "..."
    tkCommand = "command (e.g., command)"
    tkArgument = "argument (e.g., <arg> or ARG)"
    tkShortOption = "short option (e.g., -o)"
    tkShortOptions = "short options (e.g., -abc)"
    tkLongOption = "long option (e.g., --option)"
    tkAnyOption = "[options] keyword"
    tkOptionValue = "option value (e.g., =<val>)"
    tkOptsEnd = "end-of-options marker (e.g., --)"

  SpecToken* = object
    kind*: SpecTokenKind ## The kind of token
    line: int            ## The line of the spec the token was found on
    column: int          ## The column of the spec the token was found at
    literal*: string     ## The literal value of the token
    context: string      ## A string showing the context of the token for errors

  SpecLexer* = object of BaseLexer

let
  patterns: seq[tuple[kind: SpecTokenKind, pattern: Peg]] = @[
    (tkAnyOption, peg"{'[options]'}"),
    (tkShortOptions, peg"{'-' [a-zA-Z0-9][a-zA-Z0-9]+}"),
    (tkShortOption, peg"{'-' [a-zA-Z0-9]}"),
    (tkLongOption, peg"{'--' \w (\w / ('-' \w))+}"),
    (tkOptsEnd, peg"{'[' \s* '--' \s* ']'}"),
    (tkOptsEnd, peg"{'--'} !(\w / '-')"),
    (tkArgument, peg"{'<' \w (\w / ('-' \w))* '>'}"),
    (tkArgument, peg"{[A-Z0-9] ([A-Z0-9] / ([_-] [A-Z0-9]))*} ![a-z]"),
    (tkCommand, peg"{(\w / '-')+}"),
    (tkOptionValue, peg"{[=:] '<' \w (\w / ('-' \w))* '>'}"),
    (tkOptionValue, peg"{[=:] [A-Z0-9] ([A-Z0-9] / ([_-] [A-Z0-9]))*} ![a-z]"),
    (tkParensOpen, peg"{\(}"),
    (tkParensClose, peg"{\)}"),
    (tkBracketOpen, peg"{\[}"),
    (tkBracketClose, peg"{\]}"),
    (tkChoice, peg"{\|}"),
    (tkRepeat, peg"{'...'}")
  ]

proc open*(lex: var SpecLexer, spec: string) =
  ## Opens the string `spec` in the lexer.
  lexbase.open(lex, newStringStream(spec.strip))

proc close*(lex: var SpecLexer) =
  ## Closes the lexer's associated spec stream.
  lexbase.close(lex)

proc getColumn*(lex: SpecLexer): int {.inline.} =
  ## Returns the column the lexer has arrived at.
  lexbase.getColNumber(lex, lex.bufPos)

proc getLine*(lex: SpecLexer): int {.inline.} =
  ## Returns the current column the lexer has arrived at.
  lex.lineNumber

proc error*(lex: SpecLexer, msg: string) =
  ## Raises a `SpecDefect` with a given message showing the location of
  ## the error.
  let
    col = lex.getColumn
    line = lex.getLine
    spec = lex.getCurrentLine().strip
  raise newException(SpecDefect, "Error at ({line}:{col}): {msg}\n{spec}".fmt)

proc error*(tok: SpecToken, msg: string) =
  ## Raises a `SpecDefect` with a given message showing the location of `tok`.
  raise newException(SpecDefect, "Error at ({tok.line}:{tok.column}): {msg}\n{tok.context}".fmt)

proc skip(lex: var SpecLexer) =
  ## Skips whitespace, handling end-of-line characters and refilling the buffer.
  var pos = lex.bufPos
  while true:
    case lex.buf[pos]
    of ' ', '\t': pos.inc
    of '\c': pos = lex.handleCR(pos)
    of '\l': pos = lex.handleLF(pos)
    else: break
  lex.bufPos = pos

proc token(lex: SpecLexer, kind: SpecTokenKind, literal: string = ""): SpecToken =
  ## Returns a token of the given `kind` and a value of `literal`.
  SpecToken(kind: kind, literal: literal, line: lex.getLine(), column: lex.getColumn(), context: lex.getCurrentLine().strip)

proc next*(lex: var SpecLexer): SpecToken =
  ## Advances to and returns the next token. Any whitespace is skipped.
  skip(lex)
  if lex.buf[lex.bufPos] == lexbase.EndOfFile:
    return lex.token(tkEof)
  var matches: array[1, string]
  for (kind, pattern) in patterns:
    if lex.buf.match(pattern, matches, lex.bufPos):
      result = lex.token(kind, matches[0])
      lex.bufPos.inc matches[0].len
      return

  lex.error(fmt"Unexpected character: {escape($lex.buf[lex.bufPos])}")

