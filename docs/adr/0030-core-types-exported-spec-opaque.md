# Core types are exported; `Spec` becomes an opaque handle

> **Extended by [ADR 0046](0046-arg-value-source-contract.md)**: the
> fallback half of the custom-`Arg` contract is now two methods, not three
> — `envName`/`envDelim` collapsed into one `envSource*` returning
> `Option[EnvSource]`, with `envName` surviving as a derived proc. All of
> `envSource*`, `configKey*` and `envName*` are re-exported from
> `argumint.nim`.
>
> That ADR also **corrects the final Consequences bullet below**, which is
> wrong: a hand-written subtype *can* override these from a caller's module
> and always could — Nim attaches the override to `backend`'s method family
> because `Arg` is in scope. What it could not do was *read* them back.
> Verified by scratch compile.

> **Extended by [ADR 0041](0041-parse-is-the-write-surface.md)**: the
> custom-`Arg` method contract this ADR freezes at 1.0 changed, on balance
> getting smaller. A subtype must now (1) route its `parse` override
> through the `arbitrate*` template, and (2) override `clear*` if it
> carries a value, or it will accumulate where it should reset.
>
> Three methods left the contract: `setFromEnv*` and `setFromConfig*` are
> gone (every tier now writes through `parse*`, which carries a `SeenBy`),
> and `Arg.parse`'s `(command, spec, variant)` overload became the sole
> `action*`, replacing the narrower `(variant)` form. `envName*`,
> `envDelim*` and `configKey*` stay — they are how a tier *finds* values,
> which is still per-Arg. So the method list further down this ADR that
> names `setFromEnv`/`setFromConfig` is stale.
>
> `parse*`, `clear*`, `action*`, `arbitrate*` and `subject*` are all
> reachable from the facade, so none of this needs a backend import.

`docs/adr/0017-argumint-reexports-for-custom-arg-types.md` set the goal that
"`import argumint` alone is enough". For the core vocabulary types it wasn't:
after a bare `import argumint`, none of `Arg`, `ArgKind`, `CommandArg`,
`MessageArg`, `HelpArg`, `Spec`, `SpecSettings`, `EnvSource`, `Option`, or
`CompletionCandidate` could be written down as a type, nor could
`DefaultMaxVariantsWidth`/`DefaultEnvDelim`, the constants `newSpecSettings`'
own signature names as two of its parameter defaults.

The consequence with teeth is that **a spec couldn't cross a proc or module
boundary**. `newSpec*` returns a `Spec`, but only `let`-inference could
receive it, so a non-trivial CLI had to build its spec at the point of use.
This repo was already paying for it: `examples/completion.nim` needs
`var built: Spec` so the `completion` subcommand's action can reach the whole
tree, and worked around the gap with `import argumint/backend` — reaching
past the public API into the FSM's data model. `tests/test_completion.nim`
did the same. Both drop that import as of this change.

Two smaller cases were just as real. `HookInfo.matched` is `seq[Arg]`, so
without `Arg`/`ArgKind`/`MessageArg` the only thing a caller could do with it
was pass it to `showsMessage` — the helper existed *because* users couldn't
write `it of MessageArg` themselves. And `opt*`/`opts*`/`flag*`'s `env`
parameter is `Option[EnvSource]`, so factoring out a house style
(`proc devEnv(name: string): Option[EnvSource]`) was unwritable, as was
spelling the `none(EnvSource)` default explicitly.

## Decision

Export the vocabulary types from `argumint.nim`, and narrow `Spec`'s field
surface to match what's actually API before 1.0 freezes it.

**Exported**: `Spec`, `SpecSettings`, `Arg`, `ArgKind`, `CommandArg`,
`MessageArg`, `HelpArg`, `EnvSource`, `CompletionCandidate`, and `Option`
(the type, not just the `some`/`none` already re-exported).

**Not exported**: `State`, `Transition`, `Matcher`, `MatcherKind`. These are
FSM plumbing, and the operations over them live in `argumint/fsmgraph`, which
isn't re-exported either — so `Spec`'s (now private) `fsm` field would be
inert to a caller even if they could reach it.

Of the constants, `DefaultMaxVariantsWidth` and `DefaultEnvDelim` are
exported and `DefaultWidth` is not. The line is whether the constant appears
in an exported signature: `newSpecSettings*` spells the first two as its own
parameter defaults, so anyone reading its generated documentation sees a name
they'd otherwise be unable to resolve. `DefaultWidth` appears only in
`formatUsage`, which isn't re-exported, so `docs/adr/0029`'s rule applies —
an export with no demonstrated caller stays out, since adding it later is
non-breaking and removing it after 1.0 is not.

Also re-exported: `fsm.parse*` and `fsm.completeArgs*`, the only two
operations on a built `Spec` that live in `argumint/fsm` rather than
`argumint.nim`. `parseOrQuit*(Spec)` was already reachable because it happens
to be defined in `argumint.nim`, so `newSpec` → `parse` was the one broken
half of an otherwise-complete pair — naming a `Spec` is worth little if the
primary operation on it still needs `import argumint/fsm`.

### `Spec` is opaque

`prolog`, `epilog`, `usage`, `args`, `commands`, `arguments`, `options`,
`groups`, and `fsm` lose their `*`. `settings`, `before`, `action`, and
`after` keep theirs: `newSpecSettings`' own doc comment tells callers to hold
the returned instance and mutate it later, and the hooks are assigned
directly by `parse*`/`parseOrQuit*`'s tuple overloads.

