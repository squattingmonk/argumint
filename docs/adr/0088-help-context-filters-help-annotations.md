# A Help Context can filter Help Annotations

> **Note (#357):** A Validator or Flag Clamp can now hide its own
> annotation with `desc = some("")`, an `AnnotationText` (ADR 0089).
> `desc` stays one text for help and failure, and the converters keep it
> source compatible, so the first rejected option below is half adopted.
> Hiding in one help message but not another is still `filterAnnotations`.

Amends [ADR 0082](0082-help-context-filter.md). This is an addition to the
toolkit [ADR 0080](0080-1x-freezes-the-public-modules-and-the-usage-grammar.md)
freezes, so a minor release can ship it.

An Arg's Help Annotations always show. In a CLI that reads a config file,
every option whose Config Key is its own name ends with `configKey: …`,
which repeats the option name. A Flag with a `validator` (ADR 0086) whose
Flag Operations have their own descriptions gets one row per op (ADR 0063),
each ending with the whole `env/config values: choices: …` text. In
issue #345's CLI, its global and logging options grew from one line each
to two or three. The only way to leave one out was a custom Help Formatter
that edited `Row.text`, since the bracket is already in it.

Whether a Help Annotation is noise depends on the help message, not on the
Arg: a terse `--help` and a detailed `--help-all` may want the same Arg's
bracket differently. So the choice belongs to the Help Formatter.

## Decision

1. **`ctx.filterAnnotations(keep: proc (arg: Arg, annotation:
   HelpAnnotation): bool): HelpContext`** is public in `argumint/help`. It
   returns a copy of `ctx` whose Rows show only the Help Annotations `keep`
   accepts. A second call ANDs with the first, and the context it was
   called on is unchanged. A nil `keep` drops nothing further. An Arg left
   with none has no bracket.
2. **A `HelpAnnotation` has a `kind` and its `text`.**
   `HelpAnnotationKind = enum haValidator, haClamp, haDefault, haEnv,
   haConfigKey, haAction`. It isn't `{.pure.}`: `ConfigKey` and
   `Validator` already name types, so a pure enum's members would need
   qualifying in every predicate. The prefix follows `StyleRole`'s. `text`
   is the entry as shown, label included (`configKey: server.port`). A
   Flag's `env/config values:` entry is an `haValidator`; a predicate that
   wants only the Flag's checks the Arg. A Custom Arg's `validatorHelp` is
   an `haValidator` entry too.
3. **Everything that builds Rows honors it.** `ctx.rows`, so `frame`,
   `formatColumn` and `formatParagraph` too.
4. **It is help only.** Nothing else shows Help Annotations. Output with
   no filter is unchanged.

A formatter that leaves out every Config Key is then one line:

```nim
proc quietHelp(ctx: HelpContext): string =
  formatColumn(ctx.filterAnnotations((arg, a) => a.kind != haConfigKey))
```

It's named apart from `filter`, though an overload would resolve, so a
call says whether it narrows the Args or their Help Annotations. The
predicate's type is written out, as `filter`'s is, rather than given a
name.

## Considered options

- **An Arg or Validator hides its own Help Annotations**, such as
  `choice`/`range`/`check` taking `desc = some("")` the way `clamp` does
  (issue #12): rejected. It fixes the choice per Arg, for every help
  message, and `desc` is also the Validator Failure Message, so its type
  can't change in 1.x.
- **A `SpecSettings` switch to leave out `configKey:` or `env:`**:
  rejected for the same reason. It's a presentation choice made once for
  every formatter.
- **`Row` keeping its Help Annotations apart from `text`**: rejected. Only
  a formatter built on the Help Frame could use it, every `RowRenderer`
  would have to put the bracket back, and an existing renderer reading
  `text` would lose it or see the annotations twice.
- **A set of kinds** (`ctx.withoutAnnotations({ConfigKey})`): rejected.
  It can't decide per Arg, such as hiding a Config Key only when it
  repeats the option's name.
- **A built-in terse formatter**: not added. The one-liner above is short
  enough to write.

## Consequences

- A formatter can leave out any kind of Help Annotation, for any Arg, and
  keep the built-in layout.
- A program can offer both a terse and a detailed help message from the
  same Spec.
- `HelpContext` gains another private field. Formatters only receive a
  context, so none of them can tell.
