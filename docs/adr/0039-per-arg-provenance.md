# Per-Arg provenance is a field on `Arg`, written centrally

> **Amended by [ADR 0041](0041-parse-is-the-write-surface.md)** in three
> places. The field, its enum, the weakest-to-strongest ordering, and the
> uniform-across-Arg-kinds semantics all stand as described here.
>
> 1. *"The writes are central, not per-type"* is reversed. Provenance is
>    now written by whichever `parse` override writes the value --
>    `setFromEnv`/`setFromConfig` no longer exist, so `parse` is the only
>    write path for every tier. Of the two reasons given for centralising it, only
>    one survived: ADR 0032 had already moved every matched level's
>    conversion ahead of `dispatch`, so a per-contribution write also
>    completes before the first hook fires. Central stamping also wrote
>    provenance when nothing had been written, which was a live
>    `IndexDefect`.
> 2. The blanket post-walk `byCli` sweep described below is gone;
>    `parseAllValues` records `byCli` per contribution. The `applyFallbacks`
>    code block below is stale in the same way — its gates now skip only a
>    *strictly* stronger tier, and the `setValue` closures no longer stamp.
> 3. *"`arg in info.matched` and `arg.seenBy == byCli` are equivalent"* no
>    longer holds. A programmatic write declaring `byCli` sets provenance
>    without a match-table entry.
>
> The `ValueCursor.tried`/`complained` reasoning below is unchanged and
> gained a third set, `applied`, for the same reason.

After a parse, nothing recorded which Value Precedence tier supplied an
Arg. `spec.color` reads `"auto"` identically whether the user typed
`--color=auto` or typed nothing at all, so a program that wants to layer
its own source on top — or merely log where a setting came from — cannot
tell a supplied value from a coded default that happens to equal it.
`HookInfo.matched` (ADR 0021) answers it for the command-line tier only,
and only from inside a hook.

The information already existed and was being discarded. Exactly one tier
ever wins per Arg: `applyFallbacks` skips an Arg the walk matched, and
consults the Config Source tier only when the env tier had nothing. Each
tier's write site is distinct.

## Decision

A **Seen Arg** (`CONTEXT.md`) is an Arg some tier supplied. Its provenance
is a field on the base `Arg`:

```nim
type SeenBy* = enum
  byNone     ## nothing supplied it
  byConfig   ## a Config Source
  byEnv      ## an environment variable
  byCli      ## the command line

proc seen*(self: Arg): bool = self.seenBy > byNone
```

Members are ordered weakest-to-strongest, mirroring the documented
precedence chain, so ordinal comparison is meaningful and part of the
public contract: `spec.port.seenBy > byConfig` reads "supplied above the
Config Source tier". Members must never be reordered.

`byNone` being the zero value is what makes the default path free. A coded
default is merged at read time by `toT`/`toSeqT` and never written into
`value` (ADR 0008), so "nothing wrote to this Arg" and "the coded default
applies" are already the same state; Nim initialising an enum field to its
first member expresses it with no code at all.

### A field, not a `{.base.}` method

Provenance is data. Nothing about it varies by subtype, so dynamic
dispatch buys nothing, and a field leaves the custom-`Arg` method contract
of ADR 0017 / ADR 0030 untouched. That contract freezes at 1.0 and this
was its last open gate; a method here would have reopened it.

The field is publicly writable, like every other `Arg` field. Making this
one read-only would be a new rule for one field rather than a fix.

### Semantics are uniform across every Arg kind

Including the kinds that carry no value. A matched command word sets its
`CommandArg` to `byCli`; a matched `-h` sets its `HelpArg`. This is what
the "seen by" framing buys over "which tier supplied the value", which
would be a category error for a command — and it keeps `seenBy` truthful
for anyone iterating `HookInfo.matched` and reading it off an `Arg`.

### The writes are central, not per-type

Provenance is assigned in the parse pipeline, never in a per-type
`parse`/`setFromEnv`/`setFromConfig` method:

- immediately after a successful walk, `byCli` on every Arg in the match
  table — `matchedArgs` already returns exactly that set, commands and
  help args included
- in `applyFallbacks`, `byEnv`/`byConfig` as each tier applies, inside the
  `setValue` closure so an oversupply complaint (which sets nothing) does
  not claim a tier

Two things follow. A hand-written `Arg` subtype gets correct provenance
without having to remember anything, and `defineArg`/`defineFlagArg` need
no changes. More importantly, `seenBy` is fully resolved for the whole
invocation before any hook fires. Writing it inside the per-type methods
would resolve command-line provenance progressively during dispatch, so a
top-level `before` hook would read `byNone` for an Arg belonging to a
subcommand not yet dispatched.

