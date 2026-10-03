# Tutorial

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

This tutorial builds `notes`, a small command-line notebook, one feature at a
time. By the end it has subcommands, typed and validated values, a usage line
written by hand, an environment variable fallback, and shell completion. The
finished program is
[`examples/notes.nim`](https://github.com/squattingmonk/argumint/blob/main/examples/notes.nim).

The first three steps are complete programs you can build with
`nim c notes.nim` and run as `./notes`. Later steps change parts of the third.
You need Nim 2.2.4 or later and argumint installed (see the
[README](https://github.com/squattingmonk/argumint#installation)).

## A First Spec

A program declares its command line as a tuple of `Arg`s called a **spec**.
Start with one: the text of the note to add.

```nim
import std/strutils
import argumint

let spec = (
  text: args("<text>", help = "The note's text"),
  help: help(),
)

spec.parseOrQuit(prolog = "A tiny note-taking CLI")

let file = open("notes.txt", fmAppend)
file.writeLine spec.text.get.join(" ")
file.close()
```

`args` declares a positional argument that takes one or more values. Its name,
`<text>`, is how it appears in usage and help. `help()` adds `-h`/`--help`.

`parseOrQuit` parses the command line against the spec. If that fails, or the
user asks for help, it prints a message and exits. Otherwise each `Arg` in the
spec now holds its value:

```console
$ ./notes buy milk
$ cat notes.txt
buy milk
```

An `Arg` converts to its value wherever Nim knows the type it wants, so most
of the time you can use `spec.text` as if it were a `seq[string]`. `join` is
generic, so Nim can't tell what to convert to; `get` asks for the value
explicitly. See [Getting Values Out](specs.md#getting-values-out).

You didn't write a usage string, so argumint wrote one from the spec. It's
shown in the help:

```console
$ ./notes --help
A tiny note-taking CLI

Usage:
  notes <text>...
  notes (-h | --help)

Arguments:
  <text>      The note's text

Options:
  -h, --help  Display this help message
```

`<text>...` means one or more values. `(-h | --help)` is a second way to call
the program.

## Options and Flags

Next, let the user tag a note, choose which file to write to, and ask for
more output:

```nim
import std/strutils
import argumint

let spec = (
  file: opt("-f, --file=<path>", default = "notes.txt",
            help = "Where notes are stored"),
  tags: opts("-t, --tag=<tag>", help = "Tag the note"),
  verbose: flag("-v, --verbose", help = "Show extra output"),
  text: args("<text>", help = "The note's text"),
  help: help(),
)

spec.parseOrQuit(prolog = "A tiny note-taking CLI")

var note = spec.text.get.join(" ")
for tag in spec.tags:
  note.add " #" & tag

let file = open(spec.file, fmAppend)
file.writeLine note
file.close()

if spec.verbose:
  echo "Added to ", spec.file, ": ", note
```

- `opt` declares an option that takes a value. Its type comes from `default`,
  so `spec.file` is a `string`.
- `opts` is an option that can be given more than once, collecting each value.
- `flag` is an option without a value. A plain flag is a `bool`.

The usage line grows an `[options]` placeholder, which stands for any of the
spec's options in any order:

```console
$ ./notes --help
A tiny note-taking CLI

Usage:
  notes [options] <text>...
  notes (-h | --help)

Arguments:
  <text>             The note's text

Options:
  -f, --file=<path>  Where notes are stored [default: "notes.txt"]
  -t, --tag=<tag>    Tag the note
  -v, --verbose      Show extra output
  -h, --help         Display this help message

$ ./notes -v buy milk --tag errands -t home
Added to notes.txt: buy milk #errands #home
```

Short flags combine (`-vf todo.txt`), and options can come before, after, or
between the positional values. Mistakes are reported with the usage:

```console
$ ./notes buy milk --tag
Parsing error:
  - missing value: option --tag requires a value

Usage:
  notes [options] <text>...
  notes (-h | --help)
```

See [Arguments and Options](args-and-options.md) and
[Flags](flags.md) for everything these can do.

## Subcommands

A notebook needs more than one action. Split `notes` into an `add` command and
a `list` command:

```nim
import std/[os, sequtils, strutils]
import argumint

let
  file = opt("-f, --file=<path>", default = "notes.txt",
             help = "Where notes are stored")
  verbose = flag("-v, --verbose", help = "Show extra output")

proc readNotes(): seq[string] =
  if fileExists(file): readFile(file).splitLines.filterIt(it.len > 0)
  else: @[]

proc addNote(spec: tuple, _: HookInfo) =
  var note = spec.text.get.join(" ")
  for tag in spec.tags:
    note.add " #" & tag
  let f = open(file, fmAppend)
  f.writeLine note
  f.close()
  if verbose:
    echo "Added to ", file, ": ", note

proc listNotes(spec: tuple, _: HookInfo) =
  for i, note in readNotes():
    if i == spec.limit: break
    echo i + 1, ". ", note

let
  add = (
    tags: opts("-t, --tag=<tag>", help = "Tag the note"),
    text: args("<text>", help = "The note's text"),
    help: help(),
  )
  list = (
    limit: opt("-n, --limit=<n>", default = 10,
               help = "Show at most this many notes"),
    help: help(),
  )
  spec = (
    file: file,
    verbose: verbose,
    add: command("add", add, action = addNote, help = "Add a note",
                 prolog = "Add a note to the notes file."),
    list: command("list", list, action = listNotes, help = "List notes",
                  prolog = "List the notes in the notes file."),
    help: help(),
  )

spec.parseOrQuit(prolog = "A tiny note-taking CLI")
```

`command` takes a word and a spec of its own. Everything after the word on the
command line is parsed against that spec. Its `action` runs once the whole
command line has parsed, and receives the command's own spec, so `addNote`
reads `spec.text` and `listNotes` reads `spec.limit`. The second parameter, a
`HookInfo`, describes everything the command line matched. These hooks don't
need it, so they name it `_`. See [HookInfo](commands.md#hookinfo).

`file` and `verbose` belong to the top-level spec, which the hooks can't see.
Declaring them first, outside any tuple, lets the hooks read them directly.
An `Arg` is a reference, so the copy in `spec` and the one the hooks read are
the same object.

A command's `help` is its one-line summary in the parent's help. Its `prolog`
heads the command's own help:

```console
$ ./notes --help
A tiny note-taking CLI

Usage:
  notes [options] (add | list)
  notes (-h | --help)

Commands:
  add                Add a note
  list               List notes

Options:
  -f, --file=<path>  Where notes are stored [default: "notes.txt"]
  -v, --verbose      Show extra output
  -h, --help         Display this help message

$ ./notes list --help
List the notes in the notes file.

Usage:
  notes list [options]
  notes list (-h | --help)

Options:
  -n, --limit=<n>  Show at most this many notes [default: 10]
  -h, --help       Display this help message

$ ./notes add buy milk -t errands
$ ./notes -v add call mum
Added to notes.txt: call mum
$ ./notes add walk the dog
$ ./notes list -n 2
1. buy milk #errands
2. call mum
```

Options of the top-level spec, like `-v`, go before the command word. A
command's own options go after it.

`--limit` has an `int` default, so its value is converted for you, and a value
that doesn't convert is an error:

```console
$ ./notes list -n two
Parsing error:
  - expected int for -n but got "two"

Usage:
  notes list [options]
  notes list (-h | --help)
```

Commands nest to any depth, and have `before` and `after` hooks as well. See
[Commands](commands.md#commands).

## Validating Values

A value can have the right type and still be wrong. A **validator** checks it
after conversion. Give `list` an `--order` option that accepts only two
words, and cap `--limit`:

```nim
  list = (
    order: opt("-o, --order=<order>", default = "oldest",
               validator = choice(["oldest", "newest"]),
               help = "Which notes come first"),
    limit: opt("-n, --limit=<n>", default = 10, validator = range(1..100),
               help = "Show at most this many notes"),
    help: help(),
  )
```

Then number each note by its place in the file, so the numbers stay the same
whichever order they're shown in:

```nim
proc listNotes(spec: tuple, _: HookInfo) =
  let notes = readNotes()
  var ids = toSeq(1..notes.len)
  if spec.order == "newest":
    ids.reverse()
  for id in ids[0 ..< min(spec.limit, ids.len)]:
    echo id, ". ", notes[id - 1]
```

`reverse` comes from `std/algorithm`, so add it to the imports. Help now
lists what each option accepts, and a bad value is caught before `listNotes`
runs:

```console
$ ./notes list --help
List the notes in the notes file.

Usage:
  notes list [options]
  notes list (-h | --help)

Options:
  -o, --order=<order>  Which notes come first [choices: "oldest", "newest";
                       default: "oldest"]
  -n, --limit=<n>      Show at most this many notes [range: 1..100; default: 10]
  -h, --help           Display this help message

$ ./notes list -o newest -n 2
3. walk the dog
2. call mum
$ ./notes list --order size
Validation error:
  - for --order, got "size" but expected one of "oldest", "newest"

Usage:
  notes list [options]
  notes list (-h | --help)
$ ./notes list -n 0
Validation error:
  - for -n, got 0 but expected a value in 1..100

Usage:
  notes list [options]
  notes list (-h | --help)
```

See [Validating Values](args-and-options.md#validating-values) for the other
validators and how to write your own.

## Writing a Usage Line

So far argumint has written every usage line. Add a `remove` command that
takes either some note numbers or `--all`, but not both. That rule can't be
worked out from the spec, so write it in the command's `usage`. Add two procs
after `readNotes`:

```nim
proc writeNotes(notes: seq[string]) =
  writeFile(file, notes.mapIt(it & "\n").join)

proc removeNotes(spec: tuple, _: HookInfo) =
  var notes = readNotes()
  if spec.all:
    notes = @[]
  else:
    for id in spec.ids.get.sorted(Descending):
      if id notin 1..notes.len:
        quit "No note " & $id, 1
      notes.delete(id - 1)
  writeNotes(notes)
```

```nim
  remove = (
    ids: args[int]("<id>", help = "Number of a note to remove"),
    all: flag("--all", help = "Remove every note"),
    help: help(),
  )
```

```nim
    remove: command("remove", remove, action = removeNotes,
                    usage = "(<id>... | --all)",
                    help = "Remove notes",
                    prolog = "Remove notes by number, or all of them."),
```

`args[int]` makes each `<id>` an `int`; there's no `default` to infer the type
from. In the usage, `( ... | ... )` means one of the alternatives. You only
have to write the lines you care about: argumint still adds the
`(-h | --help)` line, since nothing you wrote mentions it.

```console
$ ./notes remove --help
Remove notes by number, or all of them.

Usage:
  notes remove (<id>... | --all)
  notes remove (-h | --help)

Arguments:
  <id>        Number of a note to remove

Options:
  --all       Remove every note
  -h, --help  Display this help message

$ ./notes remove 1 3
$ ./notes list
1. call mum
$ ./notes remove 1 --all
Parsing error:
  - unexpected flag: --all

Usage:
  notes remove (<id>... | --all)
  notes remove (-h | --help)
```

The usage string is what argumint parses with: it compiles into a state
machine that the command line is matched against. Brackets, alternatives,
repetition and `[options]` can be combined freely. See
[Usage Strings](usage-strings.md) for the full grammar.

## Defaults from the Environment

A user who keeps notes somewhere else shouldn't have to type `--file` every
time. Give `--file` an environment variable to fall back on:

```nim
  file = opt("-f, --file=<path>", default = "notes.txt", env = "NOTES_FILE",
             help = "Where notes are stored")
```

A value on the command line wins over the environment variable, which wins over
the `default`:

```console
$ export NOTES_FILE=work.txt
$ ./notes -v add standup
Added to work.txt: standup
$ ./notes -v -f home.txt add water plants
Added to home.txt: water plants
```

Help shows where else a value can come from:

```console
$ ./notes --help
...
Options:
  -f, --file=<path>  Where notes are stored [default: "notes.txt"; env:
                     NOTES_FILE]
...
```

Values can also come from a config file. See
[Value Precedence](precedence.md#value-precedence).

## Shell Completion

argumint can complete commands, options, and validated values in bash, zsh,
and fish. Completion runs your program to ask what comes next, so it always
agrees with the parser. Add a command that prints the script for a shell:

```nim
var cli: Spec

proc printCompletion(spec: tuple, _: HookInfo) =
  echo cli.completionScript(parseEnum[Shell](spec.shell), "notes")
```

```nim
  completion = (
    shell: arg("<shell>", validator = choice(["bash", "zsh", "fish"]),
               help = "Shell to print a script for"),
    help: help(),
  )
```

```nim
    completion: command("completion", completion, action = printCompletion,
                        help = "Print a shell completion script",
                        prolog = "Print a completion script for a shell."),
```

`completionScript` needs the built `Spec`, not the tuple, so build it with
`newSpec` and keep it in `cli`. Declare `cli` before the hooks, as with `file`,
and replace the last line of the program:

```nim
cli = newSpec(spec, prolog = "A tiny note-taking CLI")
cli.parseOrQuit()
```

With `notes` on your `PATH`, load the script in your shell:

```console
$ source <(notes completion bash)    # bash or zsh
$ notes completion fish | source     # fish
```

Pressing Tab now completes `notes l` to `notes list`, and offers `newest`
and `oldest` as values for `notes list --order`. The choices come from the
`choice` validator, so they can't drift out of sync with what `notes` accepts.
See [Shell Completion](completion.md#shell-completion).

## Where to Go Next

The finished program is
[`examples/notes.nim`](https://github.com/squattingmonk/argumint/blob/main/examples/notes.nim).
From here:

- [Specs and Values](specs.md#basics) covers reading and setting values,
  `parse` for programs that handle their own errors, and parsing more than
  once.
- [Help and Messages](help.md#displaying-help) covers help layout, colour,
  and `--version`.
- [Error Handling](errors.md#error-handling) covers catching parse errors
  yourself.
