# Shell Completion

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

## Shell Completion

Completion candidates are resolved dynamically: a shell asks for them by
re-invoking the real compiled binary with a reserved leading argument,
`<binary> __complete <partial words...>`, and `parse`/`parseOrQuit` intercept
that automatically — re-walking the same FSM real parsing uses, rather than
reimplementing the grammar a second time in bash/zsh/fish. Candidates can never
drift out of sync with what real parsing would actually accept, since both come
from the exact same compiled FSM.

Two things you wire up yourself:

- **Installing a completion script.** `spec.completionScript(shell, binaryName)`
  (`shell` is `Shell = bash | zsh | fish`) returns a script string for that
  shell — author-driven: write it to a file, expose it via a subcommand,
  whatever your packaging needs.
- **Guarding expensive pre-parse setup.** Every completion request re-invokes
  your binary as a fresh process, so anything that runs *before*
  `parse`/`parseOrQuit` is even called (opening a DB connection, loading config)
  reruns on every keystroke, not just real invocations. `isCompletionRequest()`
  lets you skip it. (A `before` hook doesn't need this — see `info.showsMessage`
  in [Commands](commands.md#hookinfo) — since completion requests never reach
  `dispatch` at all.)

```nim
import std/strformat
import argumint

proc cmdDeploy(spec: tuple, info: HookInfo) =
  echo fmt"Deploying to {spec.env}"

let
  deploy = (
    env: arg("<env>", validator = choice(["staging", "production"]),
      help = "Environment to deploy to"),
  )
  spec = (
    logLevel: opt("--log-level=<level>", default = "info",
      validator = choice(["debug", "info", "warn", "error"]),
      help = "Logging verbosity"),
    deploy: command("deploy", deploy, action = cmdDeploy, usage = "<env>",
      help = "Deploy to an environment"),
    help: help(),
  )

spec.parseOrQuit(prolog = "A tiny CLI demonstrating dynamic shell completion")
```

Once installed, TAB-completing this CLI in a live shell walks the FSM under the
hood — shown here as the literal `__complete` calls a shell's adapter script
makes on your behalf:

```console
$ ./deploy __complete ""
-h	Display this help message
--help	Display this help message
--log-level	Logging verbosity
deploy	Deploy to an environment

$ ./deploy __complete dep
deploy	Deploy to an environment

$ ./deploy __complete --log-level ""
debug	
info	
warn	
error	

$ ./deploy __complete deploy ""
staging	
production	
```

Each candidate is one `value\thelp` line (`help` may be empty, but the tab is
always present). `debug`/`info`/`staging`/`production` above come straight from
each option/arg's own `choice()` validator (`Validator[T].completions()` — see
[Validating Values](args-and-options.md#validating-values)) — there's no
separate place to declare completion values, so they can never drift out of sync
with what the validator would actually accept. **Only fish and zsh render `help`
inline** in their own completion menu; bash's `compgen`/`COMPREPLY` has no
per-candidate description slot at all, so its generated script strips it before
completing bare words. A multi-line `help` is shortened to its first paragraph
(up to the first blank line), dedented and joined onto one line, so a `"""` long
description still gives a one-line summary.
