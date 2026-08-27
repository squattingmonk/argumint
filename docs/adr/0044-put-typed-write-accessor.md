# `put` is the typed write accessor; reads test the stored value, not `seen`

ADR 0041 made `parse` the whole write surface: an application can seed,
replace, or extend an Arg's value from code, and it arbitrates against the
Arg's incoming provenance the same way every Value Precedence tier does.
That closed most of issue #29. Two things it deliberately left out.

`parse` takes a `string` and converts it through the Arg's own `string ->
T` converter. A caller holding an already-computed `T` has to render it
back to a string that converter will accept — the inverse of a conversion
it may have hand-written, and argumint only ever requires the forward
direction. For a custom type with no meaningful `$`, this is not an
inconvenience but a runtime failure:

```nim
type Point = object
  x, y: int
converter toPoint(s: string): Point = ...   # forward only

arg.parse($point, seenBy = some(byCli))
# ParseError: expected Point for -p=<pt> but got "(x: 7, y: 9)"
```

`parse` also always runs the Arg's Validator, with no way for a caller that
has already computed and checked a value to say so.

Separately, every `ValueArg` read gates on `seen` (ADR 0040). That was
sound only because provenance and the stored value always agreed — every
write that stored a value also came with a tier attached to it, whether
from the command line, the env sweep, the Config Source sweep, or an
`arg.parse(v, seenBy = some(t))` call. A tier-less write breaks that
agreement on purpose: `arg.parse(v)` (or the new `put(v)` below) stores a
value while leaving `seenBy` exactly as it was, which is the "extend, don't
declare" case ADR 0041 built for pre-seeding. Under the old gate, that
value is unreadable through every accessor — not a bug in isolation, but a
sharp edge for anyone reaching for the same "compute now, supply as a seed"
idiom `put` exists for.

## Decision

### `put` is `parse` minus the conversion step

```nim
proc put*[T](arg: ValueArg[T, false], value: T,
             seenBy: Option[SeenBy] = none(SeenBy), validate = true)
proc put*[T](arg: ValueArg[T, true],  value: T,
             seenBy: Option[SeenBy] = none(SeenBy), validate = true)
proc put*[T](arg: FlagArg[T],         value: T,
             seenBy: Option[SeenBy] = none(SeenBy))
