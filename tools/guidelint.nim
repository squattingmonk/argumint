## Lints the user guide's Markdown for `nimble docscheck`, catching what
## `nim md2html` renders differently from GitHub before it reaches the
## published pages. Outside fenced code blocks, a line in `docs/guide/*.md`
## may not have:
##
## - a code span that starts or ends with a space, which md2html runs on to a
##   later backtick
## - a reference-style link (`[text][ref]` or a `[ref]: url` definition),
##   which md2html shows literally
## - inline HTML, which md2html shows as text
## - a code span inside bold, whose backticks md2html shows literally
## - `\|` in a table row, whose backslash md2html keeps
## - a heading with `:`, `-` or `'`, which md2html slugs into anchors that
##   don't match GitHub's
##
## Every violation is named by page and line.

import std/[algorithm, os, strutils]

const
  Root = currentSourcePath().parentDir.parentDir
  GuideDir = "docs" / "guide"

type Span = tuple[first, last: int]
  ## Byte range of one code span in a line, backticks included

proc codeSpans(line: string): seq[Span] =
  ## Every code span in `line`: a run of backticks closed by the next run of
  ## the same length. An unclosed run isn't a span.
  var i = 0
  while i < line.len:
    if line[i] != '`':
      inc i
      continue
    var n = 0
    while i + n < line.len and line[i + n] == '`':
      inc n
    var j = i + n
    var closed = -1
    while j < line.len:
      if line[j] == '`':
        var m = 0
        while j + m < line.len and line[j + m] == '`':
          inc m
        if m == n:
          closed = j + m - 1
          break
        j += m
      else:
        inc j
    if closed < 0:
      i += n
    else:
      result.add (i, closed)
      i = closed + 1

proc outsideSpans(line: string, spans: seq[Span]): string =
  ## `line` with each code span blanked out, so prose checks skip code.
  result = line
  for s in spans:
    for k in s.first .. s.last:
      result[k] = ' '

proc problems(line: string): seq[string] =
  let
    spans = line.codeSpans
    prose = line.outsideSpans(spans)
  for s in spans:
    var n = 0
    while line[s.first + n] == '`':
      inc n
    let inner = line[s.first + n .. s.last - n]
    if inner.len > 0 and (inner[0] == ' ' or inner[^1] == ' '):
      result.add "code span starts or ends with a space: " &
        line[s.first .. s.last]
  if prose.strip.startsWith('[') and "]: " in prose:
    result.add "reference link definition; use an inline link"
  let refAt = prose.find("][")
  if refAt >= 0 and prose.find(']', refAt + 2) >= 0:
    result.add "reference-style link; use an inline link"
  for i in 0 ..< prose.len - 1:
    if prose[i] == '<' and (prose[i + 1] in Letters or prose[i + 1] in {'/', '!'}):
      result.add "inline HTML"
      break
  if "**`" in line or "`**" in line:
    result.add "code span inside bold"
  if line.strip.startsWith('|') and "\\|" in line:
    result.add "\\| in a table row; use a bullet list"
  if line.startsWith('#') and line.find({':', '-', '\''}) >= 0:
    result.add "heading with a colon, hyphen or apostrophe"

proc lint(page: string): seq[string] =
  var fenced = false
  let lines = readFile(Root / page).splitLines
  for i, line in lines:
    if line.startsWith("```"):
      fenced = not fenced
    elif not fenced:
      for p in line.problems:
        result.add page & ":" & $(i + 1) & ": " & p

proc main(): int =
  var pages: seq[string]
  for page in walkFiles(Root / GuideDir / "*.md"):
    pages.add page.relativePath(Root)
  pages.sort
  var found: seq[string]
  for page in pages:
    found.add page.lint
  for f in found:
    echo f
  if found.len > 0:
    echo found.len, " md2html problem(s) in the guide; see tools/guidelint.nim"
    return 1
  if pages.len == 0:
    echo "no guide pages found in ", Root / GuideDir
    return 1
  echo "guide Markdown OK (", pages.len, " pages)"

when isMainModule:
  quit main()
