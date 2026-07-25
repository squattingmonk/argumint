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
  exec "nim c -r src/argumint/validators.nim"
  exec "nim c -r src/argumint/flagclamp.nim"
  exec "nim c -r src/argumint/configsource.nim"
  exec "nim c -r src/argumint/configsource/ini.nim"
  exec "nim c -r src/argumint/configsource/json.nim"
  exec "nim c -r src/argumint/fsm.nim"
  exec "nim c -r src/argumint.nim"
  for file in listFiles("tests"):
    if file.endsWith(".nim"):
      exec "nim c -r " & file

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
  writeFile(outDir & "/index.html", "<!DOCTYPE html>\n<meta http-equiv=\"refresh\" content=\"0; url=argumint.html\">\n")
