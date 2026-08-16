# Strict Option Checking: an option-shaped token is never silently data

Narrows ADR 0019.

`docs/adr/0019-lazy-token-classification.md` moved token classification into
the walk. Its gap 3 was that "an unrecognized option-shaped token raised
`ParseError` immediately, even when a different, not-yet-tried Usage Line
alternative would have accepted it as opaque literal text." The fix was
`classify`'s bottom line: anything resolving against nothing in
`spec.options` falls through to `Positional`, and any matcher that accepts
positional text takes it as opaque literal data.

That is right for a grammar that genuinely wants dash-leading literal text.
It produced three defects, all verified against the tree before this change:

1. **The catch-all positional slot.** With `myapp [options] <file>...` —
   `cp`, `rm`, `grep`, `tar`, any linter — an unrecognized option is absorbed
   with no error. `--nope` lands in the catch-all, `--por 80` lands as two
   values, and a typo'd `--recrusive` silently becomes a filename. Drop the
   catch-all and the same inputs correctly report `unrecognized option`.
2. **The option value slot, which needs no catch-all at all.** With a single
   declared `-n, --name=<s>` and a bare `[options]` usage line,
   `--name --help` silently set `name` to the string `"--help"` instead of
   showing help.
3. **A starved option was misreported.** `--port` alone produced
   `unrecognized option --port` — but `--port` *is* declared. The
   leftover-token complaint could not tell "name unknown" from "name known,
   no value available", because `classify` collapsed both into the same
   `Positional` fallback.

## Decision

Add `strictOptions` to `SpecSettings`, defaulting to **`true`**. It governs
whether an option-shaped token may be treated as data, in both the
positional slot and the value slot.

`SpecSettings` is shared by reference with every nested subcommand spec, so
strictness is uniform across a command tree by construction — no per-spec or
per-Arg override. Deliberate: the granular "this positional accepts
dash-leading text" case is already solved declaratively by ADR 0020's
usage-string `--` marker, which forces the split without the user typing
anything and is visible in generated `Usage:` output.

### Non-Option Short, not "parses as a number"

The exempt class is defined purely by token shape: **a token with a single
leading dash whose second character is not an ASCII letter**. `-5`, `-12`,
`-3.5`, `-.5`, `-1e9`, `-5.`, `-0x1F`, `-+3`, `-5x`, `-1_000` are always
accepted as literal text. Two leading dashes never qualify.

This exists because `OptionFormat`'s `shortOption <- '-' \w` matches a
digit, so negative numbers carry `optShape` and reach a positional only via
the very fallback being closed — ADR 0019's gap 2 fix. Without an exemption,
`app -5` would need the leading-space escape again.

**`parseFloat` was considered and rejected.** It draws the boundary in the
wrong place in both directions: it admits `-inf` and `-nan`, which are
option-shaped names a user could plausibly declare, while rejecting `-0x1F`
and `-+3`, which are not names by any reading. A shape rule has no such
edges, needs no exception handling, and can be read off the token in one
comparison.

A *declared* spelling always resolves against the spec's tables several
branches earlier, so the exemption only ever applies to undeclared tokens: a
spec declaring `-1` as a flag continues to match `-1` as that flag, and
`-nan` against a declared `-n` is `-n` with the folded value `an`.

### A cluster remainder is not a Non-Option Short

> **Extended by [ADR 0038](0038-name-the-short-option-that-failed.md)**: this
> section settles that a remainder *errors*, but left it named whole, so
> `-1.5` reported `unrecognized option: -.5` — a token nobody typed, whose
> tail may hold declared options. The naming half is now specified there;
> what this section decides is unchanged.

**This deviates from the issue as written**, and was agreed in review. The
exemption is for tokens the user actually typed. With `-1` declared as a
Flag, `-1.5` is cluster syntax: it peels into `-1` plus a `-.5` remainder,
exactly as `-abc` peels into `-a -bc`. That remainder's `-.` resolves to
nothing, so it is an unrecognized option in precisely the way `-1x`'s
leftover `-x` is — and `-.5` satisfies Non-Option Short by shape alone,
so the rule as stated would rescue a token nobody wrote.

`fromCluster` identifies peeled remainders and `exemptFromStrict`
withholds the exemption from them. `-1.5`, `-1x`, and `-1abc` now fail
identically, while a directly-typed `-.5` still parses. Only Flags are
affected: `classify` folds an Optional's `-1.5` into `-1=.5` at the
`-ovalue` branch, so it yields a value and never reaches the gate.

### Refuse to match, don't raise

