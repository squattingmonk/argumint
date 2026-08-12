# A Flag's variants are mutually exclusive across usage-string alternation only when they're FlagOp Aliases

Issue #8: a Flag's variants weren't checked against each other across a
usage-string alternation group (or even a plain sequence) when they
carried different Flag Operations. Given `direction: flag[int]("--up=1,
--down=-1, --left=2, --right=-2")` and `usage = "(--up | --down) (--left |
--right)"`, typing `--up --down` was silently accepted instead of
rejected -- `(--up | --down)` is meant to mean "exactly one of these two,"
but Option/Flag matching in `fsm.nim` compared only `Arg` identity, never
which specific variant was typed, so both tokens satisfied the same
grammar position in sequence.

Fixing this naively -- rejecting any second same-`Arg` Flag token
regardless of which variant it names -- would break `-v`/`--verbose`-style
Flags, where several variants are supposed to keep meaning the same thing
and stay freely interchangeable. The fix therefore needed a way to tell
"these two variants are the same operation, just spelled differently"
apart from "these two variants genuinely conflict" -- this is what FlagOp
Alias (`CONTEXT.md`) names.

## Decision

1. **A Flag's variants partition into FlagOp Alias sets by identical `(op,
   arg)` spec text**, ignoring `desc`. `Arg.aliases(a, b)` (`backend.nim`,
   overridden per-type by `FlagArg[T]` in `argumint.nim`) answers whether
   two of a Flag's own variants are aliases of each other; the base `Arg`
   implementation returns `true` unconditionally, since a non-Flag Arg has
   no notion of per-variant behavioral difference to alias by.
   `Arg.aliases` is reflexive -- a variant is always its own FlagOp Alias
   -- so every call site can check `arg.aliases(a, b)` directly instead of
   special-casing `a == b` first.

2. **`Matcher` (`backend.nim`) gains a `variant` field** recording which
   specific variant (and therefore which FlagOp Alias set) an
   `Option`-kind transition represents, populated by `parser.nim`'s
   `atom()` wherever it builds an Option/Flag matcher. `fsm.match`'s `of
   Flag:` branch checks the seen token's variant against the matcher's own
   via `m.variant == c.flagName or m.opt.aliases(m.variant, c.flagName)`
   before accepting a match -- a token naming a non-aliased variant of the
   same Flag no longer satisfies that grammar position.

3. **`parser.choice()`'s alternation dedup keys on `(Arg, variant)` via
   `Arg.aliases`, not bare `Arg`.** A later alternative is redundant only
   if some earlier one already covers its exact `(Arg, variant)` -- so
   `(-v | --verbose)` still collapses to one required position (both are
   FlagOp Aliases), while `(--up | --down)` keeps both alternatives
   independently reachable, since typing one no longer counts as having
   typed the other.

4. **A non-aliased same-`Arg` token is skipped during a scan, not treated
   as a hard stop.** Flag matching already scans forward past unrelated
   tokens looking for its own match (order-independence, ADR 0019); a
   first draft of this fix made the `of Flag:` branch `break` the scan
   instead of skipping past a same-`Arg`-but-non-aliased token, which
   silently reintroduced order-dependence for a Flag's own variants
   (`-u -d` would parse but `-d -u` wouldn't, even though both are
   individually valid) and, in an even more broken intermediate state,
   blocked the scan for *any* other Flag entirely. Skipping restores full
   order-independence.

5. **Skipping alone isn't enough to keep composition correct**, because
   Flag Operations are often non-commutative (e.g. with `clamp`):
   composing them in usage-declaration order instead of true typed order
   would silently produce the wrong value once a Flag's variants can be
   satisfied out of order. `RawToken` gained an `idx: int` (original CLI
   argv position, inherited by a short-option cluster's peeled-off
   remainder tokens); `Match` carries it through as a fourth tuple field.
   `parseOwnValues`/`parseMessageArgs` sort a Flag's accumulated matches by
   `idx` (a stable sort) before applying operations, instead of relying on
   push order -- so `-u -d` and `-d -u` on the same usage line now compose
   in the order they were actually typed, regardless of which grammar
   position happened to match which token.

6. **Shell completion restricts candidates to the FlagOp Alias set
   actually reachable at a given grammar position.** `fsm.bareVariants`
   gained a `variant` parameter; when non-empty, it returns only variants
   for which `arg.aliases(variant, k)` holds, and `candidateWords`'s
   `Option`-kind case passes the matching transition's own
   `tr.matcher.variant` through. Without this, completion for
   `(--up | --down) (--left | --right)` offered all four variants at the
   very first position instead of just `--up`/`--down`, since it read
   every variant ever declared for the Arg rather than the one reachable
   at that specific transition. The `Options`-kind case (`[options]`
   catch-all) and `pendingOptionalArgs` stay unrestricted (`variant`
   blank), since both are genuinely alias-agnostic contexts.

New domain term for `CONTEXT.md`: **FlagOp Alias**.

## Considered options

- **Reject any second same-`Arg` Flag token outright, ignoring variant.**
  The simplest possible reading of "flags should be exclusive across
  alternation" -- but it's the wrong exclusivity boundary: it would make
  `-v --verbose` (declared as one Flag with two variants meaning the same
  thing) reject itself, which is never the intent. Rejected as soon as the
  `-v`/`--verbose` case was checked against it; FlagOp Alias exists
  precisely to draw this line correctly.

- **Block the scan on a mismatched variant instead of skipping past it**
  (decision 4's first draft). Simpler to implement -- no `RawToken.idx`
  machinery needed -- but it reintroduces order-dependence for a Flag's
  own variants, contradicting ADR 0019's already-established
  order-independent scanning for everything else. Rejected once the
  `-u -d` / `-d -u` asymmetry was caught by testing; replaced by
  skip-and-sort-by-true-index (decisions 4-5), which is order-independent
  and still composes correctly.

## Consequences

- `Match` is now a 4-tuple `(variant, value, spec, idx)`, not 3 -- any
  code constructing or destructuring a `Match` literal needs the `idx`
  field too. `push` (`fsm.nim`) gained an `idx` parameter, defaulting to
  `0` for matches where ordering doesn't matter (e.g. `Command`).
- `newOptMatcher`/`newOptsMatcher` (`fsmgraph.nim`) both take an optional
  variant (or `variants` seq, for the short-option-cluster case) alongside
  the Arg(s) they match.
- Every one of these mechanisms is keyed off `Arg.aliases`, which only
  `FlagArg[T]` overrides meaningfully -- so none of this changes matching,
  dedup, ordering, or completion behavior for Positional Arguments,
  Options, or Commands, only for Flags with more than one FlagOp Alias
  set.
