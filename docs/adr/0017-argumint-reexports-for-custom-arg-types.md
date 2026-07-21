# `argumint.nim` re-exports `validators`, `flagclamp`, `backend.name`, and `strutils.escape`

`defineArg`/`defineFlag`/`defineFlagArg`/`defineSetFlag` — the public
mechanism for registering a custom Positional Argument/Option/Flag type —
generate methods whose bodies call `self.validator.help()`,
`self.validator.completions()`, `self.name(...)` (`backend.nim`), and
`value.escape` (`strutils.escape`). Under this project's module-level
`{.experimental: "openSym".}`, those unqualified calls resolve against
whatever the *instantiating file* has imported, not against `argumint.nim`'s
own imports — so any file that registers a custom type (even one that never
touches a `Validator` directly, and regardless of whether the registration
is a single `defineFlag(MyType, ...)` call or one nested inside another
template like `defineSetFlag`) needed `import argumint/backend`,
`import argumint/validators`, and `import std/strutils` on top of
`import argumint`, or it failed to compile with a confusing "type mismatch"/
"undeclared field" error pointing at generated code the caller never wrote.
This was undocumented and easy to hit by anyone extending the library the
intended way.

`argumint.nim` now re-exports what's needed, so `import argumint` alone is
enough:

```nim
export validators
export flagclamp
export backend.name
export strutils.escape
```

`validators`/`flagclamp` are re-exported wholesale, not just the specific
symbols (`help`/`completions`) the generated code needs. Both are
argumint's own public constructor APIs (`choice`/`range`/`check`/... and
`clamp`/`adjust`) — a caller building a `Spec` with a `Validator` or a
`FlagClamp` benefits from `import argumint` alone being sufficient too, not
just from the bug being fixed.

`backend.name` and `strutils.escape` are re-exported narrowly, one symbol
each, for the opposite reason: `backend.nim` is this library's internal FSM
machinery (`State`/`Transition`/`Matcher`/...), not meant to be public, and
`std/strutils` is a large general-purpose module where wholesale export
would flood every caller's namespace with dozens of unrelated string
utilities, risking silent shadowing of a caller's own same-named helpers.

## Consequence: this is a per-symbol defense, not a general fix

Adding a *new* generated method to `defineArg`/`defineFlag`/`defineFlagArg`
that calls another unqualified symbol from a module `argumint.nim` doesn't
already re-export will reintroduce this exact failure mode for that new
symbol. There's no mechanism that makes this class of bug impossible going
forward — each new instance needs its own re-export added here, and a note
added to `docs/gotchas.md`.
