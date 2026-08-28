# `replace` is a typed, atomic, non-arbitrating write for a multi Arg

ADR 0041 made `parse` the write surface and documented `arg.clear()`
followed by one `parse` per value as how a caller replaces a multi-valued
`ValueArg`'s whole set. That idiom has no failure atomicity: `clear` runs
before any conversion or validation, so a bad value at any position —
including the first — leaves the Arg holding a prefix of the new values
with the old ones already gone, stamped with whatever tier the caller
declared. Issue #56 filed this as a bug: single-value `parse` is atomic by
construction (ADR 0041 runs its replacing body before the `clear`
precisely so a raise leaves the Arg untouched), and multi-value
replacement was the one documented write path without that guarantee.

As filed, #56 proposed closing the gap with a string-taking call —
`replace*[T](arg, values: openArray[string], seenBy: SeenBy, variant =
"")` — going through the same string → `T` conversion `parse` uses, with
`seenBy` **required** because the idiom it replaces drops provenance to
`byNone` before any value lands, which no tier-less call could recover
from.

ADR 0044 shipped in between and changed the premise. `put` established
that a caller who already holds a `T` gets a typed sibling of `parse`
rather than being routed back through string conversion, and ADR 0044's
own Consequences named what was left as "a typed one-call replace for a
multi-valued Arg... filed as #56" — recharacterizing the issue before this
ADR was written. Once a typed write path exists at all, a typed `replace`
sits beside it the same way `put` sits beside `parse`, rather than
`replace` being the odd one out still going through strings.

## Decision

### `replace` takes a `seq[T]`, mirroring `put`, not `parse`

```nim
proc replace*[T](arg: ValueArg[T, true], values: seq[T],
                  seenBy: Option[SeenBy] = none(SeenBy), validate = true)
```

A caller holding raw strings still has the non-atomic `clear`-then-loop
option, or converts them to `T` first (trivial for every built-in type)
and calls `replace`. That residue is accepted rather than closed here: the
alternative was re-implementing string conversion beside `parse` a second
time, which is exactly the duplication ADR 0044 avoided for `put`, and
`replace` is under the same pressure not to reintroduce it. No `variant`
parameter either, for the reason ADR 0044 gives for dropping it from
`put`: nothing on this path has a matched token to report, so any
`variant` a caller passed would be a spelling they invented, not one the
write went through. Unlike `putImpl`, `replaceImpl` doesn't even carry
`variant` internally — `putImpl` keeps it because `parseImpl` calls in
with the real matched token, but nothing calls into `replaceImpl` that
way, so it names `self` with the bare `self.name()` instead of
`self.subject(variant, seenBy)`.

### `replace` never arbitrates, and needs no `clear`

Every other write — `parse`, `put` — routes through `arbitrate`, which
decides whether a contribution applies by comparing its declared tier
against the Arg's current one, and clears before applying only on the
strictly-stronger branch. `replace` skips that comparison entirely:

```nim
proc replaceImpl*[T](self: ValueArg[T, true], values: seq[T], ...) =
  try:
    if validate and not self.validator.isNil:
      for idx, value in values:
        self.validator.validate(value, values[0..<idx])
  except ValidationError as e:
    raise newException(ValidationError, ...)
  self.value = values
  self.seenBy = seenBy.get(otherwise = self.seenBy)
```

It validates the whole incoming batch first, and only if every value
passes does it overwrite `self.value` and `self.seenBy` together, in the
same two lines. There is no `clear()` call anywhere in this path — value
and provenance are replaced atomically as one unit, so there is nothing
for a `clear` to do first and nothing left over for it to undo. This is
what makes `replace` able to demote unconditionally: it doesn't ask
whether the declared tier outranks the current one, so a weaker tier
always lands, exactly as `clear()` then a declaring `parse` already
permits — in one call instead of two, with atomicity `clear`-then-loop
never had.

### `seenBy` stays optional, against the original proposal

