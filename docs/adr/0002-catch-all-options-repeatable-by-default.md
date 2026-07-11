# Options reachable only through the catch-all are repeatable by default

Docopt ties an option's repeatability to how it's written in the usage
pattern (e.g. `--path=<path>...`), because in docopt that's also how the
parser decides whether the resulting value is a scalar or a list --
docopt has no separate type system to consult. Docopt's `[options]`
shortcut has no established meaning for `...` at all; repeatability is
always per-option and explicit.

argumint doesn't have that constraint: `arg`/`args` and `opt`/`opts`
already pin down scalar-vs-list at declaration time via the `multi` static
arity, independent of anything in the Usage String. That frees
repeatability to be decided on its own merits instead of doing double
duty as a type signal. We decided an Option or Flag reachable *only*
through the Options Catch-all (`[options]`) should be repeatable by
default, with no `...` required on the catch-all itself:

- A Flag's Variants are often meant to be invoked repeatedly to compose
  the final value (e.g. multiple `--warm`/`--bright` calls building up a
  `set[Color]` via their Flag Operations); disallowing repetition by
  default would break that composition for the common case where the
  flag is only reachable via `[options]`.
- A multi-value Option (`opts()`) needs to be invoked more than once to
  be useful at all -- a single match would only ever produce a
  one-element list.
- A single-value Option (`opt()`) is harmless to invoke more than once;
  nothing is lost by allowing it.

An Option or Flag *explicitly* named in a Usage Line keeps the opposite
default (single-match unless it carries its own `...`) -- explicit
mention is how an author opts out of the catch-all's repeat-by-default
behavior for one specific Arg while leaving the rest of `[options]`
alone.

This is implemented today as "the catch-all repeats when `[options]`
itself is written with a trailing `...`" (`fsm.nim:239`), which is not
quite what we want -- see the TODO item to make it unconditional.