The reasoning is asymmetry of regret. A field can be added or an accessor
introduced after 1.0; neither can be withdrawn. And the newly-private set
isn't merely unnecessary — `spec.usage = "..."` after construction silently
desyncs the string from the FSM compiled out of it, which is a footgun rather
than an omission. Read-only introspection over `commands`/`args` is a
plausible future request (Nim has no read-only field, so it would have to be
an accessor proc); this leaves room to add one deliberately, on evidence.

`Arg` and `SpecSettings` keep every field public. A custom `Arg` subtype
constructs one, and inspecting `HookInfo.matched` means reading `kind`/
`variants`/`help`/`group`/`hidden`.

### The mechanism, and the constraint it imposes

The library reaches its own now-private fields via
`std/importutils.privateAccess(Spec)`, in the three modules that touch them:
`argumint.nim`, `fsm.nim`, and `parser.nim`. (`completion.nim`, `dot.nim`,
and `fsmgraph.nim` turned out to touch none.)

**Update:** five modules. Issue #50 split help rendering out of
`argumint.nim` into `help.nim`, which reads `prolog`/`epilog`/`usage`/
`args`/`groups` and so carries its own `privateAccess(Spec)`. The
generic-instantiation constraint below doesn't bite there -- `genHelp` is a
plain proc. Issue #49 then split spec construction out into `specbuild.nim`,
which reads every index field plus `usage`/`fsm`/`settings` and carries one
too; the constraint below moved with it, since `newSpec` and its `beginSpec`/
`finishSpec` bookends now live there rather than in `argumint.nim`.

`privateAccess` **does not survive template or generic instantiation in
another module** — verified by scratch compile, and recorded in
`docs/gotchas.md`. `newSpec*(spec: tuple, ...)` is generic over the spec
tuple and so instantiates in the caller's file, where the `privateAccess` in
its defining module doesn't reach. Its body is therefore split around two
non-generic bookends, `beginSpec` and `finishSpec`, with only the (private-
field-free) `addArgs` left generic in between. Any future generic or template
needing a private `Spec` field must be split the same way.

## Considered options

**Export the types as-is, changing no field visibility.** Zero refactor, and
the ADR could document which fields are supported versus incidental. Rejected
because documentation isn't a boundary: at 1.0 every `*` field becomes
something a user may depend on and this project may not remove, including the
ones that desync the FSM when written.

**Strip `*` from `Spec.fsm` alone.** The minimal version — `fsm` is the one
field whose type is deliberately unexported, so it's already useless outside
the library. It needs the `newSpec` split but no `privateAccess` beyond
`argumint.nim`. Rejected as drawing the line where it was cheapest rather
than where it belonged; the measured cost of the full narrowing was two more
`privateAccess` lines and one in `tests/test_argumint.nim`.

**Restructure so the internals live behind a private companion object**,
avoiding `privateAccess` entirely. Larger diff, and it wouldn't remove the
generic-instantiation constraint above — `newSpec*` would still be reaching a
private field from a caller-instantiated body.

## Consequences

- **Additive for ordinary callers.** Nothing that compiled before stops
  compiling, unless it reached a `Spec` field — which required
  `import argumint/backend`, since `Spec` wasn't nameable in the first place.
  That combination is what made the narrowing affordable now and impossible
  after 1.0.
- **Every `argumint/*` import that existed only to work around a missing
  re-export is gone**, from `examples/` and `tests/` alike. Three were freed
  by this change (`argumint/backend` in `examples/completion.nim` and
  `tests/test_completion.nim`, `argumint/fsm` and `argumint/lexer` in
  `tests/test_argumint.nim`, `argumint/completion` in
  `tests/test_completion.nim`); five `import argumint/validators` had been
  dead since ADR 0017 re-exported that module wholesale and were simply never
  cleaned up. Verified by removing each one and compiling. What remains is
  only what's meant to be reached deliberately: the opt-in
  `configsource/ini`/`configsource/json` adapters (ADR 0018 keeps them out of
  the umbrella import on purpose), `argumint/lexer` in the lexer's own test,
  and `argumint/backend` in `tests/test_argumint.nim`'s white-box assertions.
- **White-box tests pay a line.** `tests/test_argumint.nim` asserts on
  `spec.usage`/`spec.commands` and now carries its own `privateAccess(Spec)`
  alongside the `import argumint/backend` it already had.
- `tests/test_public_api.nim` locks the boundary in both directions — every
  exported type nameable, every plumbing type not, every private `Spec` field
  unreachable — and must never import an `argumint/*` submodule, or its
  negative assertions pass vacuously. A `not compiles(...)` is also satisfied
  by a name that no longer exists, so each negative is mirrored by a positive
  in `tests/test_argumint.nim`'s "Library-internal names ... unreachable"
  suite, which does import the internals. Only the pair carries the meaning
  "exists, but isn't exported"; add to both lists together.
- **The `{.base.}` method contract on `Arg` is deliberately untouched.**
  `envName`/`configKey`/`setFromEnv`/`setFromConfig`/`parse` remain
  unexported, so a hand-written `Arg` subtype (as opposed to one registered
  through `defineArg`/`defineFlag`) still can't override them from a caller's
  module. That contract is what issues #21 (a `reset` for reusing a `Spec`)
  and #22 (per-Arg value provenance) both extend, and settling it is their
  work, not this ADR's.

  **Corrected by [ADR 0046](0046-arg-value-source-contract.md):** the last
  sentence is false. Being unexported prevented *calling* these methods
  from a caller's module, not *overriding* them — Nim attaches an override
  to `backend`'s method family on the strength of `Arg` being in scope, and
  the tiers dispatch to it correctly. The distinction went unnoticed
  because nothing in-tree tested the fallback half of the contract. It does
  now.
