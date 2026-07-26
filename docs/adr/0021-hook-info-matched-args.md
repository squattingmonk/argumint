# `before`/`action`/`after` receive a `HookInfo` with matched Args

`examples/completion.nim` demonstrated a real usability gap: running
`examples/completion --help` printed "Connecting to the database..." (a
stand-in for expensive setup) before the help text, because the DB
connection ran directly in `main()`, guarded only by `isCompletionRequest()`
(ADR 0012). That guard only detects a shell-completion request -- a cheap
static check of `args[0] == "__complete"`. There was no equivalent way to
detect "this invocation is just going to print `--help`/`--version`/a
custom message and exit."

Unlike the `__complete` check, that can't be a static peek at `args[0]`:
`MessageArg`/`HelpArg` variants (`-h`/`--help`, `-v`/`--version`, or any
custom `message()` flag) are author-defined and can appear anywhere the
usage grammar allows, at any nesting depth. Detecting one genuinely
requires the FSM walk `parse*` already performs -- `fsm.nim`'s
`MatchTable`, built by `spec.fsm.walk(pc)`, already knows exactly which
Args matched by the time `dispatch` starts.

A first draft of this feature added a standalone `isMessageRequest*(spec,
args)` guard, mirroring `isCompletionRequest*`'s calling convention, that
redid the walk on demand. Rejected: it duplicates work `parse*` already
does for every real invocation (a second, throwaway walk on top of the
real one that follows), and it only answers one narrow question ("did a
MessageArg match") when the underlying match data is useful for more than
that.

## Decision

Add `HookInfo` (`src/argumint/backend.nim`), a small value carrying every
Arg matched during the invocation:

```nim
HookInfo* = object
  matched*: seq[Arg]
```

Compute it once in `fsm.parse*`, from the same `MatchTable` the walk
already produced -- no extra walk, no change to `applyFallbacks` (a
`MessageArg`'s `envName` base case already returns `""`, so it's never
fallback-populated; `pc.matches` alone is a complete answer):

```nim
let info = HookInfo(matched: matchedArgs(pc.matches))
dispatch(spec, pc.matches, command, info)
```

Thread `info` unchanged through `dispatch`'s recursion, passing it to
`before`/`action`/`after` at every level:

```nim
proc dispatch(spec: Spec, matches: MatchTable, command: string, info: HookInfo) =
  parseOwnValues(spec, matches, command)
  if not spec.before.isNil:
    spec.before(info)
  try:
    parseMessageArgs(spec, matches, command)
    let (cmd, variant) = matchedCommand(spec, matches)
    if cmd.isNil:
      if not spec.action.isNil:
        spec.action(info)
    else:
      dispatch(cmd.spec, matches, "{command} {variant}".fmt, info)
  finally:
    if not spec.after.isNil:
      spec.after(info)
```

Add a convenience accessor for the concrete motivating case:

```nim
proc showsMessage*(info: HookInfo): bool =
  for arg in info.matched:
    if arg of MessageArg:
      return true
  false
```

`Spec.before`/`action`/`after` (`backend.nim`) change from `proc ()` to
`proc (info: HookInfo)`. Every public hook-accepting signature --
`command*[S]`, `command*[S, O]`, `parse*[S: tuple]`, `parseOrQuit*[S:
tuple]` (`src/argumint.nim`) -- gains a matching `info: HookInfo` parameter
on `before`/`action`/`after`, and their internal wiring closures pass it
through.

This makes `info.matched` a flat view across the *whole* matched dispatch
chain, not scoped to the receiving hook's own spec level -- by design, so
an ancestor's `before` (e.g. a `ship` router command) can see
`info.showsMessage: true` even when the actual matched `HelpArg` belongs to
a nested `move` spec several levels down. `MatchTable` already carries this
information keyed by Arg across every level (via `Match.spec` provenance),
so no extra bookkeeping is needed to expose it this way.

With this, `examples/completion.nim`'s DB connection becomes a real
`before` hook instead of ad hoc `main()` code:

```nim
built.before = proc(info: HookInfo) =
  if not info.showsMessage:
    connectToDatabase()
```

This also means `isCompletionRequest()` is no longer needed for *this*
guard: a `__complete` request short-circuits before `dispatch` ever starts
(`fsm.nim`'s `parse*`), so `before` simply never fires for one -- one hook
now covers both the completion case and the message case.
`isCompletionRequest()` isn't obsoleted by this, though -- it still matters
for setup that must happen before `parse*`/`parseOrQuit*` is even callable,
e.g. before the `Spec` itself is constructed.

## Rejected alternatives

- **Standalone `isMessageRequest*(spec, args)` guard, redoing the walk**:
  the first draft of this ADR. Rejected for the redundant-walk and
  narrow-scope reasons above.
- **Keep `before`/`action`/`after` signatures unchanged; inject `HookInfo`
  via a global/threadvar the hook reads with a zero-arg accessor**:
  considered as a non-breaking alternative (a nested command's `before`
  hook only receives `spec: S` -- the tuple of args declared *inside* that
  command -- never a reference to its own backend `Spec`, so there's no
  in-scope object to query `info` from without either a new parameter or
  global state). Rejected: this codebase has no other global mutable
  state, `Spec.settings` (the one existing "shared, cross-tree state"
  mechanism) is a deliberately explicit shared *reference*, not a global,
  and a global would need careful push/pop discipline around every hook
  call to stay correct under a `before` hook that itself calls `parse*`
  again (the exact pattern `examples/config_bootstrap.nim` already uses).
- **Additive `beforeInfo`/`actionInfo`/`afterInfo` params alongside the
  existing non-breaking ones**: avoids breaking existing call sites, but
  doubles the hook-parameter surface (six params instead of three) and
  needs validation against setting both the plain and `Info` variant of
  the same hook. Rejected in favor of a clean break, consistent with ADR
  0009's own precedent (replacing `CommandArg.handler` outright, no
  deprecated alias) -- argumint is pre-1.0 and unpublished, so a breaking
  change here costs a one-line mechanical edit per existing hook (add
  `, info: HookInfo` to its signature) rather than permanent extra surface
  area.

## Consequences

- Breaking change to every `before`/`action`/`after` call site. Every
  in-tree example (`naval_fate.nim`, `git.nim`, `completion.nim`,
  `config_bootstrap.nim`) and test needed updating to add the new
  parameter.
- `info.matched` only reflects CLI-driven matches (`MatchTable`), not
  env/Config Source fallback values -- consistent with `MessageArg` never
  being fallback-populated, and keeps `HookInfo` computable before
  `applyFallbacks` runs.
