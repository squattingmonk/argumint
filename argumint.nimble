# Package

version       = "0.1.0"
author        = "Michael A. Sinclair"
description   = "A fresh command-line argument parsing library"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.2.4"


# Tasks

task test, "Run the test suite":
  # Compiling and running every source file both sanity-compiles modules with
  # no `when isMainModule` block (a stand-in for `nim check`) and executes
  # the embedded `std/unittest` blocks of modules that have one -- so a new
  # file's tests run without any wiring here. See tools/runtests.nim.
  exec "nim c -r --hints:off tools/runtests.nim"

task examples, "Compile every example":
  for file in listFiles("examples"):
    if file.endsWith(".nim"):
      exec "nim c " & file

task docs, "Generate HTML API docs into htmldocs/ (open htmldocs/index.html)":
  let
    outDir = "htmldocs"
    docRoot = thisDir() & "/src"
    gitFlags = "--git.url:https://github.com/squattingmonk/argumint --git.commit:main --git.devel:main"
  rmDir(outDir)
  # One `--project` pass per entry point -- `argumint/configsource/ini`/`json`
  # aren't reachable from `argumint.nim`'s own import graph (they're opt-in
  # config-file backends users import directly), so they need their own
  # pass to get their own pages. Sharing `docRoot`/`outDir` keeps both passes'
  # relative links (and the combined `theindex.html`) resolving correctly.
  exec "nim doc --project --index:on --docRoot:" & docRoot & " --outdir:" & outDir & " " & gitFlags & " src/argumint.nim"
  exec "nim doc --project --index:on --docRoot:" & docRoot & " --outdir:" & outDir & " " & gitFlags & " src/argumint/configsource/ini.nim"
  exec "nim doc --project --index:on --docRoot:" & docRoot & " --outdir:" & outDir & " " & gitFlags & " src/argumint/configsource/json.nim"
  # The user guide: plain Markdown that reads on GitHub too, so its links
  # between pages say `.md` -- md2html leaves them alone, so point them at
  # the rendered `.html` here. md2html also titles a page with its file
  # path unless it opens with an RST overline title, which GitHub can't
  # render, so swap in the page's own `# Title` and drop its duplicate.
  for file in listFiles("docs/guide"):
    if file.endsWith(".md"):
      exec "nim md2html --hints:off --outdir:" & outDir & "/guide " & file
      let
        html = outDir & "/guide/" & file.rsplit({'/', '\\'}, 1)[^1].replace(".md", ".html")
        path = file.replace('\\', '/').replace(".md", "")
      var page = readFile(html).replace(".md\"", ".html\"").replace(".md#", ".html#")
      let
        start = page.find("<h1 id=\"")
        stop = page.find("</h1>", start) + "</h1>".len
        title = page[page.find('>', start) + 1 ..< stop - "</h1>".len]
      page = page[0 ..< start] & page[stop .. ^1]
      writeFile(html, page.replace(">" & path & "<", ">" & title & "<"))
  cpDir("docs/images", outDir & "/images")
  writeFile(outDir & "/index.html", "<!DOCTYPE html>\n<meta http-equiv=\"refresh\" content=\"0; url=guide/index.html\">\n")
