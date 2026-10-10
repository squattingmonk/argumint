# File completion can be limited to names matching patterns

Amends ADR 0066 (point 5, the directive line) and ADR 0071 (point 3, the
`Offer`).

A value that takes a TOML file still offered every file, so the user had
to pick the right one out of the whole directory. Filtering inside the
program, by returning the matching paths as candidates, would lose each
shell's own path handling: escaping, `~`, descending into directories.
So the program names the patterns, and the shell does the matching.

## Decision

1. **`files(patterns)` and `offer(..., patterns = ...)`.** `files("*.toml",
   "*.ini")` is a fixed Completer offering directories and the files that
   match; it fills nothing. `files()` is the same as `Files`. Both `offer`
   overloads take `patterns: openArray[string] = []`, so a completer can
   offer values beside filtered files. `Offer` holds the patterns in a
   private field. Patterns with `paths = Dirs` or `None`, or a pattern
   holding a tab or newline, are a Defect.
2. **The patterns ride on the directive line**, tab-separated after it:
   `:files\t*.toml\t*.ini`. `:files` alone, `:dirs` and `:` are unchanged,
   so a CLI using no patterns prints exactly what it did.
3. **Combining positions.** Unfiltered `Files` beats filtered `Files`,
   which beats `Dirs`, then `None`. Two filtered positions take the union
   of their patterns, in the order first seen, without duplicates. This
   holds wherever ADR 0066 combined paths: across frontier positions, and
   across options pending a value.
4. **A portable subset, matched on the name.** A pattern may use `*`, `?`,
   `[...]` and `[!...]`, which every shell reads alike, and is matched
   against the file's name, not its directory. Matching is case-sensitive.
   argumint doesn't validate the subset; the guide states it.
5. **Strict.** Directories are always offered, so the user can descend into
   them, but when no file matches, no other file is offered. Hidden files
   follow each shell's own rules.
6. **Each script matches its own way.** bash filters `compgen -f`'s output
   with `[[ name == pattern ]]`, keeping directories. zsh calls
   `_path_files -g` with the patterns joined by spaces, then
   `_path_files -/`: `_files -g` falls back to every file when none
   matches, and a space inside a pattern is written `[[:blank:]]`. fish's
   `string match` globs have no `[...]`, so the script turns each pattern
   into an anchored regex and filters `__fish_complete_path`'s output.

## Considered options

- **Extensions instead of globs** (`files(".toml")`), as Cobra,
  argcomplete and carapace take: rejected, since globs also cover names
  like `Makefile*` or `x[0-9].cfg`, and an extension is a glob with a
  `*` in front.
- **Case-insensitive matching**, as Cobra's bash adapter gets from
  bash-completion's `_filedir` (lower case or all capitals): rejected.
  Each shell would need its own option for it, and a CLI wanting both
  cases lists both, `files("*.toml", "*.TOML")`.
- **A `Paths` type holding the kind and the patterns**: rejected. It
  breaks every `paths = Files` already written, for a field only `Files`
  uses.
- **Falling back to every file when none matches**, as zsh's `_files -g`
  does: rejected, since the shells would disagree, and an unrelated file is
  rarely the right answer.
- **Filtering in the program**, as clap does: rejected above.

## Consequences

A third-party adapter reading the directive must split it on tabs, or it
sees `:files\t*.toml` as an unknown directive and offers no paths.

A pattern outside the subset, such as zsh's `**/` or bash's extglob
`@(a|b)`, may work in one shell and not another. argumint passes it
through unchecked.
