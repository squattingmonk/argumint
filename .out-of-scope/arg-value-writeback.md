# Writing an Arg's value back as strings

argumint has no method that renders an Arg's current value as the strings
`parse` would accept back. A program that saves parsed values, such as a
`config set` command writing a config file, turns each value into text
itself.

## Why this is out of scope

The request came from the nasher port, whose `config` command stores an
option's value in a config file. The sketch walked the spec with
`fieldPairs` and branched on the Arg's type: `$` for a single value,
`join(";")` for a `ValuesArg`.

A method would have folded those cases into one call, but each case it
would cover is either short in user code or not well defined:

- **A single value** is `$` already.
- **A `ValuesArg`** needs a join, and the separator belongs to the file
  format: an INI file may repeat a key, a JSON file writes an array, and
  an env variable joins on its delimiter. argumint doesn't write config
  files, so it can't pick one.
- **A Flag** stores only its value, not the Variants that set it. After
  `-vvv`, or a `+=` op, there is no list of Variant names to give back,
  so the method couldn't return what a config file supplies for a Flag
  (ADR 0005). Writing the value itself works only for a Flag that
  accepts a value from env or config, which #330 proposes. Whether a
  Flag's value round-trips depends on how its author declared it, so a
  generic method couldn't promise it.
- **A Custom Arg** is the only case a method would really help, and no
  known program needs it. Its author already knows how it stores values.

So the method would save a couple of lines in the programs that need it,
while adding a method every Custom Arg should override to stay correct.

## Prior requests

- #320: "An Arg can write its value back as strings" (review candidate
  [AB](../docs/reviews/2026-10-22-nasher-port-review.md#ab--an-arg-can-write-its-value-back-as-strings))
