# This example demonstrates argumint's dynamic, FSM-driven shell completion
# (see docs/adr/0012-fsm-driven-shell-completion.md and
# docs/adr/0022-completion-candidate-help-text.md). Real completion
# requests (`<binary> __complete <partial words...>`) are intercepted
# automatically by `parseOrQuit*` -- nothing below handles `__complete`
# itself. The two things an author wires up by hand:
#
# - Installing a completion script: `completion()` adds a `completion
#   <shell>` subcommand that prints one (see
#   docs/adr/0074-built-in-completion-command.md), meant to be sourced from
#   the user's shell startup files.
# - Guarding expensive setup (a DB connection, config loading), simulated
#   below with `connectToDatabase()`. This is wired as a `before` hook
#   (see docs/adr/0009-command-before-action-after-hooks.md) rather than
#   run directly in `main()`, and checks `info.showsMessage` (see
#   docs/adr/0021-hook-info-matched-args.md) to skip it for a `--help` or
#   `completion <shell>` request, which are both messages. `before` already
#   never fires at all for a `__complete` request -- that short-circuits
#   before dispatch even starts -- so one hook covers both cases.
#   `isCompletionRequest()` still matters separately for setup that has to
#   happen *before* `parseOrQuit*` is even callable, e.g. before the `Spec`
#   itself is constructed; this example has no such setup, so it isn't used
#   below.
#
# `deploy <env> <host>` also shows a completer proc (see
# docs/adr/0071-runtime-completers.md): `<host>`'s values can't be listed up
# front, since they depend on the environment, so its `complete` proc looks
# them up when the user presses Tab. By then `env` already holds what the user
# typed, so the proc reads it by capturing `env`, declared with `let` before
# the spec. The proc runs inside the user's shell with no hook run first: it
# stays quiet (no `echo`, no stderr) and doesn't rely on `connectToDatabase`.
#
# Try it after compiling:
#   nim c examples/completion.nim
#   set -x PATH $PWD/examples $PATH    # fish; use `export PATH=...` for bash/zsh
#
# The PATH step matters: the generated script always shells out to the bare
# name the program runs as, `completion`, never a relative/absolute path,
# since that's what `complete -c`/`complete -F` register against in every
# shell. Without it on PATH, completion fails with "Unknown command:
# completion" -- the same as it would for any real CLI tool whose completion
# script is installed but whose binary isn't actually on PATH.
#
#   source <(completion completion bash)   # bash / zsh
#   completion completion fish | source    # fish has no <() -- pipe into source
#   completion --log-level=<TAB>           # debug info warn error
#   completion dep<TAB>                    # deploy
#   completion deploy production <TAB>     # web1 web2 db1
#   completion deploy staging <TAB>        # stage1
#
# In a live fish or zsh shell (not bash, which has no way to render one),
# each candidate's own `help = "..."` text shows up alongside it in the
# completion menu -- e.g. TAB-completing `completion <TAB>` shows "deploy"
# beside "Deploy to an environment" and "completion" beside "Print a shell
# completion script", not just the bare words. See
# docs/adr/0022-completion-candidate-help-text.md.

import std/strformat

import argumint

proc connectToDatabase() =
  echo "Connecting to the database..."

proc hostsIn(env: string): seq[(string, string)] =
  ## Each host in `env`, with a description for the completion menu. A real
  ## CLI would ask an inventory service, with a timeout of its own.
  case env
  of "production": @[("web1", "Frontend"), ("web2", "Frontend"),
                     ("db1", "Primary database")]
  of "staging": @[("stage1", "Everything, on one box")]
  else: @[]

proc cmdDeploy(spec: tuple, info: HookInfo) =
  echo fmt"Deploying to {spec.host} in {spec.env}"

proc setup(spec: tuple, info: HookInfo) =
  # A message, like `completion fish`'s script, goes to stdout to be piped
  # into `source`, so setup output there would corrupt it.
  if not info.showsMessage:
    connectToDatabase()

let
  env = arg("<env>", validator = choice(["staging", "production"]), help = "Environment to deploy to")
  deploy = (
    env: env,
    host: arg("<host>", help = "Host to deploy to",
      complete = proc (ctx: CompletionContext): Offer = offer(hostsIn(env.get))),
    help: help(),
  )
  spec = (
    logLevel: opt(
      "--log-level=<level>", default = "info",
      validator = choice(["debug", "info", "warn", "error"]), help = "Logging verbosity"
    ),
    deploy: command("deploy", deploy, action = cmdDeploy, usage = "<env> <host>", help = "Deploy to an environment"),
    completion: completion(),
    help: help(),
  )

spec.parseOrQuit(before = setup,
  prolog = "A tiny CLI demonstrating dynamic shell completion")
