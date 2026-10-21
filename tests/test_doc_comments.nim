## Lints the `##` doc comments in every Nim source file of the project, so the
## two layout rules in `CODING_STANDARDS.md` that a reviewer shouldn't have to
## check by eye fail the suite instead:
##
## - A doc comment line ends at or before column 80.
## - An object field's doc comment goes on its own line(s) below the field,
##   never after the field on the same line, however short.
##
## Each violation is reported as `file:line`.

import std/[os, strutils, unicode, unittest]

const
  Root = currentSourcePath().parentDir.parentDir
  Dirs = ["src", "tests", "tools", "examples"]
  MaxWidth = 80

proc sources(): seq[string] =
  for dir in Dirs:
    for file in walkDirRec(Root / dir):
      if file.endsWith(".nim"):
        result.add file

proc relative(file: string): string =
  file.relativePath(Root).replace('\\', '/')

proc isFieldName(text: string): bool =
  ## Whether `text` is the name part of a field declaration: one or more
  ## identifiers, each optionally exported, separated by commas.
  let names = text.split(',')
  for name in names:
    let name = name.strip
    let ident = if name.endsWith('*'): name[0 ..< ^1] else: name
    if ident.len == 0 or ident[0] notin IdentStartChars:
      return false
    for c in ident:
      if c notin IdentChars:
        return false
  true

proc trailingFieldDoc(line: string): bool =
  ## Whether `line` declares a field and puts a doc comment after it.
  let doc = line.find("##")
  if doc < 0:
    return false
  let code = line[0 ..< doc]
  let colon = code.find(':')
  colon > 0 and code[colon + 1 .. ^1].strip.len > 0 and
    code[0 ..< colon].isFieldName

proc indentOf(line: string): int =
  line.len - line.strip(trailing = false).len

proc longLines(file: string): seq[string] =
  let lines = file.readFile.splitLines
  for i, line in lines:
    if line.strip.startsWith("##") and line.runeLen > MaxWidth:
      result.add file.relative & ":" & $(i + 1) & " is " & $line.runeLen &
        " columns"

proc sameLineFieldDocs(file: string): seq[string] =
  var typeIndent = -1
    ## Indent of the open `type` keyword, or -1 outside a type section
  let lines = file.readFile.splitLines
  for i, line in lines:
    let text = line.strip
    if text.len == 0 or text.startsWith('#'):
      continue
    if typeIndent >= 0 and line.indentOf <= typeIndent:
      typeIndent = -1
    if text == "type" or text.startsWith("type "):
      typeIndent = line.indentOf
    elif typeIndent >= 0 and line.trailingFieldDoc:
      result.add file.relative & ":" & $(i + 1)

suite "doc comments":
  test "isFieldName accepts field names only":
    check "name".isFieldName
    check "name*".isFieldName
    check "line, column*".isFieldName
    check not "".isFieldName
    check not "tkFoo = \"a".isFieldName
    check not "proc foo(x".isFieldName

  test "trailingFieldDoc spots a doc after a field":
    check "  kind*: SpecTokenKind ## The kind".trailingFieldDoc
    check "  a, b: int ## Two".trailingFieldDoc
    check not "  kind*: SpecTokenKind".trailingFieldDoc
    check not "    ## The kind".trailingFieldDoc
    check not "  tkFoo = \"a: b\" ## Enum value".trailingFieldDoc

  test "no doc comment line runs past column 80":
    var found: seq[string]
    for file in sources():
      found.add file.longLines
    for f in found:
      checkpoint f
    check found.len == 0

  test "no field doc comment shares the field's line":
    # Move each one onto its own line below the field, indented two more.
    var found: seq[string]
    for file in sources():
      found.add file.sameLineFieldDocs
    for f in found:
      checkpoint f
    check found.len == 0
