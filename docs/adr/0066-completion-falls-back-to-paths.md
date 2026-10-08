# Completion falls back to paths

Amends ADRs 0012, 0022 and 0030.

When completion had no candidates for a word, the shell offered nothing.
None of the three generated scripts could fall back to file names: bash
registered no `-o default`, fish passed `-f`, and zsh only `compadd`ed the
candidates. So `<file>` completed nothing, though file names are what users
expect for most free-form values. The script alone can't decide when to add
them: it sees only whether the list is empty, and only argumint knows
whether the word is a free-form value or, say, a word past the last
positional.

## Decision

1. **Files by default.** Wherever a free-form value can go (a positional,
   or an `opt`/`opts`'s value, with no enumerable values), Tab offers file
   names, whatever the value's type. Detecting a string value would need
   another method on `Arg` for a default.
2. **Per-Arg override.** `arg`, `args`, `opt` and `opts` take
   `complete = PathCompletion.Files | Dirs | None`, defaulting to `Files`,
   stored on `Arg.complete`. `Files` also offers directories to descend
   into; no shell can usefully complete "files but not directories", so
   it's an enum, not a set. `PathCompletion` is `{.pure.}` with capitalised
   values, so `complete = Dirs` and `complete = None` compile unqualified
   beside `std/files`, `std/dirs` and `std/options`. Flags and commands
   take no value, so they don't take `complete`. `Files` is the zero
   value, so a custom Arg kind gets the default with no code.
3. **`choice` values replace the fallback.** An Arg whose `completions()`
   is non-empty offers only those values, since a `choice` rejects anything
   else. A hidden positional offers no paths, as ADR 0065 keeps it out of
   completion.
4. **Options are still offered beside paths.** `cat <Tab>` offers `-n`,
   `--help` and the files.
5. **Wire format.** `__complete`'s output always ends with one directive
   line: `:files`, `:dirs` or `:`. Every script strips the last line
   unconditionally, the same "always present" rule as ADR 0022's tab. When
   several frontier positions disagree, `Files` beats `Dirs`, which beats
   `None`. An empty result is `:` alone, which also ends the stray blank
   line an empty result used to print.
6. **`completeArgs` and `CompletionCandidate` are no longer exported** from
   `argumint`; `completeArgs` becomes `resolveCompletion`, returning the
   paths too, in `argumint/completion`. The documented wire format, through
   `parse`'s `CompletionError`, is the only interface. An adapter for another shell
   can read it as the three generated scripts do; re-exporting later is
   non-breaking.

## Considered options

- **The script falls back whenever the list is empty**: rejected, since it
  offers files after the last positional and none beside options at a
  positional.
- **A set of path kinds**: rejected, since no shell completes files without
  the directories leading to them.
- **Lowercase `files`/`dirs`/`none`**: rejected, since they collide with
  the `std/files` and `std/dirs` module names and `std/options.none`.

## Consequences

Breaking: `completeArgs` and `CompletionCandidate` are gone from the
facade, and `__complete`'s output gains a last line that any third-party
adapter must strip. Out of scope: extension filters and a custom completer
proc.
