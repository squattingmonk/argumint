## Usage Lines: splitting a Usage String into them, for both the parser and
## help, and laying them out for help and parse errors. Takes plain strings,
## so it needs no Spec.

import std/strutils

import ./[console, lexer, style]

const Margin* = "  "
  ## The left margin of a usage line, and of a help row.

proc splitUsage*(usage: string): seq[string] =
  ## `usage`'s Usage Lines. A blank line is dropped, and an indented line
  ## continues the line before it.
  for line in usage.splitLines:
    if line.isEmptyOrWhitespace:
      continue
    if result.len > 0 and line[0] in Whitespace:
      result[^1] = result[^1] & " " & line.strip
    else:
      result.add line.strip

proc styledUsage(line: string): StyledText =
  ## One usage line's tokens with their roles: options (and `[options]`)
  ## `srOption`, commands `srCommand`, arguments `srPositional`, a value
  ## placeholder's `<x>` `srMetavar`, and punctuation `srPlain`.
  for (kind, text) in line.displayTokens:
    case kind
    of tkShortOption, tkShortOptions, tkLongOption, tkAnyOption:
      result.add styled(srOption, text)
    of tkOptsEnd:
      if text.startsWith('['):
        result.add styled("[") & styled(srOption, text[1 .. ^2]) & styled("]")
      else:
        result.add styled(srOption, text)
    of tkCommand:
      result.add styled(srCommand, text)
    of tkArgument:
      result.add styled(srPositional, text)
    of tkOptionValue:
      result.add styled(text[0 .. 0]) & styled(srMetavar, text[1 .. ^1])
    else:
      result.add styled(text)

proc usageLines*(usage: string, command: string, width = DefaultWidth): seq[StyledText] =
  ## Lays out `usage` (a spec's raw usage string, one alternative per line) as
  ## indented usage lines, prefixing each alternative with `command`
  ## (`srProgram`). Lines longer than `width` are wrapped, with continuations
  ## hanging-indented to align under the first token after `command` rather
  ## than restarting at the left margin. A usage with no Usage Lines is one
  ## bare call. Adds no "Usage:" label -- the caller writes its own.
  let
    prefix = styled(Margin) & styled(srProgram, command) & styled(" ")
    indent = styled(' '.repeat(prefix.len))
    lineWidth = max(width, 20)
    lines = usage.splitUsage

  for line in (if lines.len == 0: @[""] else: lines):
    for i, wrapped in (prefix & line.styledUsage).wrap(lineWidth):
      result.add(if i == 0: wrapped else: indent & wrapped)

proc usageBlock*(usage: string, command: string, width: int): seq[StyledText] =
  ## `usageLines` under a `Usage:` heading, as help and parse errors show it.
  @[heading("Usage")] & usage.usageLines(command, width)

