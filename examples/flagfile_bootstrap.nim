# Demonstrates a GNU-style `@file` flagfile convention: a token on the
# command line beginning with `@` is expanded into that file's
# whitespace-delimited contents, recursively, before argumint ever sees it.
#
# This needs no support from argumint itself -- `expandFlagfiles` is a plain
# `seq[string] -> seq[string]` transform run on `commandLineParams()` before
# the first `parse()`/`parseOrQuit()` call, so the library only ever sees an
# already-expanded argv. Unlike `examples/config_bootstrap.nim`'s Config
# Source bootstrap (a `before` hook triggering a *second* parse once
# `--config` is known), this can't be done with a hook: a `before` hook only
# fires after its own spec's values already parsed successfully, but a
# flagfile may supply *required* positional args (like `<src>...` below) --
# so the args have to be expanded before the first, only, parse call.
#
# Try it with:
#   nim c -r examples/flagfile_bootstrap.nim -- --help
#   nim c -r examples/flagfile_bootstrap.nim -- -r src/a.nim src/b.nim dest/
#   nim c -r examples/flagfile_bootstrap.nim -- @examples/flagfile_bootstrap.files dest/
#   nim c -r examples/flagfile_bootstrap.nim -- -r @examples/flagfile_bootstrap.files dest/

import std/[os, sets, strformat, strutils]

import argumint

proc expandFlagfiles(args: seq[string]): seq[string] =
  var seen: HashSet[string]

  proc expand(args: seq[string]): seq[string] =
    for a in args:
      if a.len > 1 and a[0] == '@':
        let path = a[1..^1]
        let full = expandFilename(path)
        if full in seen:
          raise newException(IOError, fmt"flagfile cycle: {path} includes itself")
        seen.incl(full)
        result.add expand(readFile(path).splitWhitespace)
      else:
        result.add a

  result = expand(args)

let spec = (
  src: args("<src>", help = "The source file(s) to copy"),
  dest: arg("<dest>", help = "The destination to copy to"),
  recursive: flag("-r, --recursive", help = "Whether to recurse into subdirectories"),
  help: help()
)

spec.parseOrQuit(usage = "[-r] <src>... <dest>", prolog = "Copy files around",
  args = expandFlagfiles(commandLineParams()))

for file in spec.src:
  echo fmt"Copying {file} to {spec.dest} (recursive: {spec.recursive})"
