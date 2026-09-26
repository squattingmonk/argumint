## Usage Lines: splitting a Usage String into them, for both the parser and
## help. Takes plain strings, so it needs no Spec.

import std/strutils

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

when isMainModule:
  import std/unittest

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
