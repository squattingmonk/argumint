# `specTuple` builds a Spec Tuple and flattens a base into it

[ADR 0080](0080-1x-freezes-the-public-modules-and-the-usage-grammar.md)
freezes the facade for 1.x. This adds a name to it, so a minor release can
ship it. Once it ships, its name, its merge and its field order are frozen
too.

Many CLIs share a set of global options across their commands (issue #317).
In argumint an option belongs to the spec that declares it, so a program had
two ways to share one. It could nest the shared tuple in each spec
(`global: global`), so a field reads `convert.global.verbose`, and leaving
the field out of one spec drops the options there with no error. Or it
could copy the fields by hand (`version: global.version, ...`), which
silently misses any field later added to `global`. That happens, for
example, when one command needs a different `help` flag.

## Decision

1. **One macro, `specTuple`, in the facade.** `specTuple:` takes one
   `name: expr` field per line, with no commas, and gives the tuple literal
   those fields describe. `specTuple(base):` also takes a base tuple. Both
   forms build a Spec Tuple, so they share a name, and the plain form lets
   a whole program use one style.
2. **A base is flattened, one level deep.** `specTuple(base)` gives a flat
   tuple of every field of `base` plus the body's fields, so a field reads
   `convert.verbose`. The copied fields are the base's own values. For Args
   these are the same refs, so after parsing, `convert.verbose` and
   `global.verbose` read the same value. A field of `base` that is itself a
   tuple stays nested. The base is evaluated once.
3. **A body field named like a base field replaces it.** This is how one
   command swaps a shared Arg, such as a `help` flag with its own
   formatter, and the merge keeps every other base field, including ones
   added later.
4. **Field order follows what changed.** The order of a Spec Tuple's fields
   sets the order of its Args in help, and the order their groups first
   appear.
   - The body's fields come first, in body order. These are the command's
     own Args.
   - The base's fields come next, in base order.
   - A replacement with the same Nim type as the base field takes that
     field's slot. It is the shared Arg with different settings, so it stays
     where the other commands built on the same base show it: `--help` sits
     in the same place in every command's help.
   - A replacement of a different type (`ValueArg[int]` to
     `ValueArg[string]`, or a `ValueArg` to a `ValuesArg`) is a different
     Arg that reuses the name, so it comes first with the body's fields.
5. **Mistakes are compile-time errors at the offending node.** These are a
   base that isn't a tuple with named fields, a body line that isn't
   `name: expr`, a field named twice in the body, and more than one
   argument before the body. An error in a field's expression still points
   at that field's line.

## Considered options

- **The name `spec`**: rejected. A module-level variable named `spec`, or a
  hook's `spec: tuple` parameter, hides an imported macro of that name
  throughout its scope, and nearly every program has one of those.
- **The name `mergeFields`** (the review sketch): rejected. It names only
  the base form, and `specTuple` says what both forms build.
- **Two overloaded macros**, one per form: not possible. Nim typechecks the
  untyped body against the typed-base overload while it resolves the call,
  and fails on the first field name. See `docs/gotchas.md`.
- **Nesting the base** (`convert.global.verbose`): rejected. It is what
  programs already did by hand, and it doesn't let one command replace a
  single shared Arg.
- **Deep merging nested tuples**: rejected for now. A tuple field of a Spec
  Tuple is unusual, and flattening it would change field names in ways the
  reader can't see.
- **Base fields first**: rejected. A command's own Args are what its help
  is about, so they lead.
- **Every replacement keeps the base field's slot**: rejected. A replacement
  of a different type is a new Arg, not the shared one with new settings.
- **Options inherited from a parent spec**, like cobra's persistent flags:
  rejected. `command()` builds its Spec before any parent exists, and one
  command can be grafted under two parents with different options.
- **Object bases**: out of scope. Only tuples are Spec Tuples.

## Consequences

- Sharing a group of options is one call per spec, and a field added to the
  base reaches every spec built from it.
- A merged tuple can itself be a base, so a chain of commands can add
  options level by level.
- Help order depends on Nim types as well as field names. Changing a
  replacement's type moves it in help.
- The guide still teaches plain tuple literals. Making `specTuple` the form
  it teaches everywhere is a separate decision.
