# An Arg can supply its own completion candidates at runtime

Amends ADR 0022 (value candidates stay description-less) and ADR 0066
(points 2 and 3, and its "out of scope: a custom completer proc").

Completion offered a value's `choice` or enum values, or file and directory
names. Many values come from neither: git branch names, hosts in an SSH
config, a remote API's resource IDs. Only code run when the user presses Tab
can list them, as Cobra's `ValidArgsFunction` and clap's
`ArgValueCompleter` do.

## Decision

1. **One `complete` param takes a Completer.** `arg`, `args`, `opt` and
   `opts` take `complete = default(Completer)` in place of
   `complete = PathCompletion.Files`, and `Arg.complete` is a `Completer`.
   The zero value is the default: the Arg's enumerable values if it has
   any, otherwise files, as before. Flags and commands still take none.
2. **A Completer is opaque**: the default, a fixed `Offer`, or a closure,
   `proc (ctx: CompletionContext): Offer`. Two exported converters make
   one:
   - a `PathCompletion` is a fixed Offer of just those paths, so
     `complete = Dirs`, `None` and `Files` still compile unchanged;
   - any proc of that shape is the completer itself, so users write
     `complete = proc (ctx: CompletionContext): Offer = ...` with no
     wrapper. The converter is generic over the proc type, because a proc
     literal capturing nothing is `{.nimcall.}`, and a converter won't
     chain a second implicit conversion. A proc of another shape is a
     compile error naming the expected signature.
3. **An `Offer` carries the candidates and the paths for this Tab**, built
   with `offer(values, paths = None)` or `offer((value, help) pairs, paths
   = None)`. Its fields are private, so file patterns (#214) can be added
   later. argumint still filters candidates by the word being completed,
   so a completer may return everything; `CompletionContext.word` is for
   narrowing a slow query.
4. **Earlier values are filled before a proc runs.** Completion stores the
   branch's command-line matches into the Args in the order typed, then the
   env and Config Source tiers over the root Spec and every level the
   branch entered, as `parse` would. A completer reads an earlier Arg by
   capturing it, so that Arg is bound with `let` before the spec tuple. An
   `args` or `opts` completer sees its own earlier values. A value that
   fails to convert or validate leaves its Arg unsupplied. No hook runs.
   A fixed Completer, such as a converted `PathCompletion`, fills nothing.
5. **Once per Tab.** The fill runs once per `__complete` request, from the
   first frontier branch that reaches a proc Completer, and clears nothing,
   so pre-seeded values (ADR 0041) survive. Each Arg's Completer runs at
   most once. In an ambiguous grammar like `(<user> | <org>) <repo>`,
   `tool acme <Tab>` fills `user`, the binding `parse` makes for
   `tool acme widget`.
6. **Descriptions.** A pair's description is reduced to one line, as option
   help is, so it can't break the `value\thelp` wire format. `choice` and
   enum values still carry none.
7. **An explicit Completer replaces enumerable values.** With any
   non-default `complete`, `completions()` isn't consulted for completion,
   including for `complete = Dirs` on an Arg with a `choice`, which now
   offers directories. Help, error messages and validation are unchanged.
8. **Errors.** A `CatchableError` from a completer offers nothing: no
   candidates and no paths. A `Defect` propagates. A hidden Arg isn't
   offered (ADR 0065), so its completer never runs until the user types a
   hidden option's name, after which its values complete as ADR 0065
   allows.
9. **The fill's writes are visible** to a `parse` caller that catches
   `CompletionError` and carries on.

## Considered options

- **A bare proc type for `Completer`**: rejected, since argumint couldn't
  tell a converted `Dirs` from a user's proc, and would fill for both.
- **A proc plus a `fill` flag**: rejected. Only argumint makes a Completer
  that skips the fill, and each is a fixed answer, so storing that answer
  as data says what it is; extension filters (#214) will be one too.
- **An inheritable `Completer` with a `complete` method**: rejected. A
  completer reading earlier Args would need its own subtype, fields and
  constructor, and Nim requires a `method` at module top level, so it
  couldn't be written at its Arg. Reuse is a proc returning a `Completer`.
  This matches ADR 0070.
- **Looking up earlier values by name** (`ctx.arg("--repo")`): rejected as
  stringly typed. **A spec-level completer taking the typed tuple**:
  rejected, since it puts the completer away from its Arg.
- **Filling per frontier branch**: rejected. It ran a completer once per
  live branch, twice for the common optional `-h`, and clearing between
  branches destroyed pre-seeds.

## Consequences

Breaking: `Arg.complete` is a `Completer`, not a `PathCompletion`, so a
custom Arg kind reading it must change. An Arg with a `choice` and an
explicit `complete = Dirs` or `Files` now offers paths instead of the
choices.

A completer runs inside the user's shell, where argumint can't guard a hang
or stray output. Its doc comment states the rules: return quickly, write
nothing to stdout or stderr, and expect no hook to have run.