The `Argument` matcher declines a refused token the same way it already
declines `Optional`/`Flag`-classified ones; the token ends up leftover at a
terminal state, where the existing complaint machinery words the error.
This preserves backtracking — other usage-line alternatives, and nested
specs reached after a command descent, still get their chance — and reuses
the did-you-mean suggestion already living on that path rather than
duplicating it. `classify` still never raises, so ADR 0019's invariant that
every failure surfaces through the walk holds.

### The starved case is unconditional

`classify` grows a non-accepting outcome (`starvedOpt`/`starvedName`) for a
declared Optional with no value available. An option with nothing at all
following it is an error under **both** settings, worded
`option --port requires a value`. With strict checking off an option-shaped
token still counts as a value, so `--name --help` does not starve there;
starvation only becomes reachable at end of input.

The complaint is added even when other messages exist, unlike the
leftover-token wording it sits beside. It has to be: a starved option can
never be consumed as anything else, so it is always the real error. `--name
-q` therefore reports both the starved option and the unrecognized `-q`
rather than one masking the other — but only when the starving token really
is unknown. `--name --port 80` names neither token unrecognized, since
calling a declared option unrecognized is the very wording this ADR exists
to correct.

Reaching every failure path takes more than computing that classification
once. Four ask the question, and two of them never see a leftover token at
a terminal state: the `[options]` catch-all deliberately rolls back each
failed probe's messages, discarding a starved complaint a probe already
produced, and the `Argument` matcher reports its own `missing argument` and
stops. So `addStarved` classifies the leading token for itself and each
path asks independently — the catch-all *after* its rollback. Threading one
precomputed answer through instead leaves the complaint reachable only via
some other usage line, which is how a `help()`-less `[options]` spec lost
it, and how `app <x> <y> [--speed=<kn>]` reported only `missing argument:
<y>` for `app 1 --speed`.

### End-of-options is checked at the gate, not inherited

Once a path is past end-of-options, `classify` short-circuits to `Positional`
above any option-shape reasoning. That makes the result indistinguishable
from an unknown option's, so the gate consults `pc.optsEnd` directly rather
than reading exemption off the classification. With that one check, both the
CLI-typed `--` and the ADR 0020 usage-string marker exempt their whole region
with nothing per-token. ADR 0020 point 3 flags the marker's interaction with
`[options]`'s repeat-loop `Shortcut` as worth confirming empirically;
`[options] -- <rest>...` routing a whole dash-leading region is pinned in
`tests/test_strict_options.nim`.

## Considered options

- **Strict by default.** Chosen. The setting is additive; its default is not,
  which is why this lands before 1.0 — flipping it afterwards would silently
  change whether an existing CLI accepts input it used to.
- **Permissive by default, opt in.** Zero upgrade friction and no need to
  block 1.0. Rejected: it leaves the silent wrong answer as the out-of-box
  behavior and merely defers the same break to a point with more users.
- **A per-Arg strictness override.** Rejected; ADR 0020's marker covers the
  granular case declaratively and shows up in `Usage:`.
- **Gating only the positional slot.** Rejected: the value-slot absorption
  needs no catch-all at all, so it is the broader of the two defects.

## Consequences

- **Breaking.** A CLI whose grammar has a catch-all positional, or which
  passed dash-leading values positionally, now raises `ParseError`.
  `strictOptions = false` restores the old behavior for both slots — except
  the starved case, which is an error either way.
- **Also breaking for the value slot**, independently of any catch-all:
  `--name --help` used to set `name` to `"--help"`.
- Exactly one pre-existing test changed meaning: ADR 0019 gap 3's own
  regression test in `tests/test_cli_syntax.nim`, now asserting both halves.
  Every negative-number test survives via Non-Option Short, and every
  dash-literal test already used the marker or the leading-space form.
- `--5` is *not* option-shaped (`longOption` needs two characters after the
  dashes), so it remains plain literal text. Outside this feature rather than
  a hole in it; pinned in tests because it looks like one.
- Shell completion needed no special case: `collectFrontier` walks the same
  `match` path, so an already-invalid prefix yields no candidates and the
  shell's own file completion takes over. `completeArgs` still never raises.
- `DefaultStrictOptions` is exported, since `newSpecSettings*` spells it as a
  parameter default — the rule ADR 0030 applied to
  `DefaultMaxVariantsWidth`/`DefaultEnvDelim`.
- The issue asked for this to be ADR 0031; that number was already
  `parsed-fresh-spec-per-parse` by the time the work started, and 0033 was
  claimed on an in-flight branch, so it is 0034.
