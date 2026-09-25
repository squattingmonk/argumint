# Every exception argumint raises has `styledMsg` filled, `msg` again when
# there's no Styler -- see `docs/adr/0059-plain-help-msg.md`. Help and
# `failure` are pinned in `test_help.nim` and `complaints.nim`.

import std/[options, unittest]

import argumint

template checkPlain(E: typedesc, body: untyped) =
  var caught = false
  try: body
  except E as e:
    caught = true
    check e.styledMsg == e.msg
    check e.msg.len > 0
  check caught

suite "without a Styler, styledMsg is msg":
  let plain = newSpecSettings(style = nil)

  test "a message() or version()":
    checkPlain(MessageError):
      (v: version("--version", "1.0")).parse(settings = plain, args = @["--version"], command = "prog")

  test "a completion request":
    checkPlain(CompletionError):
      (v: flag("--verbose", help = "")).parse(settings = plain,
        args = @["__complete", "--"], command = "prog")

  test "a parse failure":
    checkPlain(ParseError):
      (v: flag("--verbose", help = "")).parse(settings = plain,
        args = @["--nope"], command = "prog")

  test "a validation failure":
    checkPlain(ValidationError):
      (n: opt("--num=<n>", default = 1, validator = range(1..3), help = "")).parse(
        settings = plain, args = @["--num=9"], command = "prog")

suite "the write side and validators fill styledMsg too":
  test "put":
    let n = opt("--num=<n>", default = 1, validator = range(1..3), help = "")
    checkPlain(ValidationError): n.put(9, seenBy = some(byCli))

  test "replace":
    let tags = opts("--tag=<t>", default = @["a"], validator = choice(["a", "b"]), help = "")
    checkPlain(ValidationError): tags.replace(@["z"], seenBy = some(byCli))

  test "parse":
    let n = opt("--num=<n>", default = 1, help = "")
    checkPlain(ParseError): n.parse("x", seenBy = some(byCli))

  test "a flag's unknown variant":
    let v = flag("--verbose", help = "")
    checkPlain(ParseError): v.parse("--nope", seenBy = some(byCli))

  test "a validator called directly":
    checkPlain(ValidationError): range(1..3).validate(9)
