# `MessageArg`/`HelpArg` parse after `before`, inside `after`'s guarantee

ADR 0009 established `before`/`action`/`after` firing root-to-leaf/leaf/
leaf-to-root around `dispatch`, with `after` guaranteed to run once
`before` has completed, success or failure, via nested `try/finally`. It
didn't account for `MessageArg` (`help()`, `message()`, `version()`;
`HelpArg` is a subtype of `MessageArg`) at all: `parseOwnValues`
(`src/argumint/fsm.nim`) parsed every non-`Command` match at a spec's own
level -- including any matched `MessageArg` -- in one pass, and
`MessageArg.parse`/`HelpArg.parse` (`src/argumint.nim`) raise
`MessageError`/`HelpError` immediately and unconditionally. Since this
happened before `dispatch` ever reached `spec.before()`, matching `--help`
(or any message flag) at a spec's own level meant `before` and `after`
never fired at all for that level -- the raise unwound straight out of
`dispatch` before either hook was entered.

This surfaced as a real limitation once `Spec.width`/`maxVariantsWidth`/
`envDelim` moved to a shared, mutable `SpecConfig` ref cascaded by
reference to nested specs (rather than copied by value): a `before` hook
that reconfigures `Spec.config` -- e.g. to change help-text wrapping based
on some runtime condition -- only actually applied to *descendant* specs'
`--help` output, not the current level's own, since the current level's
`--help` had already raised before `before` ran.

## Decision

Split `parseOwnValues` in two: it now parses only non-`Command`,
non-`MessageArg` matches, leaving `MessageArg`/`HelpArg` to a new
`parseMessageArgs` proc, called from `dispatch` *after* `spec.before()`,
and *inside* the same `try/finally` that already guards `spec.action()`/
recursion:

```nim
proc dispatch(spec: Spec, matches: MatchTable, command: string) =
  parseOwnValues(spec, matches, command)
  if not spec.before.isNil:
    spec.before()
  try:
    parseMessageArgs(spec, matches, command)
    let (cmd, variant) = matchedCommand(spec, matches)
    if cmd.isNil:
      if not spec.action.isNil:
        spec.action()
    else:
      dispatch(cmd.spec, matches, "{command} {variant}".fmt)
  finally:
    if not spec.after.isNil:
      spec.after()
```

A matched `MessageArg` is, conceptually, this level's action for the
invocation -- the thing that happens instead of running `action` or
recursing into a nested command. Treating it exactly like `action` for
firing purposes (after `before`, inside `after`'s `try/finally`) is more
consistent than the ad hoc "silently skips both hooks" behavior it had
before, and gives it the same two guarantees `action` already had:
`before`-time state is visible to it, and `after` still runs as cleanup
even though it raises rather than returning.

Regular (non-message) value/flag parsing is unchanged -- it still happens
in `parseOwnValues`, before `before`, so `before`'s existing contract
("fires once this spec's own values are parsed") stays accurate. Relative
precedence between value validation and message-arg matching is also
unchanged: a `ValidationError` from a regular arg still surfaces before a
message arg gets a chance to raise, since `parseOwnValues` still runs
first.

This is a real, intentional behavior change: `before`/`after` now fire
around a matched `--help`/`--version`/custom message, where previously
neither did. No test exercised the old behavior, so nothing regresses --
this closes a gap rather than breaking a documented contract.

### Known, accepted limitation: `envDelim`

`Spec.config.envDelim` doesn't get the same benefit. The env-var fallback
sweep (`fsm.nim`'s `apply`) runs to completion across the *entire* matched
tree before `dispatch` is ever called at all -- so a `before` hook mutating
`envDelim` has no effect on that parse's env-var handling, regardless of
this change. `width`/`maxVariantsWidth` don't have this limitation because
they're only read inside `genHelp`/`raiseParseError`, which run during or
after `dispatch`.

## Considered options

- **Leave message-arg parsing in `parseOwnValues`, before `before`**
  (today's behavior): rejected -- makes `before`-time reconfiguration
  invisible to the current level's own message output, the motivating
  problem.
- **Move message-arg parsing after `before` but keep it outside the
  `try/finally`** (so `after` still wouldn't fire on a message-arg raise):
  rejected -- inconsistent with treating a matched message arg as this
  level's action-equivalent, and reintroduces the same "resource
  leaked because after didn't run" concern ADR 0009 exists to avoid, this
  time specifically for the message-arg path.

## Out of scope

The `SpecConfig` ref-sharing change that motivated this fix is tracked and
designed separately; this ADR only covers the hook-ordering fix, which
stands on its own regardless of whether that follow-up lands.
