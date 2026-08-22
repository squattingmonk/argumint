# `ValueArg` and `FlagArg` are exported; their state stays private

> **Amended by [ADR 0041](0041-parse-is-the-write-surface.md)**: the base
> methods listed below now read `envName`/`envDelim`/`configKey`/`parse`/
> `clear`/`action`. `setFromEnv`/`setFromConfig` are gone — every tier
> writes through `parse`, which carries the Value Precedence tier it is
> writing as. The decision here, that the two type *names* are exported
> while their state stays private, is unaffected.

`docs/adr/0030-core-types-exported-spec-opaque.md` made a `Spec` nameable so
it could cross a proc or module boundary. It drew its export list around the
types a caller *receives* from `newSpec*` and reads off `HookInfo`, and did
not consider the types the five spec constructors return.

`arg*`/`args*`/`opt*`/`opts*`/`flag*` return `ValueArg[T, multi]` and
`FlagArg[T]`. Neither was exported, so a caller could hold one by
`let`-inference and pass it into a spec tuple, and nothing else. Naming one
was impossible:

```nim
proc appOpt(variants, help: string): ValueArg[string, false] =   # house style
  opt(variants, help = help, group = "App")

var pending: ValueArg[string, false]                              # forward decl

var common: seq[ValueArg[string, false]]                          # built in pieces

proc describe[T](a: ValueArg[T, false]): string = a.help          # helper
```

All four fail with `Error: undeclared identifier: 'ValueArg'`. This is
ADR 0030's own "couldn't cross a proc or module boundary" consequence, one
level down — and a strictly larger boundary, since these are the return
types of every constructor rather than one parameter of three.

Three workarounds compile. `auto` erases the signature from generated
documentation and defers every error to the call site. `typeof(opt(""))`
constructs a throwaway value to name a type. Inference covers a `seq` only
when it is initialized in a single statement, which rules out building one
conditionally. None of the three helps the forward declaration or the
helper at all.

## Decision

Export both type names. Every field stays private.

This is ADR 0030's `Spec` shape exactly — the type is nameable, its state is
not — so it introduces no new mechanism and sets no new precedent.
`FlagOp[T]` stays private: `FlagArg.ops` is a private field, so naming
`FlagArg[T]` never requires naming its element type. (`FlagOpGroup*` was
already exported, being a parameter of `flag*`.)

### Answering ADR 0029's rule

`docs/adr/0029-config-key-distinct.md` holds that an export with no
demonstrated caller stays out, since adding it later is non-breaking and
removing it after 1.0 is not. ADR 0030 applied that rule to keep
`DefaultWidth` internal. It is the real argument against this change and
deserves better than a wave.

The demonstrated caller is the one ADR 0030 already accepted for
`EnvSource`: factoring out a house style. That case cleared the bar for a
type appearing in *one parameter* of three constructors. These are the
*return* types of all five. If `EnvSource` qualified, so do these.

Worth being explicit that the rule still bites in the other direction here —
it is why this ADR exports two type names and nothing else. No field, no
`FlagOp`, and none of the `{.base.}` method contract on `Arg`
(`envName`/`configKey`/`setFromEnv`/`setFromConfig`/`parse`), which ADR 0030
deliberately froze and which #22 is settling separately.

## Considered options

- **Export both, fields private.** Chosen.
- **Export `ValueArg` only.** `FlagArg` has the identical problem for
  `flag*`, and splitting them would leave a caller able to write an `opt`
  factory but not a `flag` one — an arbitrary seam.
- **Document `typeof(opt(""))` as the sanctioned spelling.** Keeps the
  export list minimal, but institutionalizes a trick nobody discovers
  unaided, and still leaves the forward-declaration and helper cases
  unwritable.
- **Wait until after 1.0.** Adding an export is non-breaking, so this is
  genuinely available. Rejected because the argument for it is already
  settled, and because the accessors #16 and #22 are expected to add hang
  off these two types — their generated documentation would otherwise
  reference a type the reader cannot look up or name.

## Consequences

- The five constructors' return types appear in generated documentation as
  names a reader can resolve. #16 notes that a generic-inference failure
  today reports `argumint.ValueArg`, a type the user could not look up;
  exporting doesn't fix that inference problem, but it does make the name in
  the error findable.
- `tests/test_public_api.nim` gains both halves of the boundary: the two
  types are nameable, and their fields are not. It previously asserted
  nothing about either type in either direction, which ADR 0030 made that
  file's job.
- One wrinkle in the two-file convention that file documents. Every negative
  in `test_public_api.nim` is supposed to be mirrored by a positive in
  `tests/test_argumint.nim`, so that a negative can't pass merely because a
  name was deleted. `FlagOp` can't be mirrored there: it is private to
  `src/argumint.nim` itself rather than to a submodule that file can import,
  and `privateAccess` unlocks fields, not type names. Its positive lives in
  that file's own embedded suite instead, and both files say so.
- `privateAccess` is now called on three generic instantiations
  (`ValueArg[string, false]`, `ValueArg[string, true]`, `FlagArg[bool]`) in
  `tests/test_argumint.nim`. It works per-instantiation, not per-generic, so
  a white-box assertion on some other `T` needs its own call.
