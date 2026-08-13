# Flag Operations are declared via `flagOp`, not embedded in a variants string

`flag*[T]`'s `variants` param used to be a comma-separated string where
each item was `<flag>[<op><value>]` (e.g. `--boost+=5`), parsed with a PEG.
Two side-table params were added later to work around what a string
couldn't express cleanly: `variantValues` (a typed value with no natural
string spelling, bypassing string parsing) and `variantHelp` (a per-variant
help override). Both were keyed by bare flag name and separately validated
against the declared variants -- so the same Variant's identity, behavior,
and help lived in three unrelated places (`variants`, `variantValues`,
`variantHelp`) that could silently drift out of sync, and every future Flag
feature needing per-variant data would have meant a fourth side table.

## Decision

1. **A Flag's Variants split into exactly two authoring paths.** `flag*`'s
   own `variants: string` param stays a comma-separated list of bare
   spellings (`-f`/`--flag`, no `<op><value>` suffix -- that's no longer
   legal there), always sharing the type's implicit blank-op behavior
   (`bool` toggles, `int` increments by 1) against the Flag's own coded
   `default`. `flag*`'s new `ops` param takes zero or more `FlagOpGroup[T]`
   values, built by `flagOp*(variants: string, op: string, value: T, help
   = "")` -- `op`/`value` are mandatory here, since a `flagOp*` call can
   never represent a blank operation; that's exclusively `variants`'
   job. This is what removes the ambiguity a unified "blank-value flagOp"
   design would have had: since blank-op behavior only ever happens where
   the Flag's own `default` is already in scope as a sibling parameter, no
   value needs threading into `flagOp*` for it, and `flagOp*`'s `op`/
   `value` can be plain required params.

2. **`variantValues`/`variantHelp` are removed outright, not kept
   alongside the new form.** Keeping both would mean designing every
   future Flag feature twice, and the three-separate-place drift risk is
   exactly what motivated this change. `flagOp*`'s `value: T` is always a
   real, already-typed Nim value (never parsed from a string), which is
   what `variantValues` existed to work around -- e.g. `flagOp("--warm",
   "=", warmColors)` for a `set[Color]` with no single-token string
   spelling needs no escape hatch anymore. `flagOp*`'s `help` param plays
   `variantHelp`'s exact role, supplied inline instead of as a name-keyed
   side table.

3. **FlagOp Alias grouping is authored directly, not discovered by
   comparing `(op, value)` after the fact.** Every spelling in `flag*`'s
   own `variants` string is automatically one alias group (they can only
   ever share the type's one implicit op/value pair); every spelling
   passed to one `flagOp*` call is another, declared explicitly by the
   author. Two different `flagOp*` calls are always independent groups,
   never merged into one alias set even if their `(op, value)`
   coincidentally match -- unlike today's `docs/adr/0026` mechanics, which
   discover aliasing by scanning every declared variant pair. Once
   grouping is something the author states rather than something the
   library infers, an accidental match between two separately-authored
   `flagOp*` calls is far more likely a coincidence than an intended
   alias; silently merging them would be surprising. This also simplifies
   the implementation: `Arg.aliases` is built directly from each group's
   own spellings, no `O(n²)` cross-comparison needed. `CONTEXT.md`'s
   FlagOp Alias entry is updated accordingly.

4. **`flag*`/`flagOp*` stay plain generic `proc`s -- no macro.** The
   original plan for this redesign called for a trailing-block call shape
   (`flag(...): flagOp(...); flagOp(...)`), with a macro rewriting each
   bare `flagOp(...)` into `flagOp[T](...)` before typechecking, to work
   around what looked like a hard Nim generic-inference limitation. A
   scratch-compile spike (see Considered Options) found the block shape
   doesn't parse as a spec-tuple element at all, and separately that a
   macro can't reliably resolve its own bound `[T]` from inside its body
   in the first place -- eliminating the need for a macro is what actually
   solves the problem: `flagOp[T]`'s own `T` is always inferable from its
   own `value: T` argument via completely ordinary Nim generic inference,
   and declaring `flag*`'s `ops` param as `varargs[FlagOpGroup[T]]` (not a
   tuple) gets the same elementwise type-unification an array literal gets
   against a `seq[T]`/`openArray[T]` parameter. Callers pass explicit
   Flag Operations as `ops = [flagOp(...), flagOp(...)]` (square brackets,
   an array literal) rather than `(flagOp(...), flagOp(...))` (a tuple) --
   the smaller, but real, surface-syntax cost of avoiding the macro
   entirely.

