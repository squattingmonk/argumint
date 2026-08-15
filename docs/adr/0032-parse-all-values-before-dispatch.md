# Every matched level's values are parsed before any hook fires

Value Precedence has three supplied tiers, and until now they disagreed
about when a bad value is reported. `applyFallbacks`
(`src/argumint/fsm.nim`) runs to completion before `dispatch` is ever
called, and its `setFromEnv`/`setFromConfig` calls route through
`parseImpl` (`src/argumint.nim`) — so the environment-variable and Config
Source tiers are already converted and validated up front. Only the
command-line tier was deferred, into `dispatch`'s per-level
`parseOwnValues`.

The same arg, the same bad value, two tiers:

```
$ APP_PORT=abc app go
ParseError: expected int for APP_PORT but got "abc"     # no hook ran

$ app go --port abc
[top before] SIDE EFFECT                                # hook ran
[top after] cleanup
ParseError: expected int for --port but got "abc"
```

A parent's `before` hook fires its side effects — opening a database,
configuring logging, taking a lock — for an invocation that was never
going to reach an `action`. `after` does run, so cleanup is symmetric,
but the work happened at all only because the offending value arrived on
the command line rather than from the environment.

The same deferral leaves a window in which a hook reads stale values:

```
$ app go --port 8080 hello
[top before] child port reads as 0        # walk already matched 8080
  [child before] port=8080
```

The walk had matched `8080` before any hook ran; only the conversion had
not happened yet. So `HookInfo.matched` (ADR 0021), which is whole-tree,
disagrees with the values themselves, which are per-level — and issue #22's
`seenBy`, also computed for the whole tree straight after the walk, would
inherit the same disagreement.

## This was never a decision

Before ADR 0009, `parse*` parsed the entire `MatchTable` — every level, one
flat pass — and only then invoked command handlers. ADR 0009's own history
section says so: handlers ran "only after every value in the entire tree
(at every depth) was already parsed."

Per-level parsing arrived as collateral when `dispatch` became recursive.
ADR 0009's **Considered options** lists six rejected alternatives and none
of them concerns parse scope. `Match.spec` was added by that ADR to scope
*dispatch* — to tell two independent matches of a shared `Arg` at two
grammar levels apart from one match seen twice — and `parseOwnValues`
filtered on it because the mechanism happened to be there.

What ADR 0009 *did* decide is strictly weaker than what shipped. Its
iteration 3 was rejected because a level's `before` fired before **its own**
values were parsed, leaving no hook with access to a command's own flags
except `after`. That requires "a level's values are parsed before its
`before`", and says nothing about deeper levels. Parsing the whole tree
satisfies it as a superset.

### Hooks cannot influence descendant value parsing

The one hypothesis that would have justified per-level parsing is that a
`before` hook reconfigures something that changes how deeper levels parse.
ADR 0014 made `SpecSettings` a shared mutable ref for exactly that kind of
mid-parse reconfiguration. It does not reach value parsing:

| field | consumed by | reachable from a `before` hook |
| --- | --- | --- |
| `envDelim` | `applyFallbacks` → `resolveEnv` | no — already run before `dispatch` |
| `configSources` | `applyFallbacks` → `resolveConfig` | no — same |
| `width` | help/usage rendering | yes, via `parseMessageArgs` |
| `maxVariantsWidth` | help/usage rendering | yes, same |

Verified: a parent `before` hook setting `envDelim` from `:` to `,` has no
effect on a child's env-supplied `opts` — it still splits on `:`, because
`applyFallbacks` resolved and split it before the hook existed. The
reconfiguration ADR 0014 enabled lands entirely on message/help output,
which `parseMessageArgs` renders and which this ADR does not move.

`ValueArg`/`FlagArg` fields are private, so there is no other channel.

## Decision

Parse every matched level's command-line values in one pass before
`dispatch` starts:

```nim
walk
applyFallbacks          # env + Config Source tiers (unchanged)
parseAllValues          # CLI tier, whole tree
dispatch                # hooks only
```

