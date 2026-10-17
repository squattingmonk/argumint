## The Variant grammar, written once. Its fragments are PEG source, shared
## by the usage-string lexer (`lexer.nim`), the runtime option shapes
## (`tokens.nim`) and `parseVariant`, which checks one declared Variant and
## splits it into its bare name and metavar. A leaf module, so all three can
## import it. See `docs/architecture.md` §0.

import std/[options, pegs]

type
  VariantShape* {.pure.} = enum
    ## The grammar a Variant is read against: the lexer knows only shapes,
    ## so `Flag` is `Option` with the metavar forbidden.
    Positional, Option, Flag, Command

const
  ShortChar* = "[a-zA-Z0-9]"
    ## A short option's one character, and each of a `-abc` cluster's.
  ShortName* = "'-' " & ShortChar
  LongName* = "'--' \\w (\\w / ('-' \\w))+"
  AngledName* = "\\w (\\w / ('-' \\w))*"
    ## The name inside `<...>`, for a positional or a metavar.
  Angled* = "'<' " & AngledName & " '>'"
  Upper* = "[A-Z0-9] ([A-Z0-9] / ([_-] [A-Z0-9]))*"
    ## An all-caps positional or metavar (`SRC`, `FILE-2`). The lexer
    ## follows it with `![a-z]`, so `X1a` reads as a command.
  Equals* = "[=:]"
    ## What joins an option to its metavar or value.
  CommandName* = "\\w (\\w / '-')*"

let
  Comma = peg"\s* ',' \s*"
  PositionalFormat = peg("^ {" & Angled & " / " & Upper & "} $")
  OptionFormat = peg("^ {" & ShortName & " / " & LongName & "} (" & Equals &
    " (('<' {" & AngledName & "} '>') / {" & Upper & "}))? $")
  FlagFormat = peg("^ {" & ShortName & " / " & LongName & "} $")
  CommandFormat = peg("^ !(" & Upper & " ![a-z]) {" & CommandName & "} $")

proc splitVariants*(variants: string): seq[string] =
  ## Splits a comma-separated `variants` string, as every Arg constructor
  ## takes it. Doesn't check the parts: `parseVariant` does.
  variants.split(Comma)

proc parseVariant*(variant: string, shape: VariantShape):
    Option[tuple[name, metavar: string]] =
  ## Reads `variant` against `shape`'s grammar: its bare name (`--port` for
  ## `--port=<n>`; a positional or command is its own name) and metavar
  ## (`n`, or `""`), or `none` if it doesn't fit. Callers raise their own
  ## `SpecDefect`, naming what declared it.
  var m: array[2, string]
  let ok =
    case shape
    of VariantShape.Positional: variant.match(PositionalFormat, m)
    of VariantShape.Option: variant.match(OptionFormat, m)
    of VariantShape.Flag: variant.match(FlagFormat, m)
    of VariantShape.Command: variant.match(CommandFormat, m)
  if ok: some((name: m[0], metavar: m[1]))
  else: none(tuple[name, metavar: string])

when isMainModule:
  import std/unittest
  import ./lexer

  type Row = tuple[variant: string, shape: VariantShape, name, metavar: string]
    ## `name == ""` means `parseVariant` rejects it.

  const Rows: seq[Row] = @[
    ("-o", VariantShape.Option, "-o", ""),
    ("-5", VariantShape.Option, "-5", ""),
    ("--opt", VariantShape.Option, "--opt", ""),
    ("--dry_run", VariantShape.Option, "--dry_run", ""),
    ("-o=<x>", VariantShape.Option, "-o", "x"),
    ("--opt:VAR", VariantShape.Option, "--opt", "VAR"),
    ("--opt=<a-b>", VariantShape.Option, "--opt", "a-b"),
    ("-_", VariantShape.Option, "", ""),
    ("-ab", VariantShape.Option, "", ""),
    ("--o", VariantShape.Option, "", ""),
    ("--opt=", VariantShape.Option, "", ""),
    ("-f", VariantShape.Flag, "-f", ""),
    ("--flag", VariantShape.Flag, "--flag", ""),
    ("--flag=<x>", VariantShape.Flag, "", ""),
    ("-_", VariantShape.Flag, "", ""),
    ("<src>", VariantShape.Positional, "<src>", ""),
    ("<a-b>", VariantShape.Positional, "<a-b>", ""),
    ("SRC", VariantShape.Positional, "SRC", ""),
    ("SRC-2", VariantShape.Positional, "SRC-2", ""),
    ("src", VariantShape.Positional, "", ""),
    ("<src", VariantShape.Positional, "", ""),
    ("ship", VariantShape.Command, "ship", ""),
    ("a_b", VariantShape.Command, "a_b", ""),
    ("build-all", VariantShape.Command, "build-all", ""),
    ("x1", VariantShape.Command, "x1", ""),
    ("X1a", VariantShape.Command, "X1a", ""),
    ("BUILD", VariantShape.Command, "", ""),
    ("BUILD-x", VariantShape.Command, "", ""),
    ("-x", VariantShape.Command, "", ""),
    ("--", VariantShape.Command, "", ""),
    ("-", VariantShape.Command, "", ""),
    ("bad name", VariantShape.Command, "", ""),
  ]

  proc lexed(variant: string): seq[tuple[kind: SpecTokenKind, text: string]] =
    displayTokens(variant)

  suite "parseVariant":
    for row in Rows:
      test row.variant & " as " & $row.shape:
        let got = parseVariant(row.variant, row.shape)
        if row.name.len == 0:
          check got.isNone
        else:
          check got == some((name: row.name, metavar: row.metavar))

    test "splitVariants trims around each comma":
      check splitVariants("-v , --verbose,-V") == @["-v", "--verbose", "-V"]

  suite "the lexer reads each accepted Variant as its shape's tokens":
    for row in Rows:
      if row.name.len == 0: continue
      test row.variant:
        let tokens = lexed(row.variant)
        case row.shape
        of VariantShape.Positional:
          check tokens == @[(tkArgument, row.variant)]
        of VariantShape.Command:
          check tokens == @[(tkCommand, row.variant)]
        of VariantShape.Option, VariantShape.Flag:
          let nameKind = if row.name.len == 2: tkShortOption else: tkLongOption
          check tokens[0] == (nameKind, row.name)
          if row.metavar.len > 0:
            check tokens.len == 2
            check tokens[1].kind == tkOptionValue
          else:
            check tokens.len == 1

  suite "the lexer doesn't read a rejected Variant as its shape's tokens":
    for row in Rows:
      if row.name.len > 0 or row.shape == VariantShape.Flag: continue
      test row.variant & " as " & $row.shape:
        let tokens = lexed(row.variant)
        case row.shape
        of VariantShape.Positional:
          check tokens != @[(tkArgument, row.variant)]
        of VariantShape.Command:
          check tokens != @[(tkCommand, row.variant)]
        else:
          check tokens.len != 1 or
            tokens[0].kind notin {tkShortOption, tkLongOption}