5. **`ops: varargs[FlagOpGroup[T]]` needs an explicit call-based default
   (`= @[]`), not none at all.** Omitting a default entirely reproduces
   `docs/adr/0024`'s "cannot instantiate T" gotcha for the bracket-less
   bare-bool call (`flag("--verbose")`): a parameter whose type depends on
   an otherwise-unconstrained `T`, with no default value at all, poisons
   overload resolution before it ever gets to prefer the non-generic
   sibling overload -- confirmed by scratch-reproducing the exact failure,
   then confirming `= @[]` (a call-based default, the same shape as
   `docs/adr/0024`'s already-proven-safe `noClamp[T]()`/`initTable[string,
   T]()` pattern) fixes it. `docs/gotchas.md` is updated with this as a
   variant of the same underlying gotcha.

New domain-model consequence: `CONTEXT.md`'s **Flag Operation** and
**FlagOp Alias** entries are rewritten to describe authored declaration
(implicit `variants` string vs. explicit `flagOp*` groups) rather than a
string-embedded core plus side-table patches or post-hoc op/value
discovery.

## Considered options

- **Trailing-block call shape**
  (`flag(...): flagOp(...); flagOp(...)`), matching this codebase's own
  `defineArg`/`defineFlag` block-taking macro style. Rejected: a
  scratch-compile spike found Nim's indentation-sensitive grammar doesn't
  allow a block-taking call embedded as one element of an enclosing tuple
  literal to parse at all (confirmed across single- and multi-statement
  bodies, with and without extra wrapping parens, comma before or after
  the block) -- ruling this out regardless of the macro question below.

- **Macro-rewritten tuple argument**
  (`flag[int]((flagOp(...), flagOp(...)), default = 0)`, a macro splicing
  `[T]` into each bare `flagOp` call before typechecking). Rejected after
  a scratch-compile spike found a macro can't resolve its own bound `[T]`
  from inside its body at all -- it prints as an unresolved `"GenericParam"`
  regardless of how `T` was bound at the call site -- and the only working
  substitute (reading `.getTypeInst` off an argument the caller *actually
  wrote*) silently breaks the moment a defaulted parameter's own fallback
  value is what's supposed to supply that type, which is exactly the
  common "`[T]` bracket given, `default` omitted" call shape. Five
  different workarounds were tried and scratch-compiled before abandoning
  the macro approach entirely in favor of decision 4 above.

- **`ops: seq[FlagOpGroup[T]] = @[]`** instead of `varargs`. Also
  scratch-compiled: fixes the "cannot instantiate T" problem the same way,
  but a plain array literal (`[flagOp(...), ...]`) doesn't implicitly
  convert to `seq[T]` the way it does to `varargs[T]`/`openArray[T]` --
  callers would need an explicit `@[...]` prefix. `varargs` was chosen
  since it accepts a bracket literal directly.

## Consequences

- `flag*`'s `variants` param no longer accepts `<op><value>`-suffixed
  entries; existing specs written against the pre-0027 API need every
  such entry rewritten as a `flagOp*` call passed to the new `ops` param.
  This is a breaking change, shipped as a single coordinated rewrite of
  `src/argumint.nim`, every example, and every test -- not a deprecation
  window.
- Every built-in-type `flag[T]` call site that never used
  `<op><value>`/`variantValues`/`variantHelp` (the common single-behavior
  case, e.g. `flag("--verbose", help = "...")`) is unaffected -- the
  breaking surface is scoped to Flags with more than one distinct Flag
  Operation.