```

Neither overload takes a `variant`. `parse`'s `variant` names the specific
spelling a real token matched, which is worth citing in a
`ValidationError`'s message — but a programmatic write has no matched
token, so any `variant` a caller passed would be a spelling they picked,
not one the write went through. `putImpl` still takes `variant` internally
(`src/argumint/argtypes.nim`), since `parseImpl` needs to pass the real
one through; `put*` always calls it with `""`, which `subject` resolves to
`arg.variants[0]` — the one honest default. This mirrors `FlagArg.put`,
which already dropped `variant` for a related reason (nothing on its path
can raise at all).

Otherwise, `put` differs from `parse` in nothing else:

- **It arbitrates identically**, through the same `arbitrate` template
  every `parse` override routes through — omitting `seenBy` extends at
  whatever tier is current (appending, for a multi Arg), a stronger
  declared tier clears and applies, a weaker one is refused and the Arg is
  left exactly as it was. See `docs/adr/0041-parse-is-the-write-surface.md`
  for the tier rule itself; `put` doesn't restate it.
- **It records provenance the same way** — by declaring a tier, or by
  leaving it alone.
- **Scalar replaces the one slot; multi appends.** A typed one-call replace
  for a multi Arg is `clear()` then one `put` per value, the same idiom
  `parse` uses — a single-call typed replace is #56, out of scope here.

`putImpl` in `src/argumint/argtypes.nim` is the extracted core of what was
`parseImpl`: the `arbitrate` call, the two Validator branches, the
arity-dependent store, and the `ValidationError` re-raise. `parseImpl` now
does only the string conversion and delegates. The conversion has to
happen *inside* the `try` — binding it at a `let` ahead of the `try`
infers the whole expression's type from the pre-conversion `string`, so
the converter's own `ValueError` escapes uncaught instead of becoming a
`ParseError`. See `docs/gotchas.md`.

### Validation defaults on, with an opt-out at every arity

`put` validates by default at both `ValueArg` arities, with `validate =
false` available at both. This reverses ADR 0041's own "appending writes
never opt out" reasoning: there, the concern was a multi Arg's seq ending
up a mixture of checked and unchecked elements with no way to tell them
apart. `put` accepts that mixture as the deliberate cost of the opt-out —
a caller who passes `validate = false` on a multi Arg is choosing it, and
it is the only cost. It is not a new hazard for a history-aware Validator
(`unique`, `checkSeenIt`): an unvalidated write still becomes a prior Seen
Value for every later candidate, exactly as a validated one does — Seen
Values are populated by the write, not by the Validator passing.

`FlagArg.put` takes **no `validate` parameter at all** — a Flag has no
Validator, so a parameter that silently did nothing would lie in the
signature, and this is a compile-time rejection rather than a runtime
no-op. (It takes no `variant` either, for the reason given above — doubly
so here, since nothing on this path can raise at all.) It always clamps,
exactly like every other write to a Flag's value — the constructor rejects
an out-of-clamp default, Flag Operations clamp, `clear` restores a value
that already satisfied its own clamp, and now `put` clamps too, with no
opt-out. The Clamp invariant (`docs/adr/0016-flag-clamp.md`) is total.

### Every accessor tests the stored value where it can, not just `seen`

For a **scalar** `ValueArg`, `get`/`get(otherwise)` branch on whether
`rawValue` holds anything (`a.rawValue.len > 0`) rather than on `a.seen`.
This is required, not cosmetic: it is what makes a tier-less `put` (or
`parse`) readable at all, and it closes the `value[0]`-depends-on-agreement
note ADR 0040 flagged, including the Config Source `some(@[])` case that
note's own Consequences described — a tier that resolves nothing must not
leave the Arg reading as Seen over an empty seq, which `arbitrate` already
guarantees on the write side; this is the read side of the same invariant.
A scalar Arg has no renderable "Seen but empty" state — its whole point is
to hold exactly one `T` — so an empty `rawValue` falls back to `otherwise`
regardless of `seenBy`, the same as before this ADR.

For a **multi** `ValueArg`, the test is `a.seen or a.rawValue.len > 0`. An
empty seq *is* a renderable value for a multi Arg, so once a caller has
claimed a tier — `arg.seenBy = t` directly, or (in the future) a resolved
tier supplying genuinely zero values — `get`/`get(otherwise)` return that
empty seq instead of substituting `otherwise`. This distinguishes "never
supplied, so the coded default or `otherwise` applies" from "explicitly
supplied as empty, so `@[]` applies" — a distinction a scalar Arg has no
way to make (there's no `T` for "explicitly nothing") but a multi Arg's
seq already has for free. No built-in write path produces this today
(`put`/`parse` always append at least one element once they store
anything) — it's reached only by writing the public `seenBy` field
directly — but the accessor supports it now that the underlying `arbitrate`
invariant ("provenance never outruns the value it describes",
`docs/adr/0041-parse-is-the-write-surface.md`) makes it safe to trust.

`FlagArg`'s accessors gain the analogous case. `get(otherwise)` now
returns `rawValue` when `a.seen`, **or** when `rawValue != rawDefault` —
the new `rawDefault*[T](arg: FlagArg[T])` template in
`src/argumint/argtypes.nim` mirrors `ValueArg`'s existing one. A tier-less
`put`/`parse` that moves a Flag's value away from its coded default is now
visible to `get(otherwise)`, not just to the no-arg `get`.

`seen`/`seenBy` are themselves **unchanged** on every path above. A
tier-less write still leaves `seenBy == byNone`; only what the *readers*
do with the stored value changes.

**Residue, narrowed but not eliminated, and left unaddressed:** a Flag has
no representable "nothing here" state the way an empty seq serves a
`ValueArg` — its `value` is a plain `T` that always holds something. So a
tier-less write whose value happens to **equal** the coded default is
still indistinguishable from an untouched Flag, and `get(otherwise)`
still falls back to `otherwise` for it. This is real but obscure enough
not to warrant a line in `README.md`: it only bites a caller who writes a
tier-less seed equal to the Flag's own default and specifically needs
`get(otherwise)` (not the no-arg `get`, which already sees it) to report
that as supplied. Nothing in this ADR proposes fixing it — there's no
signal left to fix it with short of comparing against the default, which
is exactly the source of the ambiguity.

**New constraint on custom Flag types:** `get(otherwise)`'s `rawValue !=
rawDefault` comparison requires `T` to support `!=`. This was already true
of any `FlagArg[T]` constructed with a non-nil clamp (the constructor's
own default-satisfies-clamp check uses `!=`), so every built-in Flag type
and the common custom case are unaffected — but a custom Flag type with no
`==`/`!=` that previously compiled fine now fails to compile at its first
`get(otherwise)` call site (not at `defineArg`/`defineFlag` registration,
since `get(otherwise)` is a template, instantiated only where called).

## Consequences

- **ADR 0040 is amended.** Its "`seen` is the supplied-or-not predicate,
  for every type" section and the paragraph noting the scalar accessor's
  `value[0]` index depends on that agreement both go stale for every Arg
  kind: `seen` is no longer the sole predicate anywhere except the scalar
  `ValueArg` case, which alone still gates purely on the stored value (with
  no `seen` fallback, since it has no renderable empty-but-Seen state).
- **ADR 0041 is amended.** Its write-surface table gains `put` alongside
  `parse`, and its "ADR 0040's promise is closable but not closed"
  Consequence is now closed for every reader: a `ValueArg`'s tier-less
  write is always readable, and a `FlagArg`'s is readable whenever it
  changes the value — narrowed rather than left fully open, per the
  residue above.
- **`CONTEXT.md`'s Validator entry** stops implying every stored value
  satisfied the Validator: `put(v, validate = false)` is now the one
  exception, on both arities.
- **`CONTEXT.md`'s Seen Arg entry** notes that `seen` is no longer the
  sole gate on any Arg kind's value reads except the scalar `ValueArg`
  case — a tier-less write leaves the Arg unseen but its value readable
  (unconditionally for a `ValueArg`, and for a `FlagArg` whenever the
  write actually changes the value), which is new since that entry was
  written against ADR 0041 alone.
- **`README.md`'s write-surface section** gains a *Writing an
  Already-Typed Value* subsection alongside `parse`'s, covering `put`, the
  `validate` opt-out, and the `FlagArg` overload's narrower signature.
- **`put` is a plain generic proc, not a method.** It adds nothing to the
  custom-`Arg` contract ADR 0030 freezes, and — like `get` — it statically
  bypasses a custom subtype's `parse` override, since it never calls
  `parse` at all. `docs/architecture.md`'s custom-`Arg` section says so.
- **The facade/machinery seam**
  (`docs/adr/0043-facade-machinery-seam.md`) gains a row: `put` (facade,
  `src/argumint.nim`) is backed by `putImpl` (machinery,
  `src/argumint/argtypes.nim`), the same shape as `get`/`rawValue`.
- **`docs/gotchas.md`** gains an entry for the try-expression trap
  `putImpl`/`parseImpl`'s extraction ran into: binding the string -> `T`
  conversion at a `let` ahead of the `try` infers the whole expression's
  type from the pre-conversion `string`, so the converter's own
  `ValueError` escapes uncaught instead of becoming a `ParseError`.
- Issue #29 is narrowed to what remains after this: a typed one-call
  replace for a multi-valued Arg, filed as #56.

## Considered options

**A `validate = false` opt-out on `parse` itself.** Rejected: `parse` is a
`{.base.}` method, so adding a parameter changes every existing override's
signature for no demonstrated need. `put` is a plain proc and pays no such
cost.

**Giving `FlagArg.put` a `validate` parameter that is always ignored, for
symmetry with the `ValueArg` overloads.** Rejected as a parameter that
lies about what it does; a compile-time absence is honest where a
runtime no-op would not be.

**Keeping `variant` on the `ValueArg` overloads, for symmetry with
`parse`.** The original draft did. Dropped once the question was asked
directly: what would a caller's `variant` argument actually mean, given
`put` has no matched token to report? Nothing — it would be a spelling
the caller picked, indistinguishable in the error message from the real
thing `parse`'s `variant` provides. Keeping a parameter whose only use is
picking cosmetics for an exception message isn't worth carrying; `""`
(→ `arg.variants[0]`) is the one answer that isn't invented.

**Leaving `FlagArg`'s `get(otherwise)` gated purely on `seen`, with the
value-differs-from-default case as permanent, undocumented residue.**
Rejected in favor of closing the common case: a Flag's value has no
representable "nothing here" state to test the way an empty seq serves a
`ValueArg`, but "differs from the coded default" is a good enough proxy
for it that leaving the gap open for every tier-less write — rather than
only the one where the write coincidentally reproduces the default —
would have been a worse default for the common case, at the cost of one
narrow, documented misclassification instead of a blanket one.

**Keeping `seen` as the single predicate and adding a second one for
"holds a stored value".** Two names for what a caller usually wants
answered together — "will `get` return the thing I wrote" — would just
move the question of which one to call at every read site. One accessor,
one test, matching what it actually reads.
