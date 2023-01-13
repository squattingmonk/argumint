import std/[lexbase, streams, strutils]

type
  SpecificationDefect* = object of Defect

  TokenKind* = enum
    ## The kind of tokens in a parser spec
    tkInvalid      ## Invalid token
    tkEof          ## End of spec reached
    tkParensOpen   ## Open parenthesis: `(`
    tkParensClose  ## Close parenthesis: `)`
    tkBracketOpen  ## Open square bracket: `[`
    tkBracketClose ## Close square bracket: `]`
    tkChoice       ## Choice divider: `|`
    tkRepeat       ## Repetion postfix: `...`
    tkArgument     ## An argument: `<src> <dest>`
    tkShortOption  ## Short option: `-o`
    tkShortOptions ## Short option sequence: `-abc`
    tkLongOption   ## Long option: `--option`
    tkOptionValue  ## Short or long option value: `=<value>`
    tkOptionsEnd   ## Double dash signaling end of options: `--`
    tkAnyOption    ## Keyword representing any option: `options`

  Token* = object
    kind*: TokenKind ## The kind of token
    literal*: string ## The literal value of the token

  Lexer* = object of BaseLexer
    a: string
    kind: TokenKind

const
  OptStartChars = Letters + Digits
  OptChars = OptStartChars + {'-', '_'}
  SepChars = {':', '='}
  TokenChars = {'(', ')', '[', ']', '|', '.'}
  EndChars = Whitespace + SepChars + TokenChars + {lexbase.EndOfFile}

proc open*(lex: var Lexer, input: Stream) =
  ## Initializes the parser with an input stream.
  lexbase.open(lex, input)
  lex.kind = tkInvalid
  lex.a = ""

proc close(lex: var Lexer) =
  ## Closes the lexer `lex` and its associated input stream.
  lexbase.close(lex)

proc kind*(lex: Lexer): TokenKind {.inline.} =
  ## Returns the current token type
  lex.kind

proc literal*(lex: Lexer): string {.inline.} =
  ## Returns the character data for the tokens `tkArgument`, `tkShortOption`,
  ## `tkShortOptions`, `tkLongOption`, and `tkOptionValue`.
  if lex.kind in tkArgument..tkOptionValue:
    result = lex.a

proc c(lex: Lexer): char {.inline.} =
  ## Returns the next character in the buffer.
  lex.buf[lex.bufPos]

proc getColumn*(lex: Lexer): int {.inline.} =
  ## Returns the column the lexer has arrived at.
  lexbase.getColNumber(lex, lex.bufPos)

proc getLine*(lex: Lexer): int =
  ## Returns the current line number the lexer has arrived at.
  lex.lineNumber

proc error(lex: Lexer, msg: string) =
  ## Raises a `SpecificationDefect` with a given message showing the location of
  ## the error.
  let
    col = lex.getColumn
    line = lex.getLine
    spec = lex.buf.strip.splitLines[line - 1]
    space = if col > 0: repeat(' ', col - 1) else: ""
  raise newException(SpecificationDefect,
    "Error at ($1:$2): $3\n$4\n$5^" % [$line, $col, msg, spec, space])

proc skip(lex: var Lexer) =
  ## Skips whitespace, handling end-of-line characters and refilling the buffer.
  var pos = lex.bufPos
  while true:
    case lex.buf[pos]
    of ' ', '\t':
      pos.inc
    of '\c':
      pos = lex.handleCR(pos)
    of '\l':
      pos = lex.handleLF(pos)
    else:
      break
  lex.bufPos = pos

proc parseRepeat(lex: var Lexer): TokenKind =
  ## Parses a repeat token (`...`)
  let start = lex.bufPos
  while lex.c == '.':
    lex.a.add('.')
    lex.bufPos.inc
  case lex.a.len
  of 3:
    return tkRepeat
  of 1, 2:
    lex.error("Unexpected end of token; expected '...'")
  else:
    lex.bufPos = start + 4
    lex.error("Unexpected character: .")

