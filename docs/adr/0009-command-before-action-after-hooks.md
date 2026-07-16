# Replace `CommandArg.handler` with `before`/`action`/`after` hooks on `Spec`

`CommandArg.handler: proc()` fired once, flatly, whenever a Command was
matched -- with no way to distinguish "before this command's own logic
runs" from "after its whole subtree is done," and no way for anything
above the matched leaf to participate at all. ADR 0003 anticipated a
redesign here: "May become moot anyway if `CommandArg` moves from a single
`handler` to separate before/after hooks."

The design went through several iterations before landing:

1. **therapist's model** (argumint's original fork ancestor): a single
   handler per command, invoked leaf-to-root as parsing recursed back out
   of nested subcommands.
2. **argumint's shipped model** prior to this change: inverted that --
   commands were collected during a flat pass and their handlers invoked
   root-to-leaf, in the order commands were seen, only after every value
   in the entire tree (at every depth) was already parsed.
3. **A first two-hook attempt** (`before`/`after`, scoped to `CommandArg`,
   "hierarchical wrap" semantics: before fires before a command's own
   subtree is touched at all, after once it's fully done) had a usability
   flaw: since before fired before even that command's own values were
   parsed, no hook had access to a command's own flags except after --
   which only fires once the entire subtree, including any nested
   command, is done. That forces any real per-command logic into a strict
   leaf-to-root execution order, the same problem therapist's design had,
   just relocated.
4. **mow.cli's model** resolves this: `Before`/`After` hooks exist at
   every level (app, command, subcommand) and run with already-parsed
   values available; a single `Action` runs only once, at the leaf; Before
   hooks run root-to-leaf, then the leaf's Action, then After hooks run
   leaf-to-root; a failure partway through still lets every
   already-entered ancestor's After run, for cleanup (verified directly
   against mow.cli's source: `internal/flow/flow.go`'s `Step.Run`/
   `callDo`, and `commands.go`'s `Cmd.parse`, which wires `Before`'s
   `Error` step to the *parent's* `After` step, and gives `After` both
   `Success` and `Error` pointing at the parent's chain, so it always runs
   once `Before` has -- functionally a manually-built `try/finally`).

## Decision

Adopt mow.cli's three-hook model, with one addition: hooks live on
`Spec`, not on `CommandArg`. `CommandArg` keeps only `spec*: Spec` --
`before`, `action`, `after` are fields on `Spec` itself
(`src/argumint/backend.nim`). This lets the top-level spec, never itself
wrapped by a `CommandArg`, carry hooks too (via new `before`/`action`/
`after` params on the tuple `parse*`/`parseOrQuit*` overloads,
`src/argumint.nim`), not just a matched command's own nested spec (via the
same three params on `command*`). This directly serves the motivating use
case: shared setup like configuring logging or opening a config file,
which a subcommand shouldn't have to redo or know about -- that belongs
at the app or router level, torn down symmetrically regardless of what
happens deeper in the tree.

Firing order, applied uniformly and recursively to every `Spec` in the
matched tree:

1. Parse this spec's own non-command values.
2. If set, call `spec.before()` -- has access to this spec's own
   just-parsed values.
3. Determine whether a Command was actually matched at this spec's own
   level for *this* invocation (dynamic, not a static property of how the
   spec was declared -- a command invoked bare behaves differently from
   one that routes into a subcommand): none matched means this spec is
   the dynamic leaf, so call `spec.action()` if set; one matched means
   recurse into it, applying this same algorithm to its own nested spec.
4. If set, call `spec.after()` -- guaranteed to run if steps 1-2 completed
   without raising, regardless of whether step 3 succeeds or raises. A
   failure anywhere below a given level unwinds through every ancestor
   that had already completed its own `before`, running each one's
   `after` in turn, purely from nested `try/finally` -- no explicit
   bookkeeping needed. A level whose own value-parsing or `before` itself
   raises never runs its own `after` (it never fully "entered"), but the
   exception continues propagating into its caller's own `finally`, which
   does.

