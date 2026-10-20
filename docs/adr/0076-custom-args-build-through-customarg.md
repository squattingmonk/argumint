# Custom Args build through `argumint/customarg`

Amends ADRs 0017, 0030, 0046, 0062 and 0073.

ADR 0030 kept every `Arg` field public so a hand-written subtype could
construct one. That gave every caller of `import argumint` write access
to the four fields a Spec is built from: `kind`, `variants`,
`CommandArg.spec` and `seenBy`. Changing one after `newSpec` leaves the
Spec's option and argument tables, the Flag ops table and the FSM keyed
by the old value, and writing `seenBy` directly breaks the rule that a
Seen Arg agrees with its stored value (ADR 0039). The facade also
carried names only a Custom Arg uses (`accept`, `Contribution`,
`Arbitration`, `subject`, `action`, `isMessage`, `envSource`, `envName`
and the `configKey` method), so a CLI author reading its doc page waded
through them.

## Decision

1. **`kind`, `variants`, `CommandArg.spec` and `seenBy` are read-only
   through `import argumint`.** Each is a private field with a public
   getter of the same name, so `arg.variants` still reads but
   `arg.variants = ...` and `arg.variants.add ...` don't compile.
   `help`, `group`, `hidden`, `complete` and `MessageArg.message` stay
   public fields, since writing one corrupts nothing.
2. **The library writes them through three withheld procs in
   `backend`:** `initBase`, `setSeenBy` and `setSpec`. `seenBy` changes
   only through the write side (`parse`, `put`, `replace`, `clear` and
   the internal `arbitrated`).
   A proc declared in `backend` writes its private fields even when a
   template or generic expands it in the caller's module; only
   `privateAccess` fails across instantiation.
3. **A new opt-in public module, `argumint/customarg`, holds what only a
   Custom Arg needs,** after `argumint/help`'s precedent (ADR 0042). It
   exports the nine names above and defines
   `initArg(arg, kind, variants: string)`. The facade stops exporting
   them. It keeps what the guide shows a CLI author: `parse`, `clear`,
   `seen`, the `seenBy` getter, `showsMessage`, `env`/`toEnvSource`,
   the `configKey(...)` constructor (a different overload, in
   `configsource`) and the Arg types, and it gains the `kind`,
   `variants` and `spec` getters.
4. **`initArg` splits the Variants as `opt` does and sets the kind.** It
   raises `SpecDefect` if the Arg already has Variants, so it can't
   rewrite an Arg in a built Spec. It doesn't validate: `newSpec` still
   checks every Variant and names the tuple field in its message.
5. **Override-only methods still need no export.** `defaultStr`,
   `completions`, `validatorHelp`, `accumulates`, `variantDesc` and
   `aliases` attach to `backend`'s method family from the caller's
   module because `Arg` is in scope (ADR 0046's correction to ADR 0030).
   `customarg` exports only what a Custom Arg calls or names.
6. **`subject` needs no facade export for generated code.** ADR 0017's
   reason, that generic bodies resolve it by bare name in the caller's
   module, no longer holds: it has one overload, so the generic binds it
   where it's defined.

### Deferred

- **`initValueArg`**, for a typed Message Arg built outside the
  library.
- **`arbitrated`**, for a Custom Arg with its own typed write path.

Neither has a caller yet. ADR 0029's rule applies: no export without a
demonstrated one.

## Considered options

- **Every `Arg` field read-only**: rejected. The presentation fields
  corrupt nothing, and the guide shows a CLI author setting them.
- **A setter per field**: rejected. A setter brings back the write it
  was meant to stop.
- **A generic `newArg[T]` constructor**: rejected. Nim can't name a
  subtype's own fields in a literal through a generic, so it would
  still need an init call.
- **`initArg` in the facade, unguarded**: rejected. It would rewrite an
  Arg already in a Spec, which is the write this ADR stops.
- **Validating in `initArg`**: rejected. `newSpec`'s message names the
  tuple field, which `initArg` can't know.
- **Naming the module `argbuilder` or `extend`**: rejected for
  `customarg`, which names the glossary's Custom Arg.

## Consequences

- A Custom Arg imports `argumint, argumint/customarg` and calls
  `initArg` once in its constructor.
- A Custom Arg that assigned `kind`/`variants` in its object literal no
  longer compiles. That's a breaking change, accepted pre-1.0.
- A help formatter that reads `envSource` or `configKey` directly needs
  `argumint/customarg`. `ctx.rows` already carries those annotations.
- White-box tests that build a bare `Arg(kind: ..., variants: ...)`
  literal need `privateAccess(Arg)`, or call `initBase`.