proc parseArgument(lex: var Lexer): TokenKind =
  ## Consumes a positional argument (`<arg>`). The literal value is the
  ## characters inside the angle brackets.
  lex.bufPos.inc
  if lex.c in OptStartChars:
    while lex.c in OptChars:
      lex.a.add(lex.c)
      lex.bufPos.inc
  case lex.c
  of '>':
    if lex.a.len == 0:
      lex.error("Unexpected end of arg name")
    if lex.a[^1] notin OptStartChars:
      lex.error("Unexpected end of arg name: " & lex.a[^1])
    lex.bufPos.inc
    return tkArgument
  of EndChars:
    lex.error("Unexpected end of arg name")
  else:
    lex.error("Unexpected character in arg name: " & lex.c)

proc parseOption(lex: var Lexer): TokenKind =
  ## Parses a short option (`-a`), short option sequence (`-abc`), or long
  ## option (`--option`).
  lex.bufPos.inc # Skip first -
  case lex.c
  of OptStartChars:
    while lex.c in OptStartChars:
      lex.a.add(lex.c)
      lex.bufPos.inc
    if lex.c in EndChars:
      result = if lex.a.len > 1: tkShortOptions else: tkShortOption
    else:
      lex.error("Unexpected character in short option sequence: " & lex.c)
  of '-':
    lex.bufPos.inc # Skip next -
    if lex.c in OptStartChars:
      while lex.c in OptChars:
        lex.a.add(lex.c)
        lex.bufPos.inc
    if lex.c in EndChars:
      if lex.a.len == 0:
        result = tkOptionsEnd
      elif lex.a.len == 1 or lex.a[^1] notin OptStartChars:
        lex.error("Unexpected end of long option name: " & lex.a)
      else:
        result = tkLongOption
    else:
      lex.error("Unexpected character in long option name: " & lex.c)
  of EndChars:
    lex.error("Expected short option but got: -")
  else:
    lex.error("Unexpected character in short option name: " & lex.c)

proc parseOptionValue(lex: var Lexer): TokenKind =
  ## Parses an option value (`=<value>` or `:<value>`)
  lex.bufPos.inc # Skip separator character (`:` or `=`)
  let c = lex.c
  if c != '<':
    lex.bufPos.inc
    lex.error("Expected option value but got: " & c)
  try:
    assert lex.parseArgument == tkArgument
  except SpecificationDefect as e:
    e.msg = e.msg.replace("arg name", "option value")
    raise e
  tkOptionValue

proc next*(lex: var Lexer) =
  ## Consumes the next token in the input stream. This controls the parser.
  lex.kind = tkInvalid
  lex.a.setLen(0)
  lex.skip
  case lex.c
  of '(':
    lex.bufPos.inc
    lex.kind = tkParensOpen
  of ')':
    lex.bufPos.inc
    lex.kind = tkParensClose
  of '[':
    if lex.buf[lex.bufPos .. lex.bufPos + 8] == "[options]":
      lex.bufPos.inc(9)
      lex.kind = tkAnyOption
    else:
      lex.bufPos.inc
      lex.kind = tkBracketOpen
  of ']':
    lex.bufPos.inc
    lex.kind = tkBracketClose
  of '|':
    lex.bufPos.inc
    lex.kind = tkChoice
  of '.':
    lex.kind = lex.parseRepeat
  of '<':
    lex.kind = lex.parseArgument
  of '-':
    lex.kind = lex.parseOption
  of SepChars:
    lex.kind = lex.parseOptionValue
  of lexbase.EndOfFile:
    lex.kind = tkEof
  else:
    let c = lex.c
    lex.bufPos.inc
    lex.error("Unexpected character: " & c)

proc getToken*(lex: Lexer): Token =
  ## Returns the token the parser has arrived at.
  Token(kind: lex.kind, literal: lex.literal)

proc getTokens*(s: Stream): seq[Token] =
  ## Tokenizes the input stream `s`.
  var lex: Lexer
  lex.open(s)
  lex.next
  while lex.kind != tkEof:
    result.add(lex.getToken)
    lex.next
  lex.close

proc getTokens*(s: string): seq[Token] =
  ## Tokenizes the input string `s`.
  getTokens(newStringStream(s))


