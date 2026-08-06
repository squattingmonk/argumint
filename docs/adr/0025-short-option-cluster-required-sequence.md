# An explicit short-option cluster expands to a required sequence; brackets around it stay all-or-nothing

Issue #9: a Short-Option Cluster written directly in a Usage Line (e.g.
`-abc`) is meant to be a required, non-repeatable atom -- `-a -b -c`, all
mandatory. Instead, `fsm.nim`'s `MatcherKind.Options` branch reports
success the moment *any one* of the cluster's options matches, silently
leaving the rest unmatched with no error. Root cause: `parser.nim`'s
`atom()` (`tkShortOptions` branch) builds an explicit cluster with the same
`newOptsMatcher`/`MatcherKind.Options` machinery the `[options]` catch-all
uses (`tkAnyOption` branch, see ADR 0002), so `match()` had no way to tell
"explicit cluster, every letter mandatory" apart from "catch-all, any one
option is enough, and it repeats."

## Decision

1. **`-abc` is syntactic sugar for the sequence `-a -b -c`.** `parser.nim`'s
   `tkShortOptions` branch stops building one shared `Options`-kind
   matcher and instead chains one ordinary `Option`-kind matcher per
   letter (`State.add` per option), the same chaining its sibling
   `tkShortOption`/`tkLongOption` branch already uses for a single
   separately-written option, in the order the letters appear in the
   cluster. Each letter becomes a genuinely independent, single-match,
   required atom -- indistinguishable, once built, from writing `-a -b -c`
   by hand. This is also what makes the fix land without inventing new
   FSM machinery: everything below falls out of already-existing generic
   handling once the cluster stops being special-cased.

2. **`MatcherKind.Options` becomes exclusive to the `[options]`
   catch-all.** No other code path constructs one after this change. This
   is what actually removes the bug's root cause -- the catch-all's
   any-one-succeeds/repeat semantics (correct for `[options]`, see ADR
   0002) no longer has a second, incompatible caller pretending to be the
   same matcher kind.

3. **`[-abc]` wraps that same chain in the ordinary bracket
   shortcut-bypass (`tkBracketOpen`) and is all-or-nothing** -- typing any
   one letter without the rest is a `ParseError`, same as every other
   bracketed multi-atom sequence in argumint already behaves (confirmed
   against `main` before this change: `[<x> <y>]` and `[-a -b]` already
   reject a partial match today via the existing `addShortcut`
   bypass-the-whole-sequence construction; this was previously untested
   and undocumented, not a new rule invented for this ADR). No
   content-type special-casing: a bracketed group behaves the same
   whether it holds Positional Arguments, Options, Flags, a Command, or a
   cluster -- one rule, regardless of what's inside.

4. **`-abc...` / `[-abc]...` repeats the whole cluster as a single unit**,
   via the existing generic `...` handling in `atom()`
   (`result.b.addShortcut(result.a)`) -- not per-letter. Same as any other
   atom, parenthesized group, or bracketed group followed by `...`.

5. **No flattening** (docopt's `-a --alpha`-independent-optional behavior
   for a bracketed multi-atom group). See Considered Options for why this
   was explicitly evaluated and rejected rather than just not considered.

New domain term for `CONTEXT.md`: **Short-Option Cluster**.

## Considered options

- **mow.cli-style: treat the cluster as `(-a | -b | -c)...`** (any subset,
  any order, repeatable) -- this is genuinely what mow.cli does; its
  `TTOptSeq` grammar production reuses the exact same `matcher.NewOptions`
  constructor its `[options]`-equivalent catch-all uses, and that
  matcher's `Match` loops, succeeding as soon as any one option in the
  group matches and trying again for more. Rejected: it directly
  contradicts ADR 0002's own already-decided rule that an Option/Flag
  *explicitly named* in a Usage Line defaults to single-required-match,
  with repeat-by-default reserved for whatever's reachable *only* through
  `[options]`. A `-abc` cluster is explicit naming of three options: by
  argumint's existing rule each should require exactly one match, not
  "any one is enough." mow.cli's behavior here reads as an artifact of
  matcher reuse, not a deliberately chosen semantic -- confirmed via
  reading `internal/parser/parser.go` and `internal/matcher/options.go`
  directly, not inferred from the README.

- **docopt(.nim)-style: flatten a bracketed cluster to independent
  optionals** (`[-abc]` == `[-a] [-b] [-c]`) -- also genuinely what
  docopt.nim does; its `Optional.match` iterates each child pattern
  independently and unconditionally reports success, and `[options]`
  (`AnyOptions`) is nothing but an `Optional` auto-populated with every
  declared option, so a hand-written `[-abc]` really is "a scoped
  `[options]`" there. Rejected for two reasons, found only by checking
  what flattening would actually require:
  - `Optional.match` has no type-based branching at all -- it treats an
    `Argument` child exactly like an `Option` child. Faithfully porting
    "brackets flatten" therefore isn't an options-specific rule; it would
    have to apply to *every* bracketed multi-atom group, including
    Positional Arguments. `[<src> <dest>]` would stop requiring both
    together -- typing just `<src>` would parse successfully with
    `<dest>` silently unset. That's a known docopt surprise, not a
    property worth importing.
  - A middle ground -- flatten only when every atom inside the brackets
    is an Option/Flag, stay all-or-nothing otherwise -- was considered
    once the above ruled out full parity. Rejected: it isn't what either
    prior-art library actually does (docopt.nim doesn't special-case by
    content type; mow.cli's repeat-by-default cluster behavior is
    unconditional, not bracket-gated), so it wouldn't be adopting
    precedent, it would be inventing a third, novel rule. It also has no
    clean answer for mixed content (`[-a <x>]` -- does `-a` flatten out
    while `<x>` stays required-if-present?), and would require the parser
    to detect "is this bracket's content entirely Option/Flag atoms" and
    switch FSM construction strategy accordingly -- meaningfully more
    complexity and backtracking for a behavior with no settled
    real-world precedent to justify it.
  - Keeping brackets uniformly all-or-nothing avoids both problems: one
    rule, independent of content type, matches what the FSM already does
    today for every other multi-atom bracketed group, and needs no new
    machinery.
