import std/unittest

import argumint

suite "Option value separators":
  test "-o=value and --output=value":
    let spec1 = (output: opt("-o, --output=<value>", default = "", help = ""))
    spec1.parse(args = @["-o=foo"], command = "prog")
    check spec1.output == "foo"

    let spec2 = (output: opt("-o, --output=<value>", default = "", help = ""))
    spec2.parse(args = @["--output=foo"], command = "prog")
    check spec2.output == "foo"

  test "-o:value and --output:value":
    let spec1 = (output: opt("-o, --output=<value>", default = "", help = ""))
    spec1.parse(args = @["-o:foo"], command = "prog")
    check spec1.output == "foo"

    let spec2 = (output: opt("-o, --output=<value>", default = "", help = ""))
    spec2.parse(args = @["--output:foo"], command = "prog")
    check spec2.output == "foo"

suite "Space-separated option values":
  test "-o value and --output value":
    let spec1 = (output: opt("-o, --output=<value>", default = "", help = ""))
    spec1.parse(args = @["-o", "foo"], command = "prog")
    check spec1.output == "foo"

    let spec2 = (output: opt("-o, --output=<value>", default = "", help = ""))
    spec2.parse(args = @["--output", "foo"], command = "prog")
    check spec2.output == "foo"

  test "raise ParseError when the trailing value is missing":
    let spec = (output: opt("-o, --output=<value>", default = "", help = ""))
    expect ParseError:
      spec.parse(args = @["-o"], command = "prog")

suite "Short option value concatenation":
  test "-ofoo sets the value with no separator":
    let spec = (output: opt("-o, --output=<value>", default = "", help = ""))
    spec.parse(args = @["-ofoo"], command = "prog")
    check spec.output == "foo"

suite "Short flag clustering":
  test "-abc sets all three flags":
    let spec = (
      a: flag("-a", default = false, help = ""),
      b: flag("-b", default = false, help = ""),
      c: flag("-c", default = false, help = ""),
    )
    spec.parse(args = @["-abc"], command = "prog")
    check spec.a == true
    check spec.b == true
    check spec.c == true

  test "clustering doesn't depend on declaration order":
    let spec = (
      a: flag("-a", default = false, help = ""),
      b: flag("-b", default = false, help = ""),
      c: flag("-c", default = false, help = ""),
    )
    spec.parse(args = @["-cab"], command = "prog")
    check spec.a == true
    check spec.b == true
    check spec.c == true

suite "Folding a value option at the end of a cluster":
  test "-abo=value is equivalent to -a -b -o value":
    let spec = (
      a: flag("-a", default = false, help = ""),
      b: flag("-b", default = false, help = ""),
      o: opt("-o=<value>", default = "", help = ""),
    )
    spec.parse(args = @["-abo=value"], command = "prog")
    check spec.a == true
    check spec.b == true
    check spec.o == "value"

  test "-abo value is equivalent to -a -b -o value":
    let spec = (
      a: flag("-a", default = false, help = ""),
      b: flag("-b", default = false, help = ""),
      o: opt("-o=<value>", default = "", help = ""),
    )
    spec.parse(args = @["-abo", "value"], command = "prog")
    check spec.a == true
    check spec.b == true
    check spec.o == "value"

  test "-abovalue is equivalent to -a -b -o value":
    let spec = (
      a: flag("-a", default = false, help = ""),
      b: flag("-b", default = false, help = ""),
      o: opt("-o=<value>", default = "", help = ""),
    )
    spec.parse(args = @["-abovalue"], command = "prog")
    check spec.a == true
    check spec.b == true
    check spec.o == "value"

  test "a value option in the middle of a cluster consumes the rest as its value":
    let spec = (
      a: flag("-a", default = false, help = ""),
      o: opt("-o=<value>", default = "", help = ""),
      b: flag("-b", default = false, help = ""),
    )
    spec.parse(args = @["-aob"], command = "prog")
    check spec.a == true
    check spec.o == "b"
    check spec.b == false

suite "-- end of options":
  test "arguments after -- are positional even if they look like options":
    let spec = (
      verbose: flag("--verbose", help = ""),
      files: args[string]("<file>", help = ""),
    )
    spec.parse(usage = "[--verbose] [<file>...]", args = @["--verbose", "--", "-x", "--verbose", "file.txt"], command = "prog")
    check spec.verbose == true
    check spec.files == @["-x", "--verbose", "file.txt"]

suite "Negative number literals":
  test "a leading space disambiguates a negative int from a short option":
    let spec = (count: arg("<count>", default = 0, help = ""))
    spec.parse(usage = "<count>", args = @[" -1"], command = "prog")
    check spec.count == -1

  test "a leading space disambiguates a negative float from a short option":
    let spec = (amount: arg("<amount>", default = 0.0, help = ""))
    spec.parse(usage = "<amount>", args = @[" -3.14"], command = "prog")
    check spec.amount == -3.14

  test "a negative number without the leading space is accepted when no option could compete for it":
    # Previously required the leading-space escape unconditionally; fixed
    # by ADR 0019 -- a bare `<count>` Usage Line has no Option transition
    # to lose to, so Argument gets first (and only) crack at "-1".
    let spec = (count: arg("<count>", default = 0, help = ""))
    spec.parse(usage = "<count>", args = @["-1"], command = "prog")
    check spec.count == -1

suite "A Command name doesn't shadow a positional value in another alternative":
  test "a bare command name falls back to a positional value when the command's own args aren't satisfied":
    # ADR 0019: "ship" is a declared command name, but the "ship <name>"
    # alternative fails here (no <name> left to consume), so backtracking
    # should fall through to the "<file>" alternative and accept "ship" as
    # a literal positional value instead of raising.
    let spec = (
      ship: command("ship", (name: arg("<name>", help = "")), usage = "<name>", help = ""),
      file: arg("<file>", default = "", help = ""),
    )
    # A Command atom is self-contained -- it splices in its own nested
    # spec's usage (declared via command()'s own `usage` param) and
    # consumes every remaining token itself, so the outer line just names
    # it bare ("ship"), not "ship <name>". Top-level `|` also only
    # alternates at the atom position where it appears (`ship (a|b)`, not
    # `(ship a)|b`), so two genuinely separate whole-line alternatives
    # need separate Usage Lines instead.
    spec.parse(usage = "ship\n<file>", args = @["ship"], command = "prog")
    check spec.file == "ship"

suite "An option-shaped token unrecognized by one alternative can still match a permissive alternative":
  test "a strict alternative's unrecognized option falls through to a catch-all positional alternative":
    # ADR 0019: "-x" isn't declared anywhere, but the "--verbose"
    # alternative used to raise on it unconditionally during eager
    # tokenization; it should now just fail to match and let the "<raw>..."
    # alternative accept it as literal text instead.
    let spec = (
      verbose: flag("--verbose", help = ""),
      raw: args[string]("<raw>", help = ""),
    )
    spec.parse(usage = "--verbose|<raw>...", args = @["-x"], command = "prog")
    check spec.raw == @["-x"]
