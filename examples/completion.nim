# This example demonstrates argumint's dynamic, FSM-driven shell completion
# (see docs/adr/0012-fsm-driven-shell-completion.md). Real completion
# requests (`<binary> __complete <partial words...>`) are intercepted
# automatically by `parseOrQuit*` -- nothing below handles `__complete`
# itself. The two things an author wires up by hand:
#
# - Installing a completion script: the `completion <shell>` subcommand
#   below prints one via `spec.completionScript(shell, binaryName)`, meant
#   to be sourced from the user's shell startup files.
# - Guarding expensive setup (a DB connection, config loading), simulated
#   below with `connectToDatabase()`. This is wired as a `before` hook
#   (see docs/adr/0009-command-before-action-after-hooks.md) rather than
#   run directly in `main()`, and checks `info.showsMessage` (see
#   docs/adr/0021-hook-info-matched-args.md) to skip it for a `--help`
#   request. `before` already never fires at all for a `__complete`
#   request -- that short-circuits before dispatch even starts -- so one
#   hook covers both cases. `isCompletionRequest()` still matters
#   separately for setup that has to happen *before* `parseOrQuit*` is
#   even callable, e.g. before the `Spec` itself is constructed; this
#   example has no such setup, so it isn't used below.
#
# Try it after compiling:
#   nim c examples/completion.nim
#   set -x PATH $PWD/examples $PATH    # fish; use `export PATH=...` for bash/zsh
#
# The PATH step matters: the generated script always shells out to the bare
# name `completion` (see `binaryName` below), never a relative/absolute
# path, since that's what `complete -c`/`complete -F` register against in
# every shell. Without it on PATH, completion fails with "Unknown command:
# completion" -- the same as it would for any real CLI tool whose completion
# script is installed but whose binary isn't actually on PATH.
#
#   source <(completion completion bash)   # bash / zsh
#   completion completion fish | source    # fish has no <() -- pipe into source
#   completion --log-level=<TAB>           # debug info warn error
#   completion dep<TAB>                    # deploy

import std/strformat
import std/strutils

import argumint
import argumint/backend
import argumint/validators

var built: Spec ## Assigned right after `spec` is constructed below; the
                 ## `completion` subcommand's own action closes over it to
                 ## reach the whole tree, not just its own nested spec.

proc connectToDatabase() =
  # Deliberately stderr, not `echo` -- stdout is reserved for the
  # `completion` subcommand's own script output, which callers pipe
  # straight into their shell's `source`. Mixing this in on stdout would
  # feed "Connecting to the database..." to `source` as if it were part
  # of the script.
  stderr.writeLine "Connecting to the database..."

proc cmdDeploy(spec: tuple, info: HookInfo) =
  echo fmt"Deploying to {spec.env}"

proc cmdCompletion(spec: tuple, info: HookInfo) =
  echo built.completionScript(parseEnum[Shell](spec.shell), "completion")

let
  deploy = (
    env: arg("<env>", validator = choice(["staging", "production"]), help = "Environment to deploy to"),
  )
  completionCmd = (
    shell: arg("<shell>", validator = choice(["bash", "zsh", "fish"]), help = "Shell to print a completion script for"),
  )
  spec = (
    logLevel: opt(
      "--log-level=<level>", default = "info",
      validator = choice(["debug", "info", "warn", "error"]), help = "Logging verbosity"
    ),
    deploy: command("deploy", deploy, action = cmdDeploy, usage = "<env>", help = "Deploy to an environment"),
    completion: command(
      "completion", completionCmd, action = cmdCompletion, usage = "<shell>",
      help = "Print a completion script for the given shell"
    ),
    help: help(),
  )

built = newSpec(spec, prolog = "A tiny CLI demonstrating dynamic shell completion")
built.before = proc(info: HookInfo) =
  if not info.showsMessage:
    connectToDatabase()

built.parseOrQuit()