The issue's requirement that `seenBy` be a bare, required `SeenBy` existed
for one reason: the `clear`-then-loop idiom it was replacing drops
provenance to `byNone` before any value is written, so a tier-less call
through that idiom always produces an Arg no accessor can read. `replace`
doesn't share that mechanism — it never separates "forget who supplied
this" from "store the new values" into two steps, so the hazard the
required parameter existed to prevent cannot occur here. Making it
optional (`Option[SeenBy] = none(SeenBy)`, defaulting to "keep whatever
provenance the Arg already has") matches `put`'s shape and gives a real,
non-hazardous use: replacing an Arg's values — deduping, normalizing, or
correcting them — without changing who is on record as having supplied
them.

### Validation checks the new batch's own history, never the old values

Each candidate is validated against the prefix of `values` already
accepted in the same call (`values[0..<idx]`, not including the candidate
itself, matching `Validator.validate`'s documented contract and
`putImpl`'s existing usage) — never against `self`'s prior values, which
are about to be discarded. This is the same rule ADR 0041's `arbitrate`
applies on its replacing branch, for the same reason: a history-aware
Validator (`unique`, `checkSeenIt`) checking a promoted value's history
must not include values a stronger tier is about to clear out from under
it. A `unique` batch may therefore repeat a value the Arg held before the
call, but not repeat one of its own new elements.

### Atomicity comes from validate-then-write, not snapshot-and-restore

The issue's brief considered snapshotting the Arg's value and provenance
and restoring them on failure. `replaceImpl` doesn't need to: because
`replace` takes an already-typed `seq[T]`, there is no per-element
conversion step that can fail partway through a mutation the way a
string-driven loop's `parse` calls could. Validating the whole batch
inside one `try`, ahead of any write, is sufficient by itself — a raised
`ValidationError` happens before `self.value`/`self.seenBy` are touched at
all, so the Arg is left exactly as it was without any explicit
snapshot/restore bookkeeping.

## Consequences

- **ADR 0041's write-surface table** gains a row: replacing a multi Arg's
  values is `arg.replace(values, seenBy = ...)`, not `clear()` then one
  `parse` per value — that idiom remains valid (and is still how a caller
  starting from raw strings replaces a batch, non-atomically), but is no
  longer the only or the recommended spelling.
- **ADR 0041 and ADR 0044 both gain a forward-amendment note** pointing
  here, matching how ADR 0041 already notes ADR 0044.
- **Issue #56's acceptance criteria around string input, a required
  `SeenBy`, and a `ParseError` on unconvertible input no longer apply.**
  They described the string-taking design that predated `put`; the
  Validator-history, atomicity, and demotion criteria all still hold and
  are covered by `tests/test_replace.nim`.
- **Scalar `ValueArg` and `FlagArg` remain excluded**, for the reasons #56
  already gave: a scalar's single `parse`/`put` already replaces its one
  slot atomically, so there is no *n+1* problem to solve, and a `FlagArg`
  is scalar with Flag-Operation writes rather than value writes.
- **`CONTEXT.md`'s Seen Arg entry** now notes `replace` as the one write
  that does not arbitrate, alongside `parse`/`put`, which do.
- **`README.md`'s write-surface section** gains a *Replacing a Multi Arg's
  Values in One Call* subsection.
- **A real bug surfaced and was fixed while landing this**:
  `replaceImpl`'s first draft validated each candidate against
  `values[0..idx]`, which includes the candidate itself. Under a `unique`
  Validator this rejects every value in every batch, since each value is
  trivially "already" in a slice that contains it. Fixed to
  `values[0..<idx]`, matching `putImpl`'s `self.value` (which likewise
  never includes the value being checked) and `Validator.validate`'s own
  doc comment.

## Considered options

**The string-taking signature as originally filed
(`openArray[string]`).** Rejected once `put` established the typed-write
precedent: requiring every caller to hand strings duplicates `parse`'s
conversion path a second time (the exact duplication ADR 0044 avoided for
`put`), for a benefit — not needing to convert first — that every built-in
type's caller can trivially do themselves, and a custom type's caller
already has their own converter in hand since they wrote it.

**Requiring `seenBy` as a bare `SeenBy`.** Rejected because the hazard it
existed to prevent — a tier-less write through a `clear`-based idiom
producing an unreadable Arg — cannot occur in a design that overwrites
value and provenance together and never calls `clear` at all. Requiring it
anyway would forbid a legitimate use (replacing values while keeping the
current owner) to guard against a failure mode this design doesn't have.

**Arbitrating like `put`, refusing a weaker declared tier.** Rejected
because #56's whole point is a call that *can* demote — arbitration would
block exactly the case `replace` exists to make atomic. `clear()` then a
declaring `parse` already demotes today; the choice was between leaving
that two-step, non-atomic path as the only way to demote, or giving
`replace` the same unconditional-apply behavior in one atomic call. The
latter is a straightforward "no arbitration at all" rather than a new
three-way rule to state and test.

**Snapshot the Arg's value and provenance, run the existing per-value
sequence, and restore on failure.** Not needed given `replace` starts from
a typed `seq[T]`: with no conversion step in the loop, validating the
whole batch before any write is enough to get atomicity, with no
snapshot/restore machinery to maintain.
