# Package

version       = "0.1.0"
author        = "Michael A. Sinclair"
description   = "A fresh take on arg parsing"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 1.6.4"

task lexer, "build the lexer":
  exec "nim c -o:lexer src/argumint/lexer.nim"

task parser, "build the parser":
  exec "nim c -o:parser src/argumint/parsespec.nim"

task fsm, "build the fsm":
  exec "nim c -o:fsm -d:nimPreviewHashRef src/argumint/fsm.nim"

task args, "builds the args":
  exec "nim c -o:args src/argumint/args.nim"
