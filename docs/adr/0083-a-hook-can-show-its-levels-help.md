# A hook can show its Level's help

[ADR 0080](0080-1x-freezes-the-public-modules-and-the-usage-grammar.md)
freezes the facade for 1.x. This adds a name to it, so a minor release can
ship it.

Many CLIs show a command's help when the command is run with nothing to act
on, like a bare `nasher config` (issue #318). A hook had no way to do that.
It had to import `argumint/help`, call `genHelp(info.here.spec,
info.here.command, formatter)` and quit. That named the formatter a second
time, though the Level's `help()` flag already holds it. It also skipped the
plain/styled split that `HelpArg.action` makes (ADR 0059).

A `HelpError` raised from a hook already reaches `parseOrQuit`, which prints
it to stdout and exits 0, and a `parse*` caller receives it like any other.
So a hook only needs a way to raise the right one.

## Decision

1. **`showHelp(info: HookInfo) {.noreturn.}`** is defined in
   `argumint/help` beside `HelpArg.action` and exported from the facade, so
   `import argumint` is enough. It always raises `HelpError` for
   `info.here`. Because it is `{.noreturn.}`, it can end a branch of an
   `if` or `case` expression.
2. **It delegates to the Level's Help flag.** It calls that flag's
   `action(info)`, so the result is the same as the user typing the flag at
   that Level: the same formatter, the same `msg` and `styledMsg`. A
   `HelpArg` subtype that overrides `action` is honored too.
3. **The first-declared Help flag wins.** A Spec may register several Help
   flags, each with its own formatter. `showHelp` uses the first in
   declaration order.
4. **With no Help flag, it falls back to `formatColumn`.** It makes the same
   plain/styled split `HelpArg.action` does, through one shared helper. A
   Spec with no Help flag isn't malformed, so this is not a `SpecDefect`.
   The Level's help is still what the user should see. Column Style is
   what `help()` uses by default.
5. **A Help flag whose `action` returns is a `Defect`.** A `HelpArg` subtype
   could override `action` and forget to raise. `showHelp` raises an
   `AssertionDefect` then, so a `{.noreturn.}` proc can't return.

## Considered options

- **A `formatter` parameter**: rejected for now. The Level's flag already
  holds the formatter, and repeating it is the problem this solves. It can
  be added later with a default if a real case comes up.
- **`SpecDefect` with no Help flag**: rejected. Nothing about the Spec is
  wrong, and a program that leaves out `--help` can still want a bare
  command to show its help.
- **Returning the help text instead of raising**: rejected. A hook would
  then have to print it and quit itself, which is what it did before, and
  `parse*` callers would no longer receive a `HelpError`.
- **The last-declared Help flag, or one matched by variant**: rejected.
  Declaration order is predictable, and no variant is matched when a hook
  shows help on its own.

## Consequences

- One call in a hook shows the same help `--help` would, styled or not.
- `HelpArg.action` and the fallback share one plain/styled helper, so they
  can't drift apart.
- A `HelpArg` subtype must raise from `action`. This was already true for
  `--help` to stop the parse. `showHelp` now checks it.
