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
