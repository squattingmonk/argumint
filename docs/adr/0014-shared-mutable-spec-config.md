# `width`/`maxVariantsWidth`/`envDelim` become a shared, mutable `SpecSettings`

`Spec.width`/`maxVariantsWidth`/`envDelim` cascaded from the top-level
`newSpec`/`parse*`/`parseOrQuit*` call into every nested subcommand's `Spec`
via `cascadeSpecDefaults`, a one-time, one-directional **value copy**: it
walked `spec.commands` recursively and assigned the same three scalars onto
every nested `Spec`. Because `Spec` is a `ref object` but these three fields
were plain `int`/`string`, each level in the tree ended up with its own
independent copy the moment `newSpec` finished — there was no live
relationship between a parent's and a child's settings after construction,
and no way for a `before` hook (see
`docs/adr/0009-command-before-action-after-hooks.md`) to reconfigure them
for the rest of a parse.

## Decision

Bundle the three fields into `SpecSettings`, a `ref object`
(`src/argumint/backend.nim`):

```nim
SpecSettings* = ref object
  width*: int
  maxVariantsWidth*: int
  envDelim*: string
```

`Spec.width`/`maxVariantsWidth`/`envDelim` are replaced by a single
`Spec.settings*: SpecSettings`. `newSpecSettings*` (`src/argumint.nim`) constructs
one with the same defaults as before (`terminalWidth()`,
`DefaultMaxVariantsWidth`, `DefaultEnvDelim`). `cascadeSpecDefaults` is
renamed `cascadeSpecSettings` and changed from a scalar copy to a reference
assignment — `spec.settings = settings`, recursively — so every `Spec` in the
tree points at the *same* `SpecSettings` instance rather than an independent
copy of its values. Holding onto that instance and mutating it later (e.g.
from a `before` hook) is now visible to every not-yet-dispatched `Spec` in
the tree, including the current level's own message/help output once
`parseMessageArgs` runs after `before` (ADR 0013 is what makes that last
part true for the *current* level, not just descendants — this change and
that one are complementary).

### Clean break on `newSpec`/`parse*`/`parseOrQuit*`

`width=`/`maxVariantsWidth=`/`envDelim=` are removed from these three procs'
signatures outright, replaced by a single `settings = newSpecSettings()` param.
`command*` is unaffected — it never took these as parameters and still
doesn't; `config` is only ever set at the outermost `newSpec`/`parse*`/
`parseOrQuit*` call, cascaded from there.

This is a real, breaking change to a public API surface (confirmed against
existing usage: roughly 15 call sites across `tests/test_argumint.nim`
needed updating, from e.g. `newSpec(spec, maxVariantsWidth = 20)` to
`newSpec(spec, settings = newSpecSettings(maxVariantsWidth = 20))`). Consistent
with this project's existing precedent (ADR 0009 dropped `CommandArg.handler`
outright, no deprecated alias) — argumint is pre-1.0 with no known external
consumers, so there's no compatibility surface to preserve, and keeping both
a scalar-param convenience path and a `config` path indefinitely would mean
two ways to set the same three values with no clear precedence rule between
them.

### Known, accepted limitation: `envDelim`

Carried over from ADR 0013: `envDelim` doesn't benefit from hook-time
mutation the way `width`/`maxVariantsWidth` do, because the env-var fallback
sweep (`fsm.nim`'s `applyFallbacks`, since `docs/adr/0018-config-source.md`
generalized this from the original `EnvCursor.apply`) runs to completion
across the *entire* matched tree before `dispatch` (and therefore any hook)
is ever called. A `before` hook mutating `settings.envDelim` has no effect
on that parse's own env-var handling. It's still bundled into the same
`SpecSettings` for
consistency (all three values conceptually belong together, and setting
`envDelim` *before* calling `parse*`/`parseOrQuit*` works exactly as before),
this is just a documented gap between the three fields' otherwise-uniform
treatment.

## Considered options

- **Keep scalar convenience params on `newSpec`/`parse*`/`parseOrQuit*`,
  add an optional `settings: SpecSettings = nil` param for the shared/mutable
  case**: considered first for its lower migration cost (no existing test
  call sites would need to change). Rejected in favor of the clean break —
  see above.
- **Leave the cascade as a value copy, expose `SpecSettings` only as a
  read-only snapshot**: doesn't serve the motivating use case (hook-time
  reconfiguration propagating live to the rest of the tree) at all, so
  doesn't solve the actual problem.
- **Give `command*` its own `config` param to opt a subcommand out of the
  shared instance**: out of scope — no motivating use case surfaced for a
  subcommand needing independent `width`/`maxVariantsWidth`/`envDelim`, and
  it complicates the "one value governs the whole tree" model for no
  demonstrated benefit. Can be revisited if a real need shows up.

## Out of scope

The hook-ordering fix that makes `before`-time mutation visible to the
*current* level's own message/help output (not just descendants') is
tracked separately in ADR 0013 and landed first, specifically so this
change wouldn't ship with that gap baked in.
