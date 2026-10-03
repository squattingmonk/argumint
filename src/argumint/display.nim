## How a value the user typed, or one the developer declared, appears in
## help and error messages: a string or char always double-quoted, anything
## else as its `$`. Shared by validators (choices, ranges) and arg types
## (defaults, conversion failures). Withheld from the `argumint` facade.

import std/strutils

proc quoted*(s: string): string =
  ## `s` in double quotes, escaping only `"`, `\` and control characters --
  ## unlike `strutils.escape`, which also escapes UTF-8 bytes as `\xHH`.
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\t': result.add "\\t"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\0'..'\x08', '\x0b', '\x0c', '\x0e'..'\x1f', '\x7f':
      result.add "\\x" & toHex(ord(c), 2)
    else: result.add c
  result.add '"'

proc showValue*[T](value: T): string =
  ## `value` as help and errors show it: a string or char always quoted
  ## (see `quoted`), so it never reads as part of the list around it.
  when T is string or T is char: quoted($value) else: $value

when isMainModule:
  import std/unittest

  suite "quoted":
    test "escapes only quotes, backslashes and control characters":
      check quoted("plain") == "\"plain\""
      check quoted("") == "\"\""
      check quoted("say \"hi\"") == "\"say \\\"hi\\\"\""
      check quoted("a\\b") == "\"a\\\\b\""
      check quoted("tab\there\n") == "\"tab\\there\\n\""
      check quoted("\x01") == "\"\\x01\""

    test "leaves UTF-8 text readable":
      check quoted("café") == "\"café\""

  suite "showValue":
    test "quotes strings and chars, and leaves anything else bare":
      check showValue("x") == "\"x\""
      check showValue(',') == "\",\""
      check showValue(7) == "7"
      check showValue(1.5) == "1.5"
