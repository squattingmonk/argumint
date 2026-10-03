# Commands

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

## Commands

`command(variants, spec, help, prolog, epilog, usage, group, hidden)` builds a
`CommandArg`: a field whose `variants` are words (e.g., `ship`, `move`) rather
than `-o`/`--option`/`<arg>` forms, and whose `spec` is a full nested spec tuple
with its own args/options/flags — and its own nested commands, to any depth.
Matching a command word hands the rest of the command line off to that command's
own `spec`/`usage`, the same way the top-level `spec`/`usage` governs everything
before it.

```nim
import std/strformat
import argumint

proc cmdAdd(spec: tuple, info: HookInfo) =
  for file in spec.files:
    echo fmt"Staging {file}"

let
  add = (files: args("<file>", help = "Files to stage"), help: help())

  spec = (
    add: command("add", add, action = cmdAdd, usage = "<file>...",
      help = "Add file contents to the index"),
    help: help()
  )

spec.parseOrQuit(prolog = "A tiny git-like CLI")
```

```console
$ ./git add a.txt b.txt
Staging a.txt
Staging b.txt

$ ./git --help
A tiny git-like CLI

Usage:
  git add
  git (-h | --help)

Commands:
  add         Add file contents to the index

Options:
  -h, --help  Display this help message
```

Like a top-level spec, a command's own `usage` is auto-generated from its
declared args if omitted — that's why the top-level `spec` above needs no
explicit `usage` at all: `add`/`(-h | --help)` are derived straight from its two
fields. `add --help` shows `add`'s own usage (`add <file>...`), generated the
same way, one level down.

### Usage Lines for a Command

A Command's nested spec compiles to its own FSM exactly like a top-level
spec, and that FSM is spliced into the parent's as a single `Command`
transition. Matching a command word hands the *entire* remaining command
line to the nested spec's own grammar — it never returns control to the
parent Usage Line afterward. That's why a Command's own args, options, and
flags always belong on the Command's *own* `usage`, never tacked onto the
same Usage Line as the command word itself:

```nim
let mineArgs = (
  x: arg("<x>"),
  y: arg("<y>"),
  moored: flag("--moored"),
  drifting: flag("--drifting")
)

let mine = (
  set: command("set", mineArgs),
  remove: command("remove", mineArgs)
)

let spec = (mine: command("mine", mine))
spec.parseOrQuit(
  usage = "mine (set | remove) <x> <y> [--moored | --drifting]"
)
```

```console
Error constructing spec: Error at (1:5): Nothing may follow a Command earlier in
  the same Usage Line -- a matched Command consumes every remaining argument, so
  anything after it can never be reached; use '(a | b)' for alternatives, or
  move it into the earlier Command's own usage
mine (set | remove) <x> <y> [--moored | --drifting]
     ^
```

`<x> <y> [--moored | --drifting]` belongs on `set`/`remove`'s own `usage`
instead — the parent's line stops at `(set | remove)`:

```nim
let mine = (
  set: command("set", mineArgs,
    usage = "<x> <y> [--moored | --drifting]"),
  remove: command("remove", mineArgs,
    usage = "<x> <y> [--moored | --drifting]")
)
```

This mirrors `examples/naval_fate.nim`'s `mine` command, whose `set`/
`remove` subcommands each declare their own `<x> <y> [--moored |
--drifting]` usage rather than sharing one line with `mine` itself.

### Before, Action, and After Hooks

