# `eachArg` visits the Args `newSpec` registers

A program that does something with every Arg in its Spec Tuple, such as
writing out the values given on the command line, had to recurse through
`fieldPairs` itself. A hand-written recursion reaches an Arg once for each
place the tuple nests it, while `newSpec` registers it once (#319), so each
caller repeated argumint's rule for skipping one already seen. A built
`Spec` couldn't help: it's opaque (ADR 0030). Issue #340.

## Decision

1. **One typed visit, in the facade.** `spec.eachArg(name, arg): body` runs
   `body` once per Arg, with `arg` bound to the field with its own static
   type, so `when arg is ValuesArg` and `arg.get` work. There's no untyped
   iterator alongside it.
2. **It mirrors registration.** `addArgs` builds its list of Args with
   `eachArg`, so what `newSpec` registers and what `eachArg` visits are one
   piece of code: nested tuples in field order, an Arg reached more than
   once visited under the leaf field name where it's first reached, and the
   same compile error for a member that is neither an Arg nor a tuple.
3. **Commands are visited but not entered.** A Command's nested spec
   belongs to another level, and `newSpec` doesn't register its Args with
   the parent either. Message Arguments are visited like any other Arg;
   callers filter by type.
4. **`break` and `continue` are rewritten.** A bare `break` in the body
   ends the whole visit and a bare `continue` skips to the next Arg, as in
   a `for` loop. One inside a loop, block or nested `eachArg` the body
   opens keeps its usual meaning.
5. **It's a macro.** A recursive template over `fieldPairs` can't call
   itself when it expands in another module, and a `fieldPairs` loop
   rejects `continue` (`docs/gotchas.md`). The macro reads the tuple's type
   and writes one block per Arg, reached by index.

## Considered options

- **An untyped iterator, or re-exporting `Spec.args`.** Each gives a
  `seq[Arg]` or an `Arg` with no static type, so reading a value needs a
  downcast the caller has to get right. It would also open the opaque
  `Spec`.
- **Going into a Command's nested spec.** The caller can call `eachArg` on
  that spec tuple itself, and a visit that crosses levels would need to say
  which level each Arg came from.

## Consequences

- The facade's `eachArg` is a thin template over the spec-construction
  module's macro, so it shows on `argumint`'s doc page.
- `name` and `arg` shadow argumint's `name` and `arg` procs inside the body,
  and a generic proc's prepass binds them to those procs first, so the macro
  turns them back into identifiers (`docs/gotchas.md`).
