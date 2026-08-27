# Public names stay in `argumint.nim`; private-field machinery lives in a withheld submodule

Splitting `argumint.nim` divides each public feature in two. The rule for
where the halves go:

> `argumint.nim` holds every public name and its documentation. The
> submodule holds everything that touches a private field -- exported so
> the facade can reach it, and withheld from the facade's re-export list so
> users cannot.

In `argumint/argtypes` it applies five times:

| Public name (facade) | Machinery (submodule, withheld) |
| --- | --- |
| `arg`/`args`/`opt`/`opts` | `initValueArg` |
| `flag`/`flagOp` | `initFlagArg`, `splitFlagSpellings`, `parseFlagOpsString`, `checkFlagOp` |
| `get` (all six overloads), `toT`/`toSeqT` | `rawValue` / `rawDefault` |
| `defineArg` (both overloads), `defineFlag`, `defineSetFlag` | `defineValueArg` / `defineFlagArg` / `defineSetFlagArg` |
| `put` (all three overloads) | `putImpl` -- see `docs/adr/0044-put-typed-write-accessor.md` |

A maintainer never has to ask which module a public name lives in. The
answer is always `argumint.nim`.

The split is forced, not stylistic. `ValueArg`/`FlagArg` have private
fields (`docs/adr/0033-value-arg-flag-arg-exported.md`), and
`std/importutils.privateAccess` does not survive instantiation in another
module: a generic proc declared where `privateAccess` is in effect but
instantiated elsewhere fails with `undeclared field`, and the declaring
module still compiles clean on its own -- the error surfaces only in the
*user's* file, pointing at library code they never wrote. A template or
generic declared beside the type has no such problem. So code touching
private fields must live with the type, and everything else is free to stay
where users look for it.

The alternative -- moving the public names out and re-exporting them -- was
rejected. It puts the things users reach for first in a module they never
name, and it splits each name from the documentation explaining it. The doc
comments carry real weight here:
`docs/adr/0040-explicit-value-accessor.md`'s rationale for `get` being a
template, `docs/adr/0027-flag-op-declarations.md`'s rules for FlagOp Alias
groups, `docs/adr/0017-argumint-reexports-for-custom-arg-types.md`'s
registration mechanism. Those belong beside the API they explain.

**Reads get accessors; writes go through `init*`.** The submodule exports
read accessors (`rawValue`/`rawDefault`, templates rather than procs so
reading a multi-value `ValueArg` doesn't copy the seq) but no mutators.
Exported `addOp`/`setAliases` were considered and rejected: a reader cannot
corrupt an invariant, whereas a mutator would let a caller build a
`FlagArg` whose `ops` and `aliases` tables disagree. Construction therefore
goes through a *fat* `initFlagArg` that performs the whole build -- ops
table, alias groups, duplicate detection, clamp-versus-default check --
rather than a thin constructor plus exposed mutation. The asymmetry is
deliberate; it is not an oversight to be tidied up later.

**"Withheld" means exported from its own module, absent from the facade.**
This is an established shape here, not a new category: the variant-format
PEGs are exported from `backend` and deliberately unreachable from a bare
`import argumint`, and `tests/test_public_api.nim` polices exactly that.
Every withheld name gets a `not compiles` assertion there, mirrored by a
positive in the suite that imports internals -- neither half means much
alone.

**The submodule is an implementation detail, not a promised import path.**
It is not the `argumint/help` shape
(`docs/adr/0042-genhelp-opt-in-via-submodule.md`) or the `configsource`
adapters (`docs/adr/0018-config-source.md`), both of which users are meant
to type. Nothing about a machinery submodule should be documented as
importable; its name is a maintainer-facing label, and it stays free to be
renamed or resplit.

Withheld is the widest a name should be, not the default. Anything the
facade never names stays fully private to the submodule: `FlagOp`, the four
string-to-scalar converters, the `flagOps` registry, and `getFlagOps`, whose
only reader (`checkFlagOp`) lives beside it. Sharing one `checkFlagOp`
between `flagOp*` and `parseFlagOpsString` is what let the last two of those
lose their `*` -- worth noticing, because the pressure runs the other way by
default: every call across the seam is an argument for one more export.
Names in this category are unreachable to *any* importer, so their mirror
belongs in the submodule's own embedded suite rather than in
`tests/test_argumint.nim`.

One name lands below both halves rather than in either: `Comma`, the PEG
every `variants`/`ops` string is split on, has consumers in the facade's
Arg constructors *and* in `argtypes`'s `initValueArg`/`splitFlagSpellings`,
so it moved to `backend` beside the variant-format PEGs.
`FlagOpVariantFormat` followed it rather than being stranded alone.

## Considered options

- **Move the public names out and re-export them from the facade.**
  Rejected as above: it hides the primary interface in an unnamed module
  and separates each name from its docs.
- **Split the machinery further, into types and the `define*` family.** Not
  available. The `define*` templates generate roughly twenty private-field
  accesses at the *user's* expansion site, so they must sit beside the
  type; and the bookend rescue does not apply, because the failing code is
  per-type generated methods rather than one generic proc to delegate from.
- **Keep the public names in the facade and reach the fields with
  `privateAccess`.** Verified impossible for the generic procs and
  templates involved, with the failure landing in the user's file rather
  than the library's.
- **Export mutators instead of a fat `init*`.** Rejected: it reopens the
  private fields under different names and lets a caller construct an
  inconsistent `FlagArg`.
