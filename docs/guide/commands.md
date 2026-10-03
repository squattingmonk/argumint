# Commands

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

A **command** is a word that picks what your program does, like `install` in
`pkg install foo`. Each command has a spec of its own, and everything after
the word on the command line is parsed against that spec:

```nim
import argumint

proc install(spec: tuple, _: HookInfo) =
  for name in spec.names:
    echo "Installing ", name

proc remove(spec: tuple, _: HookInfo) =
  for name in spec.names:
    echo "Removing ", name

let
  installSpec = (
    names: args("<name>", help = "Packages to install"),
    help: help(),
  )
  removeSpec = (
    names: args("<name>", help = "Packages to remove"),
    help: help(),
  )
  spec = (
    install: command("install", installSpec, action = install,
      help = "Install packages", prolog = "Install packages by name.",
      epilog = "Installed packages go in ~/.pkg."),
    remove: command("remove", removeSpec, action = remove,
      help = "Remove packages"),
    help: help(),
  )

spec.parseOrQuit(prolog = "A tiny package manager")
```

`command` takes the command's name and its spec. Its `action` runs once the
whole command line has parsed, and receives the command's own spec, so
`install` reads `spec.names` from `installSpec`. See
[Before, Action, and After Hooks](#before-action-and-after-hooks).

```console
$ ./pkg install foo bar
Installing foo
Installing bar
$ ./pkg update
Parsing error:
  - unrecognized command: update

Usage:
  pkg (install | remove)
  pkg (-h | --help)
```

A command's `help` is its summary in the program's help. Its `prolog` heads
its own help, and its `epilog` ends it. argumint writes the usage at both
levels:

```console
$ ./pkg --help
A tiny package manager

Usage:
  pkg (install | remove)
  pkg (-h | --help)

Commands:
  install     Install packages
  remove      Remove packages

Options:
  -h, --help  Display this help message

$ ./pkg install --help
Install packages by name.

Usage:
  pkg install <name>...
  pkg install (-h | --help)

Arguments:
  <name>      Packages to install

Options:
  -h, --help  Display this help message

Installed packages go in ~/.pkg.
```

## More Than One Name

A command can have more than one name. List them in one string, as for an
option:

```nim
    remove: command("remove, rm", removeSpec, action = remove,
      help = "Remove packages"),
```

```console
$ ./pkg rm foo
Removing foo
$ ./pkg --help
A tiny package manager

Usage:
  pkg (install | remove | rm)
  pkg (-h | --help)

Commands:
  install     Install packages
  remove, rm  Remove packages

Options:
  -h, --help  Display this help message
```

## Knowing Which Command Ran

For a simple program, you don't need an
[action](#before-action-and-after-hooks) to use commands. After parsing,
`seen` says whether the user gave a command, and its spec holds the values:

```nim
import argumint

let
  installSpec = (names: args("<name>", help = "Packages to install"))
  removeSpec = (names: args("<name>", help = "Packages to remove"))
  spec = (
    install: command("install", installSpec, help = "Install packages"),
    remove: command("remove", removeSpec, help = "Remove packages"),
  )

spec.parseOrQuit()
if spec.install.seen:
  echo "Installing ", installSpec.names
elif spec.remove.seen:
  echo "Removing ", removeSpec.names
```

```console
$ ./pkg install a b
Installing @["a", "b"]
$ ./pkg remove c
Removing @["c"]
```

## Commands Inside Commands

A command's spec can have commands of its own, to any depth:

```nim
import argumint

proc addRemote(spec: tuple, _: HookInfo) =
  echo "Added ", spec.name, " at ", spec.url

proc listRemotes(spec: tuple, _: HookInfo) =
  echo if spec.verbose: "origin https://example.com/pkgs" else: "origin"

let
  addSpec = (
    name: arg("<name>", help = "Name of the remote"),
    url: arg("<url>", help = "Where to fetch packages from"),
    help: help(),
  )
  listSpec = (
    verbose: flag("-v, --verbose", help = "Show each remote's URL"),
    help: help(),
  )
  remoteSpec = (
    add: command("add", addSpec, action = addRemote, help = "Add a remote"),
    list: command("list", listSpec, action = listRemotes, help = "List remotes"),
    help: help(),
  )
  spec = (
    remote: command("remote", remoteSpec, help = "Manage package sources"),
    help: help(),
  )

spec.parseOrQuit()
```

```console
$ ./pkg remote add origin https://example.com/pkgs
Added origin at https://example.com/pkgs
$ ./pkg remote list -v
origin https://example.com/pkgs
$ ./pkg remote --help
Usage:
  pkg remote (add | list)
  pkg remote (-h | --help)

Commands:
  add         Add a remote
  list        List remotes

Options:
  -h, --help  Display this help message
```

Only the deepest command the user gave runs its `action`. `remote` has none,
since it only leads to `add` and `list`.

## Usage Lines for a Command

A command takes the rest of the command line, so nothing can follow it on a
usage line. Its own arguments and options go in its own usage string, passed
as `usage`:

```nim
import argumint

let
  installSpec = (
    names: args("<name>", help = "Packages to install"),
    force: flag("-f, --force", help = "Reinstall installed packages"),
    help: help(),
  )
  spec = (
    install: command("install", installSpec, help = "Install packages"),
  )

spec.parseOrQuit(usage = "install [-f] <name>...")
```

argumint can never match anything after `install` here, so building the spec
raises a `SpecDefect`:

```console
$ ./pkg install foo
Error constructing spec: Error at (1:8): Nothing may follow a Command earlier in the same Usage Line -- a matched Command consumes every remaining argument, so anything after it can never be reached; use '(a | b)' for alternatives, or move it into the earlier Command's own usage
install [-f] <name>...
        ^
```

Move the rest of the line into the command:

```nim
  spec = (
    install: command("install", installSpec, usage = "[-f] <name>...",
      help = "Install packages"),
  )

spec.parseOrQuit()
```

```console
$ ./pkg install --help
Usage:
  pkg install [-f] <name>...
  pkg install (-h | --help)

Arguments:
  <name>       Packages to install

Options:
  -f, --force  Reinstall installed packages
  -h, --help   Display this help message
```

In a command's usage string, `{cmd}` stands for the whole command path, like
`pkg install`. See [Naming the Program](usage-strings.md#naming-the-program).

## Before, Action, and After Hooks

A spec can run three hooks once the command line has parsed:

- `before` runs first, at every level the user gave, starting from the
  program's own spec.
- `action` runs once, at the deepest level the user gave.
- `after` runs last, at every level, in the reverse order.

`command` takes all three, and so do `parse` and `parseOrQuit` for the
program's own spec. Each hook is a proc that takes its level's spec and a
`HookInfo`:

```nim
import argumint

proc pkgBefore(spec: tuple, _: HookInfo) = echo "pkg: before"
proc pkgAfter(spec: tuple, _: HookInfo) = echo "pkg: after"
proc remoteBefore(spec: tuple, _: HookInfo) = echo "remote: before"
proc remoteAfter(spec: tuple, _: HookInfo) = echo "remote: after"
proc addRemote(spec: tuple, _: HookInfo) = echo "add: action"

let
  addSpec = (
    name: arg("<name>", help = "Name of the remote"),
    url: arg("<url>", help = "Where to fetch packages from"),
    help: help(),
  )
  remoteSpec = (
    add: command("add", addSpec, action = addRemote, help = "Add a remote"),
    help: help(),
  )
  spec = (
    remote: command("remote", remoteSpec, before = remoteBefore,
      after = remoteAfter, help = "Manage package sources"),
    help: help(),
  )

spec.parseOrQuit(before = pkgBefore, after = pkgAfter)
```

```console
$ ./pkg remote add origin https://example.com/pkgs
pkg: before
remote: before
add: action
remote: after
pkg: after
```

The hooks run only after every value on the command line is converted and
validated, so a mistake anywhere means no hook runs at all. A hook can read
any value at its own level.

`after` is for cleanup, so it runs even if a deeper hook raises an exception,
as long as its own `before` finished. If `remoteBefore` raised, `pkgAfter` would
still run, but `remoteAfter` wouldn't. The exception then reaches your program
as usual.

When the user asks for help, the `before` and `after` hooks still run down to
the level where they asked, but no `action` does:

```console
$ ./pkg remote --help
pkg: before
remote: before
remote: after
pkg: after
Usage:
  pkg remote add
  pkg remote (-h | --help)

Commands:
  add         Add a remote

Options:
  -h, --help  Display this help message
```

### An Action for the Program Itself

The program's own spec runs its `action` when the user gives no command. Add a
usage line with no command on it, such as `{cmd}` on its own:

```nim
import argumint

proc showStatus(spec: tuple, _: HookInfo) = echo "All packages are up to date"
proc install(spec: tuple, _: HookInfo) = echo "Installing ", spec.names

let
  installSpec = (names: args("<name>", help = "Packages to install"), help: help())
  spec = (
    install: command("install", installSpec, action = install,
      help = "Install packages"),
    help: help(),
  )

spec.parseOrQuit(action = showStatus, usage = """
{cmd}
{cmd} install
""")
```

```console
$ ./pkg
All packages are up to date
$ ./pkg install foo
Installing @["foo"]
```

### What a Hook Can See

A hook's `HookInfo` describes the whole command line, not just its own
level. `info.matched` holds every `Arg` the command line matched, at every
level. `info.showsMessage` is true when the user asked for help, a version,
or another [message](help.md), so a `before` hook can skip work that only a
real run needs. Add this to the first example on this page:

```nim
proc openDb(spec: tuple, info: HookInfo) =
  if not info.showsMessage:
    echo "Opening the package database"

spec.parseOrQuit(before = openDb)
```

```console
$ ./pkg install foo
Opening the package database
Installing foo
$ ./pkg install --help
Install packages by name.

Usage:
  pkg install <name>...
  pkg install (-h | --help)

Arguments:
  <name>      Packages to install

Options:
  -h, --help  Display this help message

Installed packages go in ~/.pkg.
```

### Passing Extra Context to Hooks

A hook receives only its own level's spec. To read a value from another
level, share its `Arg` between the specs, as the
[tutorial](tutorial.md#subcommands) does.

To pass a hook more than one value, give `command` a third argument after the
spec. Each of its hooks then takes that argument after its spec:

```nim
import argumint

proc install(spec: tuple, global: tuple, _: HookInfo) =
  for name in spec.names:
    if global.dryRun:
      echo "Would install ", name
    else:
      echo "Installing ", name

let
  global = (
    dryRun: flag("-n, --dry-run", help = "Show what would happen"),
  )
  installSpec = (names: args("<name>", help = "Packages to install"))
  spec = (
    dryRun: global.dryRun,
    install: command("install", installSpec, global, action = install,
      help = "Install packages"),
    help: help(),
  )

spec.parseOrQuit()
```

`dryRun` belongs to the program's spec, so the user gives it before
`install`, and the hook reads it from `global`:

```console
$ ./pkg install foo
Installing foo
$ ./pkg -n install foo
Would install foo
```

The extra argument can be anything, not just a tuple of `Arg`s.
