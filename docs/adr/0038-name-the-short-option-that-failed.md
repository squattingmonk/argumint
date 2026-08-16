# An unresolved cluster is named by the short option that failed, plus the token it came out of

Extends the "A cluster remainder is not a Non-Option Short" section of
[ADR 0034](0034-strict-option-checking.md), which settled that a remainder
errors but not how it is named. Applies to the *name* the reading that
[ADR 0035](0035-parse-failure-reporting.md) already applied to *suggestions*.

ADR 0034 made `-1.5` fail against a declared `-1` Flag, but the complaint
named the whole undigested remainder:

```console
$ app -1.5                  # -1 declared as a flag, usage "[options] [<rest>...]"
Parsing error:
  - unrecognized option: -.5
```

`-.5` is a token argumint synthesized; the user typed `-1.5`. Two further
symptoms make the case sharper than "the name is unfamiliar":

**The name's length depends on how far peeling happened to get.** With `-1`
and `-a` declared and `-b` not:

```console
$ app -1ab     ->  unrecognized option: -b     # -a peeled fine, so the name narrowed
$ app -1ba     ->  unrecognized option: -ba    # -b failed first, so -a is blamed with it
```

The reported name was "first failing letter plus whatever tail was never
tested". In `-1ba` that tail is `-a`, which is declared and blameless.

**The blamed tail can be entirely valid.** Declaring `-5` alongside `-1`
changes nothing — `app -1.5` still reported `-.5`, naming a declared,
recognized flag as part of the unrecognized thing. Peeling stops at `-.`;
`-5` is never reached, let alone rejected.

## Decision

**An unresolved option-shaped token is named by the single short option that
failed to resolve, with the token the user actually typed appended as
context when the two differ.**

```console
$ app -1.5     ->  unrecognized option: -. (in -1.5)
$ app -1ba     ->  unrecognized option: -b (in -1ba)
$ app -abc     ->  unrecognized option: -a (in -abc)
$ app --nope   ->  unrecognized option: --nope
```

Three rules:

1. **Naming.** A short-form token — exactly one leading dash — longer than
   two characters is named by its first two characters. Everything else is
   named as typed. The tail past the failing letter is never named: it was
   never tested, and may hold declared options.
2. **Origin.** ` (in <typed>)` is appended, where `<typed>` is what the user
   put on the command line. Omitted when it would only repeat the name,
   which is what keeps `--nope` and a two-character `-j` clean.
3. **Suggestions are untouched.** A short-form token still gets none; a long
   option still gets one. Only short names take an origin and only long names
   take a suggestion, so the two decorations never co-occur.

Rule 1 applies to a directly typed cluster as well as a peeled remainder. A
single leading dash *is* cluster syntax in this parser, so the failing unit
is a letter either way, and `-abc` naming itself invites a long-option
reading that isn't available. This is the same reasoning ADR 0035 gives for
refusing to suggest `--ab` for a typed `-ab`: "`--ab` is not what `-ab`
meant; at most `-a` is." That ADR applied it to the suggestion; this one
applies it to the name.

### Where the typed token comes from

Peeling destroys the original — `-1` is consumed and gone — and
`ParseContext` never retains argv, only the token list, which is what gets
consumed. So `RawToken` carries the typed string itself in an `origin`
field, propagated whenever a remainder is created and read through a
`userTyped` accessor that falls back to `raw`.

`origin` also subsumes the `fromCluster` flag ADR 0034 introduced, which was
set on exactly the peel that carries an `origin` and never elsewhere.
`fromCluster` survives as a name — `exemptFromStrict` reads better for it —
but as a derived predicate rather than stored state, so the two can no
longer disagree.

Two alternatives were rejected for carrying the origin. `RawToken.subIdx`
cannot: it equals "is a peel", the failing letter is already the remainder's
second character, and it holds no text at all — it is ranking-only
(ADR 0036). Recovering the origin from `RawToken.idx`
against argv also fails: one of the two complaint sites runs mid-walk where
argv is out of scope, and putting argv on `ParseContext` would copy a seq on
every branch attempt of the backtracking walk.

## Considered options

- **Pluralize instead — `unrecognized options: -.5` — signalling cluster-ness
  without changing the name.** Rejected: it asserts something false. With
  `-5` declared, `-.5`'s letters are `-.` (unrecognized) and `-5` (declared
  and valid), so the plural claims both failed when only the first was ever
  tested. It also leaves `-1abc` and `-abc` producing byte-identical
  messages from different inputs, which is the clearest symptom of the
  original defect.

- **Name the failing letter with no origin — just `-.`.** Correct as far as
  it goes, and the whole of what issue #37 originally specified. Rejected as
  incomplete: `-.` from a typed `-1.5` gives the user nothing to connect it
  to, and the origin is the actionable half. Adopted as rule 1, with rule 2
  added on top.

- **Render a caret under the failing column instead of naming an origin.**
  `subIdx` would support it (`subIdx + 1` is the offset). Rejected: a
  Complaint is a kind plus a subject that groups with `|` (ADR 0035), and a
  caret does not survive that grouping.

## Consequences

Two complaints can in principle both carry an origin and group as
`unrecognized option: (-. (in -1.5) | -b (in -2ab))`. Reach ranking (ADR
0036) names only the first offender in practice, so this is not reachable by
any case in the test suite, but it is accepted rather than designed around.

The origin is conditional, so the same complaint site renders two shapes.
This is deliberate: appending ` (in -j)` to `-j` is noise, and appending
anything to `--nope` implies a cluster reading that doesn't apply.

Before this change the wording was entirely unpinned — the cluster-remainder
tests asserted only that a `ParseError` was raised, never its message. The
full case table is now pinned, including the `-5`-declared case, which is
what rules out the plural.
