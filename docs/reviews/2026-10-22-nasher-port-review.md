# nasher port review, 2026-10-22

The fourth review, and the first from outside the code: what porting a real,
mid-sized CLI to argumint showed about its API. nasher, a Neverwinter Nights
build tool, has eleven commands, a convert → compile → pack → install →
launch pipeline whose steps share their options, and a `config` command
whose keys are the other commands' options. Its command line was rewritten
with argumint as a throwaway sketch that parses and reports but builds
nothing. It continues the
[simplification review](2026-10-14-simplification-review.md)'s lettering at
Y. The next review,
[2026-10-29](2026-10-29-2-0-surface-review.md), continues the lettering at
AC.

The parse-error bugs the port found are already fixed (#308–#310, PRs #311
and #314, ADR 0081), and two help gaps are filed (#315, #316). This review
covers what's left: the places where writing the sketch took a workaround.
Each was settled as an argumint change, a docs change, a nasher change, or
dropped.

Reviewed at `658b5bd`. Vocabulary: domain terms per
[`GLOSSARY.md`](../../GLOSSARY.md). Line numbers are as of the review date.

## Status

| | Candidate | Strength | Status |
|---|---|---|---|
| [Y](#y--a-helper-that-merges-spec-tuples) | A helper that merges spec tuples | Strong | Shipped: #317, PR #337, `1e76888` |
| [Z](#z--a-hook-can-show-its-levels-help) | A hook can show its Level's help | Worth exploring | Shipped: #318, PR #335, `0bb6fc6` |
| [AA](#aa--an-arg-reached-twice-in-one-spec-is-registered-once) | An Arg reached twice in one spec is registered once | Strong | Shipped: #319, PR #328, `59a8cb3` |
| [AB](#ab--an-arg-can-write-its-value-back-as-strings) | An Arg can write its value back as strings | Speculative | Dropped: #320 |

**Recommendation:** Y and AA first. Both make the option-tuple idiom the
guide teaches work at scale. Y removes copying a shared tuple into every
spec by hand, and AA lets nested tuples overlap.

## What worked

Most of the port was direct, and the guide was enough to write it without
reading argumint's source:

- Nesting each pipeline step's option tuple in the next declared every
  option once, and `group` reproduced nasher's help sections.
- Sharing an Arg between specs let one tuple of global options, and one
  spec, serve several commands. `serve`, `play` and `test` share a spec,
  and the hook tells them apart by `info.here.command`.
- Flag Operations replaced groups of independent booleans: `--yes/--no/
  --default` became one value, as did `--quiet/--verbose/--debug`.
- Enum and `range` types gave choices in help, validation and did-you-mean,
  replacing nasher's prose ranges. `env = "NWN_HOME"` replaced a prose
  default, and `seenBy` let `config` store only values typed on the command
  line.
- `config`'s keys are the build commands' own option tuples, so a bad value
  is rejected the same way in both places.

## Candidates

### Y — A helper that merges spec tuples

**Strong.** Files: `src/argumint.nim`, `docs/guide/commands.md` ("Passing
Extra Context to Hooks").

**Problem.** nasher accepts its global options after any command. In
argumint, an option belongs to the spec that declares it, so the sketch put
`global: global` in all eleven command specs. Leaving it out of one drops
the global options there with no error. When `config` needed a different
help flag, the sketch rebuilt the global tuple field by field (`version:
global.version, answer: global.answer, ...`), which silently misses any
field later added to `global`. #316 doesn't remove that need: its proposal
still puts a formatter on `config`'s own help flag.

Options inherited from a parent spec (cobra's "persistent flags") were
rejected. `command()` builds its Spec and FSM before any parent exists, and
one command can be grafted under two parents with different options.
Inheritance would break that composability.

**Solution.** Ship a macro that builds a tuple from another plus extra
fields, replacing any field the extra fields name:

```nim
let
  convert = mergeFields(global):
    branch: opt("--branch=<branch>")
  config = mergeFields(global):
    help: help(formatter = formatConfig)
```

It flattens, so `convert.verbose` works where nesting gives
`convert.global.verbose`. A version written for therapist works unchanged
against argumint (checked with a scratch compile): the merged tuple holds
the same Arg refs, and `parse` writes through them. Its name and module are
open. The guide would show it where it now shows a nested `global` tuple.

**Wins.** Copying the global options into a spec is one call, and swapping
one of them can't miss a field added later.

### Z — A hook can show its Level's help

**Worth exploring.** Files: `help.nim:326` (`genHelp`), `help.nim:334`
(`HelpArg.action`), `backend.nim:110` (`HookInfo`).

**Problem.** Bare `nasher config` shows its help, as many CLIs do when a
command has nothing to act on. A hook has no way to do that. The sketch
imports `argumint/help`, calls `genHelp(info.here.spec, info.here.command,
formatConfig)`, and quits. It names the formatter a second time, though the
Level's `help()` flag already holds it, and it skips the styled/plain split
that `HelpArg.action` makes.

**Solution.** A proc taking `HookInfo` that renders `info.here`'s help the
way that Level's help flag would, with its formatter and styling. Raising
`HelpError` from a hook already reaches `parseOrQuit`, which prints it and
exits successfully (checked with a scratch compile), so the proc can raise
the same error `HelpArg.action` builds. Open: its name, and what it does
for a Level with no help flag (fall back to `formatColumn`, or raise
`SpecDefect`).

**Wins.** One call, and the help matches `--help` exactly.

### AA — An Arg reached twice in one spec is registered once

**Strong.** Files: `specbuild.nim:20–50` (`addArg`), `specbuild.nim:80`
(`gatherArgs`).

**Problem.** `config`'s keys combine several commands' option tuples, and
those tuples overlap: two of them nest the same `branch` and `installDir`.
Putting one Arg in a spec twice, directly or through nested tuples, raises
`SpecDefect: option --branch already defined` when the spec is built
(checked with a scratch compile). The check compares names, so it can't
tell one Arg reached twice from two Args with the same name, and the
message reads as the second case. The sketch worked around it by leaving
the overlapping tuples out by hand.

**Solution.** Register an Arg once, however many times the spec tuple
reaches it, so it appears once in `args`, `groups` and help. A different
Arg with a name already taken still raises. `gatherArgs` can skip an Arg
it has already gathered. This only accepts specs that raised before, and
ADR 0080 doesn't freeze spec-construction errors.

**Wins.** Overlapping option tuples, which Y makes easier to build, combine
without the author tracking which Args each one contains.

### AB — An Arg can write its value back as strings

**Speculative.** Files: `backend.nim:435` (`defaultStr`),
`argtypes.nim:402`.

**Problem.** `nasher config --gffFormat=nwnt` stores the value in a config
file, so the program has to turn each value back into text. The sketch
walks the spec with `fieldPairs` and branches on the Arg's type: `$` for a
single value, `join(";")` for a `ValuesArg`. A Flag or a Custom Arg would
need more cases. argumint already renders a default for help
(`defaultStr`) but not the current value.

**Solution.** A method returning an Arg's current value as the strings
`parse` would accept back, one per element. A Flag gives its Variant names,
matching how a config file or env variable supplies a Flag (ADR 0005). A
Custom Arg overrides it, and ADR 0080 allows adding a method with a
default. The walk over the spec and the config-file writer stay in user
code: file formats vary too much for argumint to write them.

**Wins.** A `config set` command needs no per-type code.

**Dropped** (#320): the method would save a couple of lines of user code
at the cost of a method every Custom Arg should override. See
[`.out-of-scope/arg-value-writeback.md`](../../.out-of-scope/arg-value-writeback.md).

## Docs

- `docs/guide/flags.md`: a recipe for a default-true flag that can be set
  both ways, `flag(default = true, ops = "--x=true, --no-x=false")`. The
  port wrote out each `flagOp` by hand. Filed as #321.

## Considered and dropped

- **A `--[no-]x` Variant shorthand.** It saves little over the ops string
  above, and would add a form to the Variant grammar. nasher moves from
  `--x:false` to `--no-x` instead.
- **Re-flowing each piece of a concatenated prolog.** Joining an indented
  `"""` piece to an unindented one leaves no shared indent to remove, so
  the indented lines print as they are. ADR 0054 already explains this, and
  dedenting each paragraph would break indented examples.
- **"At least one of these options" in usage.** Listing each option as an
  alternative already says it. A shorter form would change the usage
  grammar, which ADR 0080 freezes, and the check is two lines in the
  action, fewer with Z.
- **Explaining `unexpected command` when options precede a subcommand.**
  The usage block printed with the error shows the separate lines.
- **Wrapping long Variants in the names column.** `maxVariantsWidth`
  already handles it.
- **Case-insensitive option names.** No opt-in setting. Did-you-mean
  covers a port's move to exact names.
- **Mapping nasher's `user.cfg` files onto Config Sources.** It needs no
  argumint change: a global and a local `iniConfigSource`, last one
  winning, already give nasher's layering. A Config Key is set per Arg, so
  each option names its own rather than argumint deriving one from its
  name. A Flag's value in a config file is one of its Variant names (ADR
  0005), and per-target settings from `nasher.cfg` depend on the parsed
  target, so nasher applies them in a `before` hook.
- **Splitting one command-line value on a delimiter.** A list option takes
  repeated values, and a repeated INI key gives several.
