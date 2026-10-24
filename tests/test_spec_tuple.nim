# `specTuple`, which builds a Spec Tuple from a comma-free field list and can
# extend a base Spec Tuple with more fields.

import std/[os, osproc, strutils, unittest]

import argumint

proc checkErrors(code: string): string =
  ## What `nim check` says about `code`, which starts on line 2 after
  ## `import argumint`.
  let
    dir = getTempDir() / "argumint_t317_" & $getCurrentProcessId()
    src = dir / "snippet.nim"
  createDir(dir)
  defer: removeDir(dir)
  writeFile(src, "import argumint\n" & code)
  let srcDir = currentSourcePath().parentDir.parentDir / "src"
  execCmdEx(quoteShellCommand([getCurrentCompilerExe(), "check", "--hints:off",
    "--path:" & srcDir, src])).output

suite "specTuple with no base":
  test "it builds the tuple literal its fields describe":
    let built = specTuple:
      verbose: flag("-v, --verbose", help = "Talk more")
      # A comment between fields.
      name: arg("<name>")
    check built is tuple[verbose: FlagArg[bool], name: ValueArg[string]]
    built.parse(args = @["-v", "Ann"], command = "prog")
    check built.verbose.get
    check built.name.get == "Ann"

  test "it has the plain literal's type and parses the same command lines":
    let
      built = specTuple:
        verbose: flag("-v, --verbose")
        names: args("<name>")
      plain = (verbose: flag("-v, --verbose"), names: args("<name>"))
    check typeof(built) is typeof(plain)
    built.parse(args = @["Ann", "-v", "Bo"], command = "prog")
    plain.parse(args = @["Ann", "-v", "Bo"], command = "prog")
    check (built.verbose.get, built.names.get) == (true, @["Ann", "Bo"])
    check (plain.verbose.get, plain.names.get) == (true, @["Ann", "Bo"])

suite "specTuple with a base":
  test "it flattens the base's fields into the new tuple, sharing their Args":
    let
      global = (verbose: flag("-v, --verbose"), help: help())
      convert = specTuple(global):
        branch: opt("--branch=<branch>")
    check convert is tuple[branch: ValueArg[string], verbose: FlagArg[bool],
      help: HelpArg]
    convert.parse(args = @["-v", "--branch=dev"], command = "prog")
    check convert.branch.get == "dev"
    check convert.verbose.get
    check global.verbose.get

  test "a replacement of the same type keeps the base field's slot":
    let
      global = (verbose: flag("-v, --verbose"), help: help(), quiet: flag("-q"))
      config = specTuple(global):
        name: arg("<name>")
        help: help(formatter = formatParagraph)
    check config is tuple[name: ValueArg[string], verbose: FlagArg[bool],
      help: HelpArg, quiet: FlagArg[bool]]
    check config.help.variants == @["-h", "--help"]
    check not (config.help == global.help)

  test "a replacement of another type comes first, with the new fields":
    let
      global = (verbose: flag("-v, --verbose"), level: opt[int]("--level=<n>"))
      config = specTuple(global):
        name: arg("<name>")
        level: opt("--level=<name>")
    check config is tuple[name: ValueArg[string], level: ValueArg[string],
      verbose: FlagArg[bool]]

  test "help lists the new fields' Args and groups before the base's":
    let
      global = (verbose: flag("-v, --verbose", help = "Talk more",
          group = "Global"),
        help: help())
      convert = specTuple(global):
        branch: opt("--branch=<branch>", help = "Branch to use",
          group = "Source")
        force: flag("-f, --force", help = "Overwrite")
    var shown = ""
    try:
      convert.parse(args = @["--help"], command = "prog",
        settings = newSpecSettings(style = nil))
    except HelpError as e: shown = e.msg
    check shown == """
Usage:
  prog [options]
  prog (-h | --help)

Options:
  -f, --force        Overwrite
  -h, --help         Display this help message

Source:
  --branch=<branch>  Branch to use

Global:
  -v, --verbose      Talk more"""

  test "a tuple field of the base stays nested":
    let
      inner = (quiet: flag("-q"))
      global = (verbose: flag("-v"), inner: inner)
      merged = specTuple(global):
        name: arg("<name>")
    check merged is tuple[name: ValueArg[string], verbose: FlagArg[bool],
      inner: tuple[quiet: FlagArg[bool]]]

  test "a merged tuple can be a base itself":
    let
      convert = specTuple:
        verbose: flag("-v")
      compile = specTuple(convert):
        output: opt("-o=<file>")
      pack = specTuple(compile):
        level: opt[int]("-l=<n>")
    check pack is tuple[level: ValueArg[int], output: ValueArg[string],
      verbose: FlagArg[bool]]
    pack.parse(args = @["-v", "-o", "out", "-l", "3"], command = "prog")
    check convert.verbose.get
    check compile.output.get == "out"

  test "it evaluates the base once":
    var calls = 0
    proc makeBase(): auto =
      inc calls
      (verbose: flag("-v"), help: help())
    let merged = specTuple(makeBase()):
      name: arg("<name>")
    check merged is tuple[name: ValueArg[string], verbose: FlagArg[bool],
      help: HelpArg]
    check calls == 1

  test "it works inline as a command's spec, and builds the top-level spec":
    let
      name = arg("<name>")
      global = specTuple:
        verbose: flag("-v")
      spec = specTuple(global):
        test: command("test", specTuple(global) do:
          name: name)
        help: help()
    spec.parse(args = @["test", "-v", "Ann"], command = "prog")
    check name.get == "Ann"
    check global.verbose.get

  test "a plain do block works inline as a command's spec":
    let
      name = arg("<name>")
      spec = (test: command("test", specTuple do:
        name: name))
    spec.parse(args = @["test", "Ann"], command = "prog")
    check name.get == "Ann"

suite "specTuple compile errors":
  test "a base that isn't a tuple":
    check "snippet.nim(3, 25) Error: specTuple: the base must be a tuple with named fields" in
      checkErrors("""
type Global = object
let a = specTuple(Global()):
  name: arg("<name>")
""")

  test "a body line that isn't `name: expr`":
    check "snippet.nim(4, 3) Error: specTuple: each line must be `name: expr`" in
      checkErrors("""
let a = specTuple:
  name: arg("<name>")
  arg("<other>")
""")

  test "the same field named twice":
    check "snippet.nim(4, 3) Error: specTuple: field `name` is named twice" in
      checkErrors("""
let a = specTuple:
  name: arg("<name>")
  name: arg("<other>")
""")

  test "more than one argument before the body":
    check "snippet.nim(3, 22) Error: specTuple: expected at most one base before the body" in
      checkErrors("""
let g = (verbose: flag("-v"))
let a = specTuple(g, g):
  name: arg("<name>")
""")

  test "an error in a field's expression points at that field":
    check "snippet.nim(4, 13) Error: type mismatch" in checkErrors("""
let a = specTuple:
  name: arg("<name>")
  count: arg(1, 2, 3, 4, 5, 6, 7, 8, 9)
""")
