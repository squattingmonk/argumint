## Compiles the user guide's example programs for `nimble docscheck`, so an
## example that stops compiling after an API change fails review instead of
## reaching readers (issue #205).
##
## Every ```` ```nim ```` block in `docs/guide/*.md` whose first non-blank
## line starts with `import` is a whole program; the rest are fragments that
## continue an earlier example and are skipped. Each program is written to
## `nimcache/guide/` as `<page>_L<line>.nim`, named after the line of its
## opening fence, and compiled (not run: some examples raise a `SpecDefect`
## on purpose) in parallel against `src`. Every failure is named by page and
## line.

import std/[algorithm, os, osproc, sequtils, strutils]

const
  GuideDir = "docs" / "guide"
  BuildDir = "nimcache" / "guide"

type
  Block = object
    ## One whole-program code block.
    page: string
      ## Path to the guide page, relative to the project root
    line: int
      ## Line number of the block's opening fence
    source: string
      ## Path the block is written to for compiling

proc writePrograms(page: string): seq[Block] =
  ## Writes every whole-program block in `page` to `BuildDir`.
  var
    code: seq[string]
    start = 0
    inNim = false
    inOther = false
  let lines = page.readFile.splitLines
  for i, line in lines:
    if inNim or inOther:
      if line.startsWith("```"):
        let first = code.filterIt(it.strip.len > 0)
        if inNim and first.len > 0 and first[0].startsWith("import"):
          let
            name = page.splitFile.name.replace('-', '_') & "_L" & $start
            source = BuildDir / name & ".nim"
          writeFile(source, code.join("\n") & "\n")
          result.add Block(page: page, line: start, source: source)
        code.setLen 0
        inNim = false
        inOther = false
      elif inNim:
        code.add line
    elif line == "```nim":
      inNim = true
      start = i + 1
    elif line.startsWith("```"):
      inOther = true

proc compileCmd(b: Block): string =
  let name = b.source.splitFile.name
  quoteShellCommand(["nim", "c", "--hints:off", "--warnings:off",
    "--path:src", "--nimcache:" & BuildDir / "cache" / name,
    "-o:" & BuildDir / "bin" / name.addFileExt(ExeExt), b.source])

proc main(): int =
  removeDir BuildDir
  createDir BuildDir
  var blocks: seq[Block]
  for kind, path in walkDir(GuideDir):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".md"):
      blocks.add writePrograms(path)
  blocks.sort proc (a, b: Block): int = cmp((a.page, a.line), (b.page, b.line))
  let workers = max(countProcessors(), 1).min(blocks.len)
  echo "Compiling ", blocks.len, " guide examples with ", workers, " workers..."
  var failed: seq[int]
  # Output isn't captured -- see docs/gotchas.md.
  discard execProcesses(blocks.mapIt(it.compileCmd), n = workers,
    afterRunEvent = proc (i: int, p: Process) =
      if p.peekExitCode != 0: failed.add i)
  for i in failed.sorted:
    echo "== FAILED to compile ", blocks[i].page, ":", blocks[i].line,
      " (", blocks[i].source, ")"
  result = int(failed.len > 0)

when isMainModule:
  quit main()
