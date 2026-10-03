# This example is the program built step by step in docs/guide/tutorial.md: a
# small notebook with `add`/`list`/`remove` subcommands, validated options, a
# hand-written usage line for `remove`, an environment variable fallback for
# `--file`, and a `completion` command that prints a shell completion script.

import std/[algorithm, os, sequtils, strutils]
import argumint

let
  file = opt("-f, --file=<path>", default = "notes.txt", env = "NOTES_FILE",
             help = "Where notes are stored")
  verbose = flag("-v, --verbose", help = "Show extra output")

var cli: Spec

proc readNotes(): seq[string] =
  if fileExists(file): readFile(file).splitLines.filterIt(it.len > 0)
  else: @[]

proc writeNotes(notes: seq[string]) =
  writeFile(file, notes.mapIt(it & "\n").join)

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
  let notes = readNotes()
  var ids = toSeq(1..notes.len)
  if spec.order == "newest":
    ids.reverse()
  for id in ids[0 ..< min(spec.limit, ids.len)]:
    echo id, ". ", notes[id - 1]

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

proc printCompletion(spec: tuple, _: HookInfo) =
  echo cli.completionScript(parseEnum[Shell](spec.shell), "notes")

let
  add = (
    tags: opts("-t, --tag=<tag>", help = "Tag the note"),
    text: args("<text>", help = "The note's text"),
    help: help(),
  )
  list = (
    order: opt("-o, --order=<order>", default = "oldest",
               validator = choice(["oldest", "newest"]),
               help = "Which notes come first"),
    limit: opt("-n, --limit=<n>", default = 10, validator = range(1..100),
               help = "Show at most this many notes"),
    help: help(),
  )
  remove = (
    ids: args[int]("<id>", help = "Number of a note to remove"),
    all: flag("--all", help = "Remove every note"),
    help: help(),
  )
  completion = (
    shell: arg("<shell>", validator = choice(["bash", "zsh", "fish"]),
               help = "Shell to print a script for"),
    help: help(),
  )
  spec = (
    file: file,
    verbose: verbose,
    add: command("add", add, action = addNote, help = "Add a note",
                 prolog = "Add a note to the notes file."),
    list: command("list", list, action = listNotes, help = "List notes",
                  prolog = "List the notes in the notes file."),
    remove: command("remove", remove, action = removeNotes,
                    usage = "(<id>... | --all)",
                    help = "Remove notes",
                    prolog = "Remove notes by number, or all of them."),
    completion: command("completion", completion, action = printCompletion,
                        help = "Print a shell completion script",
                        prolog = "Print a completion script for a shell."),
    help: help(),
  )

cli = newSpec(spec, prolog = "A tiny note-taking CLI")
cli.parseOrQuit()