### `applyFallbacks` gates on `seenBy`

The sweep used to decide whether a tier applies by asking `arg in matches`
— "was this supplied on the command line", spelled as a table lookup — and
carried a `seen: HashSet[Arg]` so an Arg reachable from two spec levels
wasn't applied twice. Both are re-derivations of what `seenBy` now answers
directly, so both go:

```nim
for a in spec.args:
  let arg = a
  if arg.seenBy >= byEnv: continue
  let envHad = applyTier(env, arg, ..., proc (values: seq[string]) =
    arg.setFromEnv(values)
    arg.seenBy = byEnv, complaints)
  if not envHad and arg.seenBy < byConfig:
    discard applyTier(configValues, arg, ..., proc (values: seq[string]) =
      arg.setFromConfig(values)
      arg.seenBy = byConfig, complaints)
```

The gate covers both of `matches`' job and most of `seen`'s: it skips an
Arg the command line supplied, and on a second visit to a shared Arg the
tier already recorded skips it again. `applyFallbacks` keeps its `matches`
parameter only for `matchedCommand`, which drives its recursion.

It does not cover *quite* all of `seen`, because two of that set's effects
were on paths where no tier applies anything and `seenBy` therefore stays
`byNone`. Both move onto the `ValueCursor`, which is where per-tier
bookkeeping belongs:

- a tier that resolves *nothing* would be resolved again on the second
  visit, so `applyTier` now takes `cursor: var ValueCursor` and records a
  fresh resolve in `cursor.tried`. A user-supplied `ConfigSource.lookup`
  may be arbitrarily expensive, so `ValueCursor.tried`'s existing
  at-most-once contract now covers the post-walk sweep too, not just the
  walk.
- the oversupply branch complains without applying, so it would complain
  twice. A `cursor.complained` set makes that once per Arg per tier.
  `formatComplaints` happens to dedupe subjects within a kind, but that is
  a rendering coincidence and not something the sweep should lean on.

The gate does not require the command-line tier to be *converted* first:
`byCli` is written straight from `matchedArgs(pc.matches)` immediately
after the walk, so it is fully populated whichever of `parseAllValues` and
`applyFallbacks` runs next. Swapping them is a separate, deliberate
choice — it makes `parse*` read as Value Precedence top-down, strongest
tier first:

```
walk
parseAllValues        # CLI tier, seenBy = byCli
applyFallbacks        # env if seenBy < byEnv, then config if seenBy < byConfig
dispatch
```

ADR 0032 had already moved `parseAllValues` ahead of `dispatch`; this
swaps it with `applyFallbacks`, which is the only ordering change.

`applyTier`'s consumption-count semantics (`cursor.consumed`/`tried`/
`values`, and the oversupply complaint) are about what the *walk*
consumed, not about which tier won, so none of that moves.

## Consequences

- A bad command-line value now surfaces before a bad env or config value,
  where it used to be the other way round. This is a behavior change, and
  arguably the better answer — the higher-precedence tier is also the more
  likely source of a typo — but it is visible to anyone whose tests pin
  which of two simultaneous failures is reported.
- `arg in info.matched` and `arg.seenBy == byCli` are equivalent.
  `HookInfo` is unchanged and `matched` is not deprecated: enumerating
  CLI-seen Args without knowing the spec's shape is its own use case that
  `seenBy` does not serve.
- `seen` is a reliable "this Arg's value is readable" test from inside a
  hook at any depth. Issue #22's follow-up comment recorded the opposite —
  that a parent's `before` hook could observe `seen == true` for a child
  Arg whose value had not been converted yet — but that comment predates
  ADR 0032, which moved every matched level's conversion ahead of
  `dispatch` and closed the window. ADR 0032 anticipated this exact
  interaction. `tests/test_seenby.nim` pins the agreement so a later
  change to dispatch ordering (#28) is a deliberate decision rather than
  an accident.
- A `Spec` is still single-use (ADR 0031): `seenBy` accumulates across
  parses on a reused spec like every other Arg state, so build a fresh
  `Spec` per parse.

## Considered options

**Per-value provenance for multi-value Args.** Structurally impossible as
the pipeline stands — exactly one tier wins per Arg, and the fallback
sweep's single-tier rule is what makes the oversupply accounting in
`applyTier` coherent. Not pursued, and the single-tier rule is not up for
change to enable it.

**Expose provenance only through `HookInfo`.** Would have kept the whole
feature inside the hook API, but it answers a question callers ask after
`parse*` returns just as often as during dispatch, and it would have left
the CLI tier privileged over the other two for no reason.

**Show `seenBy` in help text.** Out of scope; help output describes a
spec, not one invocation of it.
