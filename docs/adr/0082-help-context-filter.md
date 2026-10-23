# A Help Context can be filtered to the Args a predicate keeps

Amends [ADR 0075](0075-help-formatters-build-on-the-help-frame.md), whose
toolkit [ADR 0080](0080-1x-freezes-the-public-modules-and-the-usage-grammar.md)
freezes for 1.x. This is an addition, so a minor release can ship it.

An Arg is one ref object, so a Spec that reuses another command's Args
shows all of them in its help. `hidden = true` can't leave them out of just
one Spec: it hides the Arg in every Spec that holds it, and ADR 0065 also
keeps it out of completion. nasher's `config` command (issue #316) uses the
build commands' option tuples as its keys, so `config --gffFormat=nwnt`
checks the value the way `pack --gffFormat=nwnt` does. That put about 50
key options into `config --help`, each already documented on its own
command. The only workaround was a custom Help Formatter of about 35 lines
that re-implemented Column Style, because `frame` takes no filter and
`columnLines` and `variantsColWidth` are private.

Column Style also sized its variants column from `spec.args`, hidden Args
included, so a hidden Arg with long Variants widened the column for the
Args shown.

## Decision

1. **`ctx.filter(keep: proc (arg: Arg): bool): HelpContext`** is public in
   `argumint/help`. It returns a copy of `ctx` that shows only the Args
   `keep` accepts. A second `filter` ANDs with the first, and the context
   it was called on is unchanged. A nil `keep` keeps every Arg.
2. **Everything that lists Args honors it.** `groups` skips an Arg that is
   hidden or that the filter drops, and skips a group left with none. So
   `frame`, `formatColumn` and `formatParagraph` honor it too. A
   user-defined group's kind (ADR 0079) comes from its first Arg that is
   both shown and kept.
3. **It is help only.** Parsing, completion and the usage lines are
   unchanged. That's the difference from `hidden`, which means "not
   advertised anywhere".
4. **Column Style's variants column fits the Args `groups` yields.** It no
   longer counts hidden Args or Args a filter drops. Output for a Spec with
   no hidden Args is unchanged.

A formatter that leaves some Args out is then one line:

```nim
proc formatConfig(ctx: HelpContext): string =
  formatColumn(ctx.filter((arg) => arg notin configKeyArgs))
```

(`=>` is from `std/sugar`.)

The name follows `std/sequtils.filter`, which also returns a new value
narrowed by a predicate. `ctx.filter(...)` resolves beside it without
ambiguity.

## Considered options

- **Hiding an Arg in one Spec only**, with a wrapper that marks a nested
  tuple's Args hidden: rejected. By ADR 0065, hidden Args don't complete,
  so `config`'s keys would stop completing. It also puts a help concern
  into spec construction.
- **A filter parameter on `frame`**: rejected. It helps only formatters
  built on the frame, and `formatColumn` would still need a factory to
  size its column from the filtered Args.
- **Exporting `columnLines` and a heading helper**: rejected. The custom
  formatter gets shorter but is still needed, and it undoes part of ADR
  0075's decision 5.
- **`without(args: openArray[Arg])`**: rejected. It fits this case
  exactly, but a predicate can also filter by group or by anything else.

## Consequences

- A formatter can drop Args from help with one `filter` call and keep the
  built-in layout.
- A hidden Arg no longer widens Column Style's variants column. Help for a
  Spec with a long hidden Variant can get narrower.
- `HelpContext` gains a private field. Formatters only ever receive a
  context, so none of them can tell.