`after`'s body isn't told whether it's running after a normal completion
or as part of a failure-triggered unwind -- same as an ordinary `finally`
block. Checked directly against mow.cli's source: `Before`/`After`/
`Action` are plain `func()` there too, and the internal error value
threaded through its `Step.Run` chain is never passed into the hook
body, only used for the dispatcher's own control-flow decisions. This was
a considered omission, not an oversight.

### `Match` gains Spec provenance

`Spec.args` reflects which `Arg` refs were included in a tuple at
`newSpec`-construction time, not which grammar position actually matched
a given occurrence -- so if the same `Arg` is genuinely reachable at two
different grammar levels (e.g. a shared `--verbose` honored both before
and after a subcommand word), a scoping scheme based on `Arg` identity
alone can't tell two independent real matches apart from one match seen
twice. `Match` (`src/argumint/fsm.nim`) gained a third field, `spec:
Spec`, tagging each match with the Spec it was recorded under at
match-time (`pc.spec`, read inside `match`'s four `push` call sites,
before it's later overwritten as the walk descends further). This is a
new requirement specifically because dispatch became per-Spec-level-scoped
with this change -- the old flat dispatch never needed to know which
level a match came from.

At most one Command can ever be matched per spec level. This was worth
verifying empirically rather than assuming: a Usage String isn't
structurally required to treat sibling commands as mutually exclusive
(`usage = "foo bar"` with both declared in the same spec compiles without
a `SpecDefect`), but `tokenizeArgs` (`src/argumint/fsm.nim`) recognizes a
command word and then recurses into *that* command's own nested spec for
every remaining token, returning immediately -- permanently handing off
the rest of the args array to that command's own scope. A sibling command
word appearing later in the input is never re-classified as a
Command-kind token once this hand-off happens.

### No `Variant` parameter on hooks

CONTEXT.md's Command entry claimed a handler "could still branch on which
Variant was actually seen" -- verified false: `handler`/the new hooks
never actually received the matched Variant. Rather than add a `variant`
parameter to every hook to make that true, a caller wanting different
behavior per Variant should declare separate `command()` entries
(optionally sharing one underlying proc, parameterized differently at
each call site) rather than branch inside a shared hook. This matches
Command's own definition -- a Variant is an alias for the *same*
subcommand, not a signal for different behavior -- and avoids a parameter
every caller pays for.

### Clean break, no back-compat alias

`handler` is removed outright. argumint is unpublished 0.1.0 with no
tags and no known external consumers, so there's no compatibility surface
to preserve.

## Considered options

- **Shallow before/after split** (both hooks firing back-to-back at the
  same point today's `handler` fires): rejected -- can't express an
  outer/router command wrapping an inner leaf's dispatch, the main
  practical reason to want more than one hook.
- **Two hooks only, redefining `before` to fire after a command's own
  values are parsed** (rather than adding a third `action` hook):
  rejected -- conflates "just entered this command" with "this command's
  own values are ready," and loses the ability for a command invoked bare
  to behave differently from one that routes into a subcommand, which was
  a specific, deliberate design goal here.
- **Passing `variant: string` into every hook signature**: rejected, see
  above.
- **No failure-cascade handling, raw exception propagation only** (today's
  behavior): rejected -- the primary motivating use case is resource
  setup/teardown, where leaking a resource on a deep failure defeats the
  purpose of having hooks at all.
- **Deduplicating matches by `Arg` identity alone**, rather than tagging
  them with their owning `Spec`: rejected -- can't distinguish two
  independent real matches of a shared `Arg` at two different grammar
  levels from one match incorrectly seen twice.
- **Keep `handler` as a deprecated alias for `action`**: rejected -- no
  external consumers to protect, and the library is pre-1.0.

## Out of scope

A separate, pre-existing bug in the (untouched) env-var fallback loop
(`src/argumint/fsm.nim`'s `for arg in pc.spec.args:`) is tracked
separately rather than fixed here -- see
[#1](https://github.com/squattingmonk/argumint/issues/1).
