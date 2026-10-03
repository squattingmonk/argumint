# Shell Completion

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

argumint can complete commands, options, and their values in bash, zsh, and
fish. When the user presses Tab, the shell runs your program to ask what can
come next. Your program answers from the same usage strings it parses with,
so completion always agrees with the parser.

You don't write any completion code. You only give users a script that tells
their shell to ask your program. `completionScript` writes one for each shell,
and a command is an easy way to print it:

```nim
import std/strutils
import argumint

var cli: Spec

proc deploy(spec: tuple, _: HookInfo) =
  echo "Deploying to ", spec.env

proc printCompletion(spec: tuple, _: HookInfo) =
  echo cli.completionScript(parseEnum[Shell](spec.shell))

let
  deploySpec = (
    env: arg("<env>", validator = choice(["staging", "production"]),
             help = "Where to deploy"),
    force: flag("-f, --force", help = "Deploy even if checks fail"),
    help: help(),
  )
  completionSpec = (
    shell: arg("<shell>", validator = choice(["bash", "zsh", "fish"]),
               help = "Shell to print a script for"),
    help: help(),
  )
  spec = (
    logLevel: opt("--log-level=<level>", default = "info",
                  validator = choice(["debug", "info", "warn", "error"]),
                  help = "How much to log"),
    deploy: command("deploy", deploySpec, action = deploy,
                    help = "Deploy the site"),
    completion: command("completion", completionSpec, action = printCompletion,
                        help = "Print a shell completion script"),
    help: help(),
  )

cli = newSpec(spec, prolog = "Deploy a website")
cli.parseOrQuit()
```

`completionScript` needs the built `Spec`, not the tuple, so the program
builds it with `newSpec` and keeps it in `cli`. See
[Keeping a Built Spec](specs.md#keeping-a-built-spec).

## Installing the Script

The script runs your program by name, so the program must be on the user's
`PATH`. To try it in the current shell:

```console
$ source <(site completion bash)    # bash
$ source <(site completion zsh)     # zsh
$ site completion fish | source     # fish
```

zsh needs `compinit` to have run first, as most zsh setups do. To keep the
script, add the `source` line to `~/.bashrc` or `~/.zshrc`. fish loads a script
from its completions directory the first time the user completes the program, as
does bash with the bash-completion package installed:

```console
$ site completion fish > ~/.config/fish/completions/site.fish
$ site completion bash > ~/.local/share/bash-completion/completions/site
```

The script completes the program under its file name. To always complete one
name, even if the user renames the program, pass it as the second argument:

```nim
  echo cli.completionScript(parseEnum[Shell](spec.shell), "site")
```

## What Gets Completed

At each point on the command line, Tab offers every command and option the
usage strings allow there, and the values of a `choice` validator. To see
what it would offer, run your program with `__complete`, then the words
typed so far, then the word being completed. This is what the script does
each time the user presses Tab:

```console
$ site __complete ""
-h	Display this help message
--help	Display this help message
--log-level	How much to log
deploy	Deploy the site
completion	Print a shell completion script
$ site __complete --log-level ""
debug	
info	
warn	
error	
$ site __complete deploy ""
-h	Display this help message
--help	Display this help message
-f	Deploy even if checks fail
--force	Deploy even if checks fail
staging	
production	
$ site __complete deploy s
staging	
```

Each line is a word, a tab, and a description, which may be empty. The shell
offers only the words that start with what the user typed.

fish and zsh show each description beside its word. bash shows only the words,
since it has nowhere to put a description. A `help` longer than one paragraph is
cut to its first, joined onto one line. A [flag](flags.md#flag-operations) whose
operations do different things adds the operation, as help does.

Values come only from a `choice`
[validator](args-and-options.md#validating-values). A validator built with
`any` offers the values of every `choice` in it, and one built with `all`
offers the ones that pass every check. Other values aren't completed, and the
shell doesn't fall back to file names, so Tab offers nothing for an argument
like `<file>`.

`parse` and `parseOrQuit` answer a completion request themselves, so
`__complete` can't be the name of a command. `parseOrQuit` prints the words
and exits with `0`. `parse` raises a `CompletionError` with the words as its
message. See [Error Handling](errors.md).

## Expensive Setup

The shell runs your program each time the user presses Tab. No hook runs for
a completion request, so a `before` hook is a good place for slow setup, like
opening a database. To skip it for help as well, see
[What a Hook Can See](commands.md#what-a-hook-can-see).

Code that runs before `parse` or `parseOrQuit` still runs for a completion
request. `isCompletionRequest` tells you to skip it:

```nim
if not isCompletionRequest():
  loadConfig()

cli.parseOrQuit()
```
