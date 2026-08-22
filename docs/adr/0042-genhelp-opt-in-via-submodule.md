# `genHelp` is opt-in via `argumint/help`, not re-exported

`genHelp` is exported from `argumint/help` and deliberately absent from
`import argumint`. A caller who wants to render a Spec's help text
themselves -- to print it at another moment, page it, or embed it in a
larger message, rather than catching the `HelpError` a matched `help*` Arg
raises -- opts in with `import argumint/help`.

The mechanism isn't new. `configsource/ini` and `configsource/json` are
already direct-import-only (`docs/adr/0018-config-source.md`), so
"submodule you import yourself" is an established shape here, not a
category invented for this. The reasons differ -- those adapters stay out
to avoid pulling `std/parsecfg`/`std/json` into every build; `genHelp` has
no such cost -- but the shape a user sees is the same one, so this adds no
new concept.

Issue #50's split forced the `*` regardless: once `genHelp` moved to its
own module, `argumint.nim` could only call it across the boundary if it was
exported. The decision here is only about the *second* step, re-exporting
it from the umbrella, and that is declined. `import argumint` stays the
spec-construction vocabulary; a rendering entry point most CLIs never call
doesn't need to widen it. Semi-public also leaves room to revise the
signature with less ceremony than a name promised by the 1.0 umbrella API.

`tests/test_public_api.nim` asserts a bare `import argumint` can't reach
it; `tests/test_help.nim` imports the submodule and calls it. That pairing
is a third category alongside the two
`docs/adr/0030-core-types-exported-spec-opaque.md` describes -- not
"exists but is private", but "exported from its own module, absent from
the umbrella" -- which is why the mirror lives there rather than in
`test_argumint.nim`'s unreachable-names suite.

## Considered options

- **Re-export from `argumint`.** Rejected as above: it promises a 1.0 name
  for a use most callers don't have, when one extra import serves them.
- **Keep it private.** Not available -- the module split requires the `*`.
  Reverting to private would mean reverting the split.
