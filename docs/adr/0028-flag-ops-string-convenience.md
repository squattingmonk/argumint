# `flag*` gets an `ops: string` convenience overload alongside `ops: varargs[FlagOpGroup[T]]`

`docs/adr/0027-flag-op-declarations.md` replaced `flag*`'s comma-string
`<flag>[<op><value>]` syntax with explicit `flagOp*(variants, op, value,
help = "")` calls passed to `ops`. This fixed the drift risk between
`variants`/`variantValues`/`variantHelp`, but made the common case more
verbose: what used to be one string,
`"-v, --verbose, --quiet=0, --boost+=5, --dampen-=2"`, now needs four
separate `flagOp(...)` calls even though none of them need a value with no
string spelling (the actual reason `flagOp*` exists).

## Decision

Add a second `flag*[T]` overload whose `ops` param is typed `string`
instead of `varargs[FlagOpGroup[T]]`: a comma-separated list of
`<flag><op><value>` entries, each becoming its own single-spelling
explicit FlagOp Alias group — parsed by `parseFlagOpsString[T]` (reusing
the same op-validation and string-to-`T` converter logic `flag*` used to
have inline before ADR 0027) and handed straight to the "normal"
array-taking overload. `flag*`'s own `variants` param is untouched by this
— it stays bare-spellings-only, still meaning implicit blank-op behavior.
A bare spelling given to the `ops: string` overload by mistake raises
`SpecDefect` pointing at `variants` instead, rather than being silently
misinterpreted.

This is a plain **overload** (`ops: string` vs. `ops: varargs[
FlagOpGroup[T]]`), not folded into `variants` itself: Nim disambiguates
the two cleanly by the `ops` argument's own type at the call site (a
string literal can never satisfy `varargs[FlagOpGroup[T]]`, and an array
literal can never satisfy `string`), so both forms coexist with zero
ambiguity — `flag[int]("-v, --verbose", ops = "--quiet=0, --boost+=5,
--dampen-=2", default = 0)` is exactly equivalent to writing out
`ops = [flagOp("--quiet", "=", 0), flagOp("--boost", "+=", 5),
flagOp("--dampen", "-=", 2)]` by hand. Folding this into `variants` instead
(auto-detecting bare vs. suffixed items in the same string) was considered
and rejected — see below.

The bare-bool convenience overload (`flag*(variants: string = "", ops:
varargs[FlagOpGroup[bool]] = @[], ...)`) gets a matching `ops: string`
sibling for the same reason.

## Considered options

- **Fold suffix-parsing back into `flag*`'s own `variants` string**,
  auto-detecting each comma item as bare or `<op><value>`-suffixed. This
  was the first approach tried and does work (a `parseFlagVariants[T]`
  proc doing exactly this dual-purpose parsing compiled and passed a
  scratch check). Rejected in favor of the separate-overload design once
  a cleaner alternative was pointed out: keeping `variants` single-purpose
  (bare spellings only, matching its post-ADR-0027 meaning) and adding a
  same-shape-but-differently-typed `ops` overload is less invasive — it
  doesn't change what `variants` itself means, and the two convenience
  forms (array vs. string) stay visibly parallel rather than one string
  param silently doing two different things depending on its content.

## Consequences

- Every Flag whose Variants only ever needed string-expressible ops
  (the common case — `=`/`+=`/`-=` against a builtin-convertible `T`) can
  go back to the pre-ADR-0027 one-string ergonomics via `ops: string`,
  without reintroducing `variantValues`/`variantHelp`'s side-table drift
  risk: a `help` override or a value with no string spelling still needs
  the array form, kept deliberately out of reach of the string overload.
- `flag*[T]` now has three overloads total (the original `ops: varargs[
  FlagOpGroup[T]]`, this `ops: string`, and the bracket-less bare-bool
  pair of the same two) — a caller not passing `ops` at all still resolves
  unambiguously to the `varargs` version, since only that one has a
  default value for `ops`; the `string` overload requires `ops` to be
  given explicitly.
