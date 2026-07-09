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

  test "a negative number without the leading space is read as an unrecognized option":
    let spec = (count: arg("<count>", default = 0, help = ""))
    expect ParseError:
      spec.parse(usage = "<count>", args = @["-1"], command = "prog")
