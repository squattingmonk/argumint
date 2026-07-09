# This example demonstrates subcommands with per-command handlers, in the
# same style as the larger Naval Fate demo in src/argumint.nim (see
# `command()`), but pared down to just two subcommands: `add` and `commit`. A
# top-level `--verbose` flag shows how `[options]` auto-fills into the usage
# line for whatever isn't otherwise reachable.

import std/strformat

import argumint

proc cmdAdd(spec: tuple) =
  for file in spec.files:
    echo fmt"Staging {file}"

proc cmdCommit(spec: tuple) =
  let action = if spec.amend: "Amending" else: "Committing"
  echo fmt"{action} with message: {spec.message}"

let
  add = (
    files: args[string]("<file>", help = "Files to stage"),
    help: help(),
  )

  commit = (
    message: arg[string]("<message>", help = "Commit message"),
    amend: flag("--amend", help = "Amend the previous commit"),
    help: help(),
  )

  spec = (
    verbose: flag("--verbose", help = "Show extra output"),
    add: command("add", add, handler = cmdAdd, usage = "<file>...", help = "Add file contents to the index"),
    commit: command(
      "commit", commit, handler = cmdCommit,
      usage = "[--amend] <message>", help = "Record changes to the repository"
    ),
    help: help()
  )

spec.parseOrQuit(prolog = "A tiny git-like CLI")