`parseAllValues` is a flat loop over `matches` itself, which is already
the whole-tree answer — an `OrderedTable[Arg, seq[Match]]` populated
across the entire spliced FSM regardless of depth. It needs no spec-tree
recursion, no `Match.spec` filtering, and no dedupe pass: an Arg shared by
two levels holds all its matches under one key and is parsed exactly once.
Each arg's matches stay sorted by `Match.idx`, as `parseOwnValues` sorted
them (issue #8).

An earlier draft recursed the matched spec tree the way `applyFallbacks`
does, carrying a `HashSet[Arg]` so a shared Arg's matches weren't applied
twice, on the theory that visiting args in declaration order rather than
`matches` insertion order mattered. It doesn't. The only thing that could
observably differ is which error surfaces when two args both hold
unconvertible values, and both orders report the same one — checked with
two bad options under both an explicit `[--aa=<n>] [--bb=<n>]` usage line
and an `[options]` catch-all, in both typed orders. `matches` insertion
order tracks the walk, which tracks the grammar.

Sorting needs no level awareness. ADR 0010 — nothing may follow a Command
in one Usage Line — makes each level's tokens a contiguous run in
command-line order, with levels in depth order, so level-then-index and
global-index sorting produce the identical sequence. Verified against a
single `-v` flag shared by a parent and child spec: `-v go -v`, `go -v -v`,
and `-v -v go` all compose to 2.

`parseMessageArgs` does not move. It stays inside `dispatch`, after
`before`, inside the same `try/finally` as `action` — ADR 0013's position
that a matched Message Argument is conceptually that level's action, and
ADR 0014's requirement that a `before` hook's settings changes reach the
current level's own help output, both depend on it.

### A conversion failure beats a matched Message Argument

No `showsMessage` gate. If any value fails to convert, the parse raises,
even when `--help` matched — including from a level below the one the
Message Argument matched at:

```
$ app -h go --port abc
Usage: ...                      # before
ParseError: expected int        # after
```

This follows from ADR 0013 rather than being a fresh judgment. If a matched
Message Argument *is* that level's action for firing purposes, it inherits
that level's preconditions; an `action` would not run on input this bad, so
neither should a Message Argument. Skipping conversion instead would not
skip `before` — ADR 0013 deliberately fires it first — so every `before`
hook would run against nothing but coded defaults, which is a worse state
to hand a hook than an early error.

At a single level this is already the behavior: `app --port abc --help`
raises today and continues to.

## Considered options

**Skip the value parse when `showsMessage(info)` is true.** Preserves
`-h go --port abc` and additionally makes `app --port abc --help` print
help, which most CLIs do and which is defensible on its own — `--help` is
what you type when you do not know what a valid value looks like. Rejected
for the two reasons above: it breaks the Message-Argument-as-action
equivalence, and because `parseMessageArgs` runs after `before`, it would
leave hooks reading defaults on precisely the invocations where a hook is
most likely to be inspecting values to decide whether to bail out.

**Parse, but swallow conversion errors when `showsMessage(info)`.** Keeps
whatever converted cleanly available to hooks. Rejected: it leaves args
partially applied — a non-commutative Flag Operation composed halfway
through its sequence — and a `before` hook can observe that state with no
way to tell it apart from a complete one.

**Keep per-level parsing and rule that the predicates may disagree.**
Documents the window rather than closing it, and leaves values as the only
per-level thing a hook can see while `HookInfo.matched` and `seenBy` are
whole-tree. Rejected: the disagreement is not load-bearing for anything,
and the CLI tier firing hooks on invalid input is a defect in its own
right, independent of #22 or #28.

## Consequences

- A hook never fires for an invocation with an unconvertible or invalid
  value, on any tier. Previously true for env and Config Source, now true
  for the command line as well.
- `after` no longer runs when a command-line value fails to convert,
  because no `before` ran and nothing was entered to clean up.
- `app -h go --port abc` raises instead of printing help. This is the only
  behavior change for input that previously succeeded, and it needs a
  Message Argument at a shallower level than the failing value — which
  ADR 0010 confines to a Usage Line like `[-h] go`.
- Hook firing *order* is unchanged. `before` root-to-leaf, one `action` at
  the dynamic leaf, `after` leaf-to-root, with `after` guaranteed once
  `before` completes — ADR 0009's algorithm with only its step 1 hoisted
  out. The existing ordering tests pass unmodified.
- A `before` hook at any level now sees every matched level's values, not
  just its own. This is what ADR 0009's iteration-3 rejection wanted, one
  step further out.
- `value.isSome` and #22's `seenBy` can no longer disagree, since both are
  whole-tree and both settled before the first hook — which unblocks the
  storage-shape question in #28.
- `Match.spec` loses one of its three consumers but stays. The other two
  are load-bearing whenever an `Arg` is genuinely shared across levels,
  which is the case ADR 0009 introduced the field for. Verified by
  patching each out against a spec sharing one `help()` and one
  `command()` between a parent and child: dropping `matchedCommand`'s
  filter makes `app go stat x` dispatch `top -> leaf`, skipping `go`'s
  hooks entirely, and dropping `parseMessageArgs`' makes `app go --help`
  fire at the top level instead of `go`'s. `matchedCommand` also drives
  `applyFallbacks`' recursion, so it is on two paths. Note that ordering
  is `Match.idx`'s job (issue #8), never `Match.spec`'s.
