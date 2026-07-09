import std/unittest

import argumint
import argumint/fsm

suite "Option value separators":
  test "-o=value and --output=value":
    let spec1 = (output: opt("-o, --output=<value>", default = "", help = ""))
    let s1 = newSpec(spec1)
    s1.parseSpec(@["-o=foo"], "prog")
    check spec1.output == "foo"

    let spec2 = (output: opt("-o, --output=<value>", default = "", help = ""))
    let s2 = newSpec(spec2)
    s2.parseSpec(@["--output=foo"], "prog")
    check spec2.output == "foo"

  test "-o:value and --output:value":
    let spec1 = (output: opt("-o, --output=<value>", default = "", help = ""))
    let s1 = newSpec(spec1)
    s1.parseSpec(@["-o:foo"], "prog")
    check spec1.output == "foo"

    let spec2 = (output: opt("-o, --output=<value>", default = "", help = ""))
    let s2 = newSpec(spec2)
    s2.parseSpec(@["--output:foo"], "prog")
    check spec2.output == "foo"

suite "Space-separated option values":
  test "-o value and --output value":
    let spec1 = (output: opt("-o, --output=<value>", default = "", help = ""))
    let s1 = newSpec(spec1)
    s1.parseSpec(@["-o", "foo"], "prog")
    check spec1.output == "foo"

    let spec2 = (output: opt("-o, --output=<value>", default = "", help = ""))
    let s2 = newSpec(spec2)
    s2.parseSpec(@["--output", "foo"], "prog")
    check spec2.output == "foo"

  test "raise ParseError when the trailing value is missing":
    let spec = (output: opt("-o, --output=<value>", default = "", help = ""))
    let s = newSpec(spec)
    expect ParseError:
      s.parseSpec(@["-o"], "prog")

suite "Short option value concatenation":
  test "-ofoo sets the value with no separator":
    let spec = (output: opt("-o, --output=<value>", default = "", help = ""))
    let s = newSpec(spec)
    s.parseSpec(@["-ofoo"], "prog")
    check spec.output == "foo"

suite "Short flag clustering":
  test "-abc sets all three flags":
    let spec = (
      a: flag("-a", default = false, help = ""),
      b: flag("-b", default = false, help = ""),
      c: flag("-c", default = false, help = ""),
    )
    let s = newSpec(spec)
    s.parseSpec(@["-abc"], "prog")
    check spec.a == true
    check spec.b == true
    check spec.c == true

  test "clustering doesn't depend on declaration order":
    let spec = (
      a: flag("-a", default = false, help = ""),
      b: flag("-b", default = false, help = ""),
      c: flag("-c", default = false, help = ""),
    )
    let s = newSpec(spec)
    s.parseSpec(@["-cab"], "prog")
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
    let s = newSpec(spec)
    s.parseSpec(@["-abo=value"], "prog")
    check spec.a == true
    check spec.b == true
    check spec.o == "value"

  test "-abo value is equivalent to -a -b -o value":
    let spec = (
      a: flag("-a", default = false, help = ""),
      b: flag("-b", default = false, help = ""),
      o: opt("-o=<value>", default = "", help = ""),
    )
    let s = newSpec(spec)
    s.parseSpec(@["-abo", "value"], "prog")
    check spec.a == true
    check spec.b == true
    check spec.o == "value"

  test "-abovalue is equivalent to -a -b -o value":
    let spec = (
      a: flag("-a", default = false, help = ""),
      b: flag("-b", default = false, help = ""),
      o: opt("-o=<value>", default = "", help = ""),
    )
    let s = newSpec(spec)
    s.parseSpec(@["-abovalue"], "prog")
    check spec.a == true
    check spec.b == true
    check spec.o == "value"

  test "a value option in the middle of a cluster consumes the rest as its value":
    let spec = (
      a: flag("-a", default = false, help = ""),
      o: opt("-o=<value>", default = "", help = ""),
      b: flag("-b", default = false, help = ""),
    )
    let s = newSpec(spec)
    s.parseSpec(@["-aob"], "prog")
    check spec.a == true
    check spec.o == "b"
    check spec.b == false

suite "-- end of options":
  test "arguments after -- are positional even if they look like options":
    let spec = (
      verbose: flag("--verbose", help = ""),
      files: args[string]("<file>", help = ""),
    )
    let s = newSpec(spec, usage = "[--verbose] [<file>...]")
    s.parseSpec(@["--verbose", "--", "-x", "--verbose", "file.txt"], "prog")
    check spec.verbose == true
    check spec.files == @["-x", "--verbose", "file.txt"]

suite "Negative number literals":
  test "a leading space disambiguates a negative int from a short option":
    let spec = (count: arg("<count>", default = 0, help = ""))
    let s = newSpec(spec, usage = "<count>")
    s.parseSpec(@[" -1"], "prog")
    check spec.count == -1

  test "a leading space disambiguates a negative float from a short option":
    let spec = (amount: arg("<amount>", default = 0.0, help = ""))
    let s = newSpec(spec, usage = "<amount>")
    s.parseSpec(@[" -3.14"], "prog")
    check spec.amount == -3.14

  test "a negative number without the leading space is read as an unrecognized option":
    let spec = (count: arg("<count>", default = 0, help = ""))
    let s = newSpec(spec, usage = "<count>")
    expect ParseError:
      s.parseSpec(@["-1"], "prog")