when isMainModule:
  import std/unittest

  proc tagged(role: StyleRole, text: string): string =
    ## Marks each styled span as `{role:text}`, leaving plain ones bare.
    if role == srPlain: text
    else: "{" & ($role)[2 .. ^1].toLowerAscii & ":" & text & "}"

  suite "splitUsage":
    test "each unindented line is a Usage Line":
      check splitUsage("<foo> [--bar]") == @["<foo> [--bar]"]
      check splitUsage("<foo>\n--bar") == @["<foo>", "--bar"]

    test "an indented line continues the line before it":
      check splitUsage("<foo>\n  --bar\n<baz>") == @["<foo> --bar", "<baz>"]
      check splitUsage("<foo>\n\t--bar") == @["<foo> --bar"]

    test "a line's surrounding whitespace is dropped":
      check splitUsage("<foo>  ") == @["<foo>"]
      check splitUsage("<foo>\r\n<bar>") == @["<foo>", "<bar>"]

    test "an indented first line is a Usage Line":
      check splitUsage("  <foo>") == @["<foo>"]
      check splitUsage("\n  <foo>") == @["<foo>"]

    test "a usage with no text has no Usage Lines":
      check splitUsage("") == newSeq[string]()
      check splitUsage("  \n\t") == newSeq[string]()

    test "blank lines are dropped, as the parser always has":
      check splitUsage("<foo>\n\n<bar>") == @["<foo>", "<bar>"]
      check splitUsage("\n<foo>") == @["<foo>"]
      check splitUsage("<foo>\n") == @["<foo>"]
      check splitUsage("<foo>\n\n") == @["<foo>"]

    test "a blank line doesn't end a line an indented line continues":
      check splitUsage("<foo>\n\n  <bar>") == @["<foo> <bar>"]
      check splitUsage("<foo>\n  \n  <bar>") == @["<foo> <bar>"]

    test "a whitespace-only line isn't an empty alternative":
      check splitUsage("  \n<foo>") == @["<foo>"]

  suite "usageLines":
    test "no label is added; the caller writes its own":
      check usageLines("<foo>", "prog").render == "  prog <foo>"

    test "a blank usage message is still prefixed with the command name":
      check usageLines("", "prog").render == "  prog"

    test "a single usage line is prefixed with the command name":
      check usageLines("<foo> [--bar]", "prog").render == "  prog <foo> [--bar]"

    test "multiple usage lines are each prefixed by the command name":
      check usageLines("<foo>\n<bar>", "prog").render == "  prog <foo>\n  prog <bar>"

    test "blank lines show nothing, as they parse to nothing":
      check usageLines("\n<foo>", "prog").render == "  prog <foo>"
      check usageLines("<foo>\n", "prog").render == "  prog <foo>"
      check usageLines("<foo>\n\n<bar>", "prog").render == "  prog <foo>\n  prog <bar>"
      check usageLines("<foo>\n\n  <bar>", "prog").render == "  prog <foo> <bar>"

    test "lines beginning with whitespace are joined to the previous usage line":
      check usageLines("<foo>\n  <bar>\n<baz>", "prog").render == "  prog <foo> <bar>\n  prog <baz>"

    test "usage lines are wrapped to width with a hanging indent matching command prefix length":
      let usage = "<foo> [--bar] (--baz | --qux=<qux>)\n<foobar>"
      check usageLines(usage, "prog", width = 40).render == "  prog <foo> [--bar] (--baz |\n       --qux=<qux>)\n  prog <foobar>"

    test "the hanging indent matches the command's visible width, not bytes":
      let usage = "<foo> [--bar] (--baz | --qux=<qux>)"
      check usageLines(usage, "prög", width = 40).render == "  prög <foo> [--bar] (--baz |\n       --qux=<qux>)"

    test "min width for a usage line is 20":
      let usage = "<foo> [--bar] (--baz | --qux=<qux>)\n<foobar>"
      check usageLines(usage, "prog", width = 10).render == "  prog <foo> [--bar]\n       (--baz |\n       --qux=<qux>)\n  prog <foobar>"

    test "words longer than width are split when wrapping":
      let usage = "<foo> [--bar --aVeryLongOptionName]"
      check usageLines(usage, "prog", width = 20).render == "  prog <foo> [--bar\n       --aVeryLongOptionNam\n       e]"

  suite "usageBlock":
    test "the usage lines follow a Usage heading":
      check usageBlock("<foo>\n<bar>", "prog", 80).render ==
        "Usage:\n  prog <foo>\n  prog <bar>"

    test "the heading is srHeader":
      check usageBlock("<foo>", "p", 80).render(tagged) ==
        "{header:Usage:}\n  {program:p} {positional:<foo>}"

  suite "usage roles":
    test "usage lines tag the program, commands, options, arguments and metavars":
      check usageLines("ship <name> move [--speed=<kn>] (-a | -bc) [options] [--] <x>...", "nf")
        .render(tagged) ==
        "  {program:nf} {command:ship} {positional:<name>} {command:move} " &
        "[{option:--speed}={metavar:<kn>}] ({option:-a} | {option:-bc}) " &
        "{option:[options]} [{option:--}] {positional:<x>}..."

    test "all-caps arguments and option values get the same roles":
      check usageLines("ship NAME [--speed=KN]", "p").render(tagged) ==
        "  {program:p} {command:ship} {positional:NAME} " &
        "[{option:--speed}={metavar:KN}]"

    test "an argument after an option in usage is still positional":
      check usageLines("-o <file>", "p").render(tagged) ==
        "  {program:p} {option:-o} {positional:<file>}"

    test "usage lines split across wraps keep their roles":
      check usageLines("--alpha --beta --gamma", "p", width = 20).render(tagged) ==
        "  {program:p} {option:--alpha} {option:--beta}\n    {option:--gamma}"

    test "unrecognized usage text is plain":
      check usageLines("a ~ b", "p").render(tagged) ==
        "  {program:p} {command:a} ~ {command:b}"
