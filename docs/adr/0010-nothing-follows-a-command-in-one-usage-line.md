# Reject anything sequential after a Command atom at spec-construction time

ADR 0009 documented, empirically, that "at most one Command can ever be
matched per spec level": `tokenizeArgs` (`src/argumint/fsm.nim`) recognizes a
command word and recurses into *that* command's own nested spec for every
remaining token, returning immediately -- permanently handing off the rest
of the args array to that command's own scope. It noted that a Usage String
isn't structurally required to keep sibling commands mutually exclusive:
`usage = "foo bar"`, with both `foo` and `bar` declared as distinct Commands
in the same spec, compiled without error, but `bar` could never actually be
reached at runtime -- it would fall through to "unexpected argument"
instead.

[#2](https://github.com/squattingmonk/argumint/issues/2) asked for this to
become a `SpecDefect` raised when the Usage Line is compiled, not a
confusing runtime failure discovered only by trying real input against the
grammar.

## Decision

`src/argumint/parser.nim`'s `atom`, `choice`, and `sequence` now thread a
`seenCommand: bool` parameter down and return a `hasCommand: bool` alongside
their existing `(a: State, b: State)` states. `atom` raises `SpecDefect` the
moment it's asked to parse anything at all while `seenCommand` is already
`true` -- a blanket guard at the top of the proc, before the atom's own kind
is even inspected. `sequence` feeds each successive child's OR-accumulated
`hasCommand` back in as the next child's `seenCommand`, so it applies within
one linear chain; `choice` passes the *same* `seenCommand` to every
alternative (so `(foo | bar)` alone stays legal -- alternatives never run
together) but returns the OR of all of them, so `(foo | baz) bar` is still
rejected: the `foo` branch alone hits the bug once `bar` follows, even
though the `baz` branch on its own would be fine. This is deliberately
conservative, matching `SpecDefect`'s whole-grammar-at-construction-time
nature rather than trying to reason per-alternative at runtime.

### Broader than "a second Command"

The issue's own framing was scoped to "detect a second Command atom." The
actual root cause is broader: once `tokenizeArgs` hands off to a matched
Command's own nested spec, it swaps *which spec's tables* classify every
token after it, so *any* atom from the outer spec following a Command
sequentially is unreachable -- not just a second Command. Non-Command atoms
have it worse than a clean "unexpected argument" failure: a plain positional
or option isn't validated by name at tokenize time, so it can be silently
*misattributed* to the inner command's own matching Arg if that command's
own grammar happens to accept a similarly-shaped token, rather than erroring
at all. The check was generalized to "nothing may follow a Command
sequentially" to close this whole class, not just the two-Command case --
and it was simpler to implement this way too: one blanket guard at the top
of `atom`, rather than a check specific to the `tkCommand` branch.

### Bracket/paren groups don't get a pass

`[...]` and `(...)` each recurse into a *new* `sequence()` call from
`atom`'s `tkParensOpen`/`tkBracketOpen` branches. A check implemented as a
flag local to one `sequence()` call frame would miss `usage = "[foo] bar"`
or `"(foo) bar"` -- `foo` is parsed in the nested call, `bar` in the outer
one, so they'd never share a same-frame-local flag, even though grouping
doesn't change how `tokenizeArgs` scans tokens at runtime. `atom`'s
`tkParensOpen`/`tkBracketOpen` branches pass `seenCommand` down into their
nested `sequence(seenCommand = seenCommand)` call and return its
`hasCommand` back up, closing this gap.

### Pure parameters, not a `SpecParser` field

`SpecParser` already has one precedent for mutable per-line state
(`explicitOptions`, reset each iteration of `genFsm`'s line loop). A
`seenCommand`/`hasCommand` field on `SpecParser` was considered and
rejected: it would need exactly the right reset scoping to avoid leaking
between a nested command's own compile and the outer spec's compile.

Concretely: if a top-level spec has sibling Commands `a`/`b`, and `b` is
*also* used as `a`'s own subcommand (reached via `a`'s own nested Usage
Line, e.g. `usage = "b"`), that must not raise `SpecDefect` -- it's the
ordinary, fully-supported subcommand-of-a-subcommand pattern. This already
holds by construction: a Command's own nested spec is fully compiled, in
its own `SpecParser` instance (`parser.nim`'s `genFsm`), *before* the outer
spec's `genFsm` runs at all (`command*` in `src/argumint.nim` finishes
`newSpec`/`genFsm` before returning the `CommandArg`) -- the outer `atom`'s
`tkCommand` branch just splices in the already-finished `cmd.spec.fsm`, no
further parsing recursion into it. With `seenCommand`/`hasCommand` threaded
as pure parameters and return values, there is no shared mutable state for
the two compiles to leak through at all -- they're separate call trees with
separate local variables, by construction, not by careful reset discipline.
A field-based implementation would have needed to get that reset exactly
right by hand; the parameter-based one makes getting it wrong not typecheck.

Covered by a dedicated test in `tests/test_argumint.nim`'s `"Commands"`
suite: the same `CommandArg` reused both as a top-level sibling and as
another command's own nested subcommand, exercised both ways, must compile
and dispatch correctly with no `SpecDefect`.

## Considered options

- **A `HashSet[Arg]`/`bool` field on `SpecParser`**, following the
  `explicitOptions` precedent: rejected in favor of pure parameter/
  return-value threading -- see above.
- **Scope the check to "detect a second Command atom" only**, per the
  issue's literal wording: rejected -- the actual bug is broader (see
  "Broader than 'a second Command'" above), and a Command-specific check
  would still leave the silent-misattribution case for non-Command atoms
  unaddressed.
- **Track Command *identity*** (which specific Arg was seen), to
  distinguish `foo foo` from `foo bar`: rejected -- the runtime bug is
  purely structural, any atom after an earlier Command breaks identically
  regardless of which Command it was, so a plain `bool` is sufficient.

## Out of scope

`cmd...` (a single Command with a trailing repeat) shares the same root
cause -- after the first match, all remaining tokens, including a second
literal occurrence of the same command word, are handed to the matched
command's own nested spec -- but isn't caught by this fix: `...` wires a
self-loop shortcut edge (`atom`'s repeat handling) without a second call to
`atom`, so no second token ever flows through the `seenCommand` check. Left
as a known, unaddressed edge case rather than silently claiming full
coverage.
