# This example demonstrates the cp test. The following example would fail in
# docopt without consuming any options, no matter what you type:
# ```
# """cp
# Usage:
#  cp.py <src>... <dest>
# """
# ```
#
# Since `<src>` greedily consumes all arguments, it is never possible for
# `<dest>` to be supplied, so parsing always fails. Since argumint supports
# backtracking using a finite state machine, this is quite easy.



import std/strformat

import argumint

let
  spec = (
    src: args[string]("<src>", help = "The source file(s) to copy"),
    dest: arg("<dest>", help = "The destination to copy to"),
    recursive: flag("-r, --recursive", help = "Whether to recurse into subdirectories"),
    help: help()
  )

spec.parseOrQuit(usage = "[-r] <src>... <dest>", prolog = "Copy files around")
for file in spec.src:
  echo fmt"Copying {file} to {spec.dest} (recursive: {spec.recursive})"
