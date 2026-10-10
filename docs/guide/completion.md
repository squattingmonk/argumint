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
    config: opt("--config=<file>", help = "Settings to load"),
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
--config	Settings to load
deploy	Deploy the site
completion	Print a shell completion script
:
$ site __complete --log-level ""
debug	
info	
warn	
error	
:
$ site __complete --config ""
:files
$ site __complete deploy ""
-h	Display this help message
--help	Display this help message
-f	Deploy even if checks fail
--force	Deploy even if checks fail
staging	
production	
:
$ site __complete deploy s
staging	
:
```

Each line is a word, a tab, and a description, which may be empty. The last
line says which file names the shell should add: `:files`, `:dirs` for
directories only, or `:` for none. The shell offers only the words that start
with what the user typed.

fish and zsh show each description beside its word. bash shows only the words,
since it has nowhere to put a description. A `help` longer than one paragraph is
cut to its first, joined onto one line. A [flag](flags.md#flag-operations) whose
operations do different things adds the operation, as help does.

Values come from a `choice`
[validator](args-and-options.md#validating-values). A validator built with
`any` offers the values of every `choice` in it, and one built with `all`
offers the ones that pass every check.

Any other value, such as `--config` above or an argument like `<file>`, gets
file names, along with directories to look in. Options are still offered
beside them, and typing `-` narrows the list to options. To offer only
directories, or no file names at all, pass `complete` to `arg`, `args`, `opt`
or `opts`:

```nim
  dest: arg("<dest>", complete = Dirs, help = "Directory to deploy into"),
  name: opt("--name=<name>", complete = None, help = "Name for the release"),
```

Unless you pass `complete`, a `choice` validator's values replace file names,
since no file name would pass it. When you do pass it, it decides: an argument
with a `choice` and `complete = Dirs` offers directories. To offer values of
your own, see [Completing Values at Runtime](#completing-values-at-runtime).

An option, command, or argument declared with `hidden = true` isn't offered,
even when what the user typed matches it, though it still parses. A hidden
argument gets no file names either. Once the user has typed a hidden option,
completion carries on as usual, so its values or file names are still
offered. See [Groups](help.md#groups).

`parse` and `parseOrQuit` answer a completion request themselves, so
`__complete` can't be the name of a command. `parseOrQuit` prints the words
and exits with `0`. `parse` raises a `CompletionError` with the words as its
message, ending with the line that names the file names to add. See
[Error Handling](errors.md).

## Completing Values at Runtime

Some values can only be listed by looking: the hosts in an environment, the
branches in a repository. Pass `complete` a proc, and argumint runs it each
time the user presses Tab at that value. The proc takes a `CompletionContext`
and returns an `Offer`, which `offer` builds from the values:

```nim
import argumint

proc hostsIn(env: string): seq[string] =
  if env == "production": @["web1", "web2", "db1"] else: @["stage1"]

let env = arg("<env>", validator = choice(["staging", "production"]),
              help = "Where to deploy")
let spec = (
  env: env,
  host: arg("<host>", help = "Host to deploy to",
            complete = proc (ctx: CompletionContext): Offer =
              offer(hostsIn(env.get))),
  help: help(),
)

spec.parseOrQuit()
echo "Deploying to ", spec.host, " in ", spec.env
```

When the proc runs, the arguments and options before it already hold what the
user typed, or what an environment variable or config file gave them. So
`<host>` reads `env` to list the hosts in that environment. A proc can only
read an `Arg` it can see, so `env` is declared before the spec, with `let`.
For an `args` or `opts`, the proc can also read the values already given, to
leave them out.

```console
$ deploy __complete production ""
web1	
web2	
db1	
:
$ deploy __complete production w
web1	
web2	
:
```

argumint offers only the values that start with what the user typed, so the
proc can return them all. `ctx.word` is what the user typed, if a slow lookup
can use it to fetch less.

To describe each value, give `offer` pairs of value and description. fish and
zsh show them; bash shows only the values:

```nim
  offer([("web1", "Frontend"), ("db1", "Primary database")])
```

The proc's values replace a `choice` validator's, and file names. To offer
file names beside them, pass `paths`:

```nim
  offer(["-"], paths = Files)
```

The proc runs inside the user's shell, each time they press Tab:

- Return quickly. A network call needs a timeout of its own.
- Don't write to stdout, which would become values, or stderr, which shows up
  in the user's shell.
- No hook has run, so nothing a `before` hook sets up is there.
- If it raises an exception, nothing is offered. To offer file names instead,
  catch it in the proc and return `offer([], paths = Files)`.

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