when isMainModule:
  import std/unittest

  template checkErrorMsg(msg: string, body: untyped) =
    ## Runs `body` and checks that any raised exception message contains `msg`.
    expect SpecificationDefect:
      try:
        body
      except:
        check msg in getCurrentExceptionMsg()
        raise

  proc token(kind: TokenKind, literal: string = ""): Token =
    Token(kind: kind, literal: literal)

  suite "Basic token parsing":
    test "Empty spec string yields no tokens":
      check(getTokens("").len == 0)

    test "Letters not part of options or args throw error":
      checkErrorMsg "Unexpected character: f":
        discard getTokens("foo")

    test "Parens, brackets, and choice tokens parsed":
      let expected: seq[Token] = @[
        token(tkParensOpen),
        token(tkParensClose),
        token(tkBracketOpen),
        token(tkBracketClose),
        token(tkChoice)]
      check getTokens("()[]|") == expected

    test "Repeat token parsed":
      let expected: seq[Token] = @[
        token(tkRepeat)]
      check getTokens("...") == expected

      checkErrorMsg "Unexpected character: .":
        discard getTokens("....")

      checkErrorMsg "Unexpected end of token; expected '...'":
        discard getTokens(".")

      checkErrorMsg "Unexpected end of token; expected '...'":
        discard getTokens("..")

    test "Repeat argument":
      let expected: seq[Token] = @[
        token(tkArgument, "name"),
        token(tkRepeat)]
      check getTokens("<name>...") == expected

    test "Repeat long option":
      let expected: seq[Token] = @[
        token(tkLongOption, "name"),
        token(tkRepeat)]
      check getTokens("--name...") == expected

    test "Repeat short option":
      let expected: seq[Token] = @[
        token(tkShortOption, "a"),
        token(tkRepeat)]
      check getTokens("-a...") == expected

    test "Repeat short option sequence":
      let expected: seq[Token] = @[
        token(tkShortOptions, "abc"),
        token(tkRepeat)]
      check getTokens("-abc...") == expected


    test "[options] token parsed":
      let expected: seq[Token] = @[
        token(tkAnyOption)]
      check getTokens("[options]") == expected

  suite "Argument parsing":
    test "Zero-length args throw error":
      checkErrorMsg "Unexpected end of arg name":
        discard getTokens("<>")

    test "Args must be bounded by <>":
      checkErrorMsg "Unexpected end of arg name":
        discard getTokens("<foo")

      checkErrorMsg "Unexpected end of arg name":
        discard getTokens("<foo <bar>")

    test "Args must contain only letters, numbers, hyphens, and underscores":
      let expected: seq[Token] = @[
        token(tkArgument, "foo"),
        token(tkArgument, "1"),
        token(tkArgument, "foo-bar"),
        token(tkArgument, "foo_bar")]
      check getTokens("<foo> <1> <foo-bar> <foo_bar>") == expected

      checkErrorMsg "Unexpected end of arg name":
        discard getTokens("<foo bar>")

      checkErrorMsg "Unexpected character in arg name: ^":
        discard getTokens("<foo^bar>")

    test "Args must start and end with a letter or number":
      checkErrorMsg "Unexpected end of arg name: -":
        discard getTokens("<foo->")

      checkErrorMsg "Unexpected end of arg name: _":
        discard getTokens("<foo_>")

      checkErrorMsg "Unexpected character in arg name: -":
        discard getTokens("<-foo>")

      checkErrorMsg "Unexpected character in arg name: _":
        discard getTokens("<_foo>")

  suite "Options parsing":
    test "Zero-length short options not allowed":
      checkErrorMsg "Expected short option but got: -":
        discard getTokens("-")

    test "Zero-length long option treated as end of options token":
      let tokens = getTokens("--")
      check:
        tokens.len == 1
        tokens[0].kind == tkOptionsEnd

    test "Short options must contain only letters or numbers":
      let expected: seq[Token] = @[
        token(tkShortOption, "a"),
        token(tkShortOption, "1")]
      check getTokens("-a -1") == expected

      checkErrorMsg "Unexpected character in short option name: _":
        discard getTokens("-_")

    test "Short option sequences must contain only letters or numbers":
      check getTokens("-abc123") == @[token(tkShortOptions, "abc123")]

      checkErrorMsg "Unexpected character in short option sequence: _":
        discard getTokens("-ab_")

      checkErrorMsg "Unexpected character in short option sequence: -":
        discard getTokens("-ab-")

    test "Long options must be > 1 characters long":
      checkErrorMsg "Unexpected end of long option name: a":
        discard getTokens("--a")

    test "Long options must contain only letters, numbers, hyphens, and underscores":
      let expected: seq[Token] = @[
        token(tkLongOption, "foo"),
        token(tkLongOption, "42"),
        token(tkLongOption, "foo-bar"),
        token(tkLongOption, "foo_bar")]
      check getTokens("--foo --42 --foo-bar --foo_bar") == expected

      checkErrorMsg "Unexpected character in long option name: ^":
        discard getTokens("--foo^bar")

    test "Long options must start and end with a letter or number":
      checkErrorMsg "Unexpected character in long option name: -":
        discard getTokens("---foo")

      checkErrorMsg "Unexpected character in long option name: _":
        discard getTokens("--_foo")

      checkErrorMsg "Unexpected end of long option name: foo-":
        discard getTokens("--foo-")

      checkErrorMsg "Unexpected end of long option name: foo_":
        discard getTokens("--foo_")

    test "Option values must have a separator character followed by a value in <arg> format":
      let expected: seq[Token] = @[
        token(tkOptionValue, "foo"),
        token(tkOptionValue, "bar")]
      check getTokens("=<foo> :<bar>") == expected

      checkErrorMsg "Expected option value but got: f":
        discard getTokens("=foo")

      checkErrorMsg "Expected option value but got: f":
        discard getTokens(":foo")

      checkErrorMsg "Unexpected end of option value":
        discard getTokens("=<>")

      checkErrorMsg "Unexpected end of option value":
        discard getTokens("=<foo")

      checkErrorMsg "Unexpected end of option value":
        discard getTokens("=<foo <bar>")

    test "Short options, short option sequences, and long options can be followed by values":
      let expected: seq[Token] = @[
        token(tkLongOption, "foo"),
        token(tkOptionValue, "bar"),
        token(tkShortOption, "a"),
        token(tkOptionValue, "1"),
        token(tkShortOptions, "abc"),
        token(tkOptionValue, "foo-bar")]
      check getTokens("--foo=<bar> -a=<1> -abc=<foo-bar>") == expected

    test "Option values must contain only letters, numbers, hyphens, and underscores":
      let expected: seq[Token] = @[
        token(tkOptionValue, "foo"),
        token(tkOptionValue, "1"),
        token(tkOptionValue, "foo-bar"),
        token(tkOptionValue, "foo_bar")]
      check getTokens("=<foo> =<1> =<foo-bar> =<foo_bar>") == expected

      checkErrorMsg "Unexpected end of option value":
        discard getTokens("=<foo bar>")

      checkErrorMsg "Unexpected character in option value: ^":
        discard getTokens("=<foo^bar>")

    test "Option values must start and end with a letter or number":
      checkErrorMsg "Unexpected end of option value: -":
        discard getTokens("=<foo->")

      checkErrorMsg "Unexpected end of option value: _":
        discard getTokens("=<foo_>")

      checkErrorMsg "Unexpected character in option value: -":
        discard getTokens("=<-foo>")

      checkErrorMsg "Unexpected character in option value: _":
        discard getTokens("=<_foo>")

  suite "Naval Fate":
    test "Move ship":
      let expected: seq[Token] = @[
        token(tkArgument, "name"),
        token(tkArgument, "x"),
        token(tkArgument, "y"),
        token(tkBracketOpen),
        token(tkLongOption, "speed"),
        token(tkBracketClose)]
      check getTokens("<name> <x> <y> [--speed]") == expected

    test "Set mine":
      let expected: seq[Token] = @[
        token(tkArgument, "x"),
        token(tkArgument, "y"),
        token(tkBracketOpen),
        token(tkLongOption, "moored"),
        token(tkChoice),
        token(tkLongOption, "drifting"),
        token(tkBracketClose)]
      check getTokens("<x> <y> [--moored | --drifting]") == expected

  #
  #
  #
  #
  #
  #
  # suite "Custom args":
  #   setup:
  #     let spec = newFileStream(stdin)
  #
  #   teardown:
  #     spec.close
  #
  #   test "Custom args parsed":
  #     try:
  #       for token in spec.getTokens:
  #         echo token
  #     except SpecificationDefect as e:
  #       echo e.msg
  #     except:
  #       fail()
  #     check(true)