Every `command()` (and the top-level `parse`/`parseOrQuit` itself) accepts
`before`/`action`/`after` hooks, each a `proc(spec: S, info: HookInfo)` (`spec`
is that level's own parsed tuple). Firing order across a whole matched chain,
root to leaf and back:

1. `before` fires once each level's own values are parsed, root-to-leaf — an
   outer command's `before` always runs, and sees its own values, before a
   nested one's does.
2. `action` fires exactly once, at the dynamic leaf — the deepest level actually
   matched *this invocation*, whether or not that's the deepest level the spec
   could reach. A command with no nested command matched is the leaf; one that
   routes into a subcommand is not, and its own `action` (if any) doesn't fire
   that time.
3. `after` fires leaf-to-root, guaranteed once a level's own `before` has
   completed — success or failure, via nested `try`/`finally`, so a deeper level
   failing still lets every already-entered ancestor's `after` run for cleanup.

```nim
var log: seq[string]

proc shipBefore(spec: tuple, info: HookInfo) = log.add "ship: before"
proc shipAfter(spec: tuple, info: HookInfo) = log.add "ship: after"
proc moveBefore(spec: tuple, info: HookInfo) = log.add "move: before"
proc moveAction(spec: tuple, info: HookInfo) = log.add "move: action (" & spec.name & ")"
proc moveAfter(spec: tuple, info: HookInfo) = log.add "move: after"

let
  move = (name: arg("<name>", help = "Ship to move"))
  ship = (
    move: command("move", move, before = moveBefore, action = moveAction,
      after = moveAfter, usage = "<name>", help = "Move a ship"),
  )
  spec = (
    ship: command("ship", ship, before = shipBefore, after = shipAfter,
      help = "Ship commands"),
  )

spec.parseOrQuit(usage = "ship", args = @["ship", "move", "Titanic"])
echo log
```

```console
$ ./naval_fate ship move Titanic
@["ship: before", "move: before", "move: action (Titanic)", "move: after", "ship: after"]
```

If `move`'s own `before` raised instead of `move`'s `action` ever running,
`ship`'s `after` still fires (`ship` already completed its own `before`, so it's
a fully "entered" level), even though `move`'s never does (it never finished
entering) — the log would end up `@["ship: before", "ship: after"]`, with the
exception still propagating to the caller afterward.

### `HookInfo`

Every hook receives `info: HookInfo`, a flat view of every `Arg` matched
during the *whole* invocation — not just that level's own spec — so an
outer router command's `before` can see what a nested command matched too.

- `info.matched: seq[Arg]` — every matched `Arg`, across every level
- `info.showsMessage: bool` — true if any matched `Arg` is a `MessageArg`
  (`help()`/`message()`/`version()`), i.e. this invocation is just going to
  print something and exit rather than reach a real `action`

```nim
proc connectToDatabase() = echo "Connecting to the database..."

proc appBefore(spec: tuple, info: HookInfo) =
  if not info.showsMessage:
    connectToDatabase()

let spec = (
  name: arg("<name>", help = "The name to call you"),
  help: help()
)

spec.parseOrQuit(usage = "<name>", before = appBefore)
```

`./hello --help` never connects to the database; `./hello Michael` does,
right before printing its greeting — `info.showsMessage` lets expensive
`before`-time setup skip itself for a request that's just going to print
help/version/a message and exit anyway.

### Passing Extra Context to Hooks

`command(variants, spec, options, ...)` — with an extra positional argument
between `spec` and `help` — gives every hook a second parameter,
`proc(spec: S, opts: O, info: HookInfo)`. `options` is arbitrary caller-chosen
context, not necessarily CLI-shaped: typically the enclosing spec (or a piece of
it) that a deeply nested command's hooks otherwise have no way to reach, since
`spec: S` alone is scoped to just that command's own tuple.

```nim
proc cmdAdd(spec: tuple, opts: tuple, info: HookInfo) =
  if opts.verbose:
    echo fmt"(verbose) staging {spec.files.len} file(s)"
  for file in spec.files:
    echo fmt"Staging {file}"

let
  verboseFlag = flag("--verbose", help = "Show extra output")
  globalOpts = (verbose: verboseFlag)
  add = (files: args("<file>", help = "Files to stage"), help: help())

  spec = (
    verbose: verboseFlag,
    add: command("add", add, globalOpts, action = cmdAdd,
      usage = "<file>...", help = "Add file contents to the index"),
    help: help()
  )

spec.parseOrQuit(prolog = "A tiny git-like CLI")
```

`--verbose add a.txt` prints the extra count line; `add a.txt` alone doesn't.
Note that `verboseFlag` is declared once and reused by reference in both
`spec.verbose` (so it's reachable/settable from the command line) and
`globalOpts.verbose` (so `cmdAdd` can read it) — since `Arg`s are `ref` objects,
this same trick works for sharing any single `Arg` (not just a whole tuple's
worth) across a spec and its nested commands, and is usually simpler than
threading a whole extra `options: O` tuple through just to share one flag's
value.
