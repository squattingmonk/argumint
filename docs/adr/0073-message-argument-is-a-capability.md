# A Message Argument is a capability, and its `action` takes a `HookInfo`

> **Amended by [ADR 0076](0076-custom-args-build-through-customarg.md)**:
> `isMessage` and `action` are exported from `argumint/customarg`, not
> `argumint.nim`.

Amends ADRs 0021 and 0041.

A Message Argument was a type: anything `of MessageArg`, always a Flag,
holding no value. That ruled out `prog completion <shell>` (#252), a
positional whose action needs the value typed, and `--help=<style>`
(#102), an option taking one. Its `action(command, spec, variant)` also
couldn't reach the root Spec, which `completion` needs to print the
whole program's script.

## Decision

1. **`method isMessage(self: Arg): bool`**, `false` by default and `true`
   for `MessageArg` and `HelpArg`, decides whether an Arg is a Message
   Argument. Everything that tested `of MessageArg` calls it instead: the
   per-level message pass, `showsMessage`, the `[options]` expansion,
   auto-filled usage, and the wording of a missing-option complaint.
2. **A Message Argument may be any kind and may hold a value.** In
   practice it's a subtype of `ValueArg[T]` overriding `isMessage` and
   `action`. Its value is converted and validated with every other value,
   before any hook fires (ADR 0032), so a bad one is an ordinary parse or
   validation error. Its `action` reads its own value. Only a dedicated
   subtype overrides the two methods, so a plain `arg[T]` or `opt[T]` is
   never a Message Argument. A positional one is auto-filled into the
   positional usage line, not a line of its own.
3. **`HookInfo` gains `root` and `here`**, each a `(spec, command)` pair.
   `root` is the Spec `parse` was called on and the command it was given,
   the same at every level. `here` is the level being dispatched, so each
   level's hooks see their own; at the root, `here == root`. ADR 0021's
   `matched` is still computed once and the same everywhere.
4. **`method action(self: Arg, info: HookInfo, variant = "")`** replaces
   `action(command, spec, variant)`, mirroring the `action` hook. The
   message pass passes the level's `HookInfo`. `HelpArg` renders from
   `info.here`. An override of `action` needs one of `isMessage` too, or
   it never fires.
5. **Building a subtype from another module.** `initValueArg(A, ...)`
   (withheld, `argtypes.nim`) builds a `ValueArg[T]` subtype `A` declared
   anywhere, setting its fields through a `ValueArg[T]` view (see
   `docs/gotchas.md`). Exporting it, with a guide section on writing your
   own Message Argument, would break nothing and is left for later.

## Considered options

- **Keeping the `MessageArg` type and giving it value storage**:
  rejected. It duplicates `ValueArg[T]`'s conversion, validators,
  `[choices: ...]` help and value completion.
- **Adding `root` and `value` as parameters to `action`**: rejected. It
  breaks again with the next field, and an override still written with
  the old signature silently becomes a new overload instead.
- **A private back-pointer from every Spec to its root**, keeping the
  old signature: rejected. A pointer on every Spec for one Arg's sake.
- **Passing the value through `action`**: rejected. The value goes
  through `parse` like every other Arg's, so it's converted before any
  hook.
- **Folding `variant` into `HookInfo`**: rejected. It belongs to the
  Arg, not to the invocation.
- **`rootSpec` and `rootCommand`, beside flat `spec` and `command`
  fields**: rejected for two pairs of one type, `root` and `here`, which
  read alike (`info.root.spec`, `info.here.spec`).

## Consequences

- A custom `action` override must change to the new signature, and add
  `isMessage` if its type isn't already a `MessageArg`.
- `HookInfo` is no longer identical at every level: `here` differs per
  level. `matched` and `root` don't.
- A hook reaches the built Spec through `info.root.spec`, so keeping a
  `var cli: Spec` just for that is no longer needed.
