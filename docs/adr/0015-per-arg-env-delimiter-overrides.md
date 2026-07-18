# Per-Arg env delimiter overrides via `EnvSource`

`Spec.config.envDelim` (ADR 0014) is one setting shared across an entire
Spec tree. There was no way for a single Option/Flag whose env value has a
different natural delimiter than the rest of the spec (e.g. a token that
legitimately contains `:`, or a value that should never be split at all)
to opt out without changing the delimiter for every other env-configured
Arg too.

## Decision

Add `EnvSource* = object` (`backend.nim`, alongside `SpecConfig`):

```nim
EnvSource* = object
  name*: string          ## required -- no meaningless "override with no name" state
  delim*: Option[string] ## none = inherit Spec.config.envDelim
```

`name` is a plain, required `string`, not `Option[string]`: an `EnvSource`
with a delimiter override but no name is a meaningless state, so the
"is there an env source at all" question is pushed up a level instead,
onto the `env` param itself (see below) — `Option` only appears where a
real three-state question exists (`delim`: inherit, or override to a
specific value, or override to "never split").

Two public constructors (`argumint.nim`, alongside `newSpecConfig`):

```nim
converter toEnvSource*(name: string): Option[EnvSource] = some(EnvSource(name: name))
proc env*(name: string, delim: string): Option[EnvSource] = some(EnvSource(name: name, delim: some(delim)))
```

Both return `Option[EnvSource]`, not a bare `EnvSource` -- `opt*`/`opts*`/
`flag*`'s `env` param is typed `Option[EnvSource]` (see below), and Nim
doesn't chain an implicit `EnvSource -> Option[EnvSource]` conversion on
top of an already-implicit call, so `env(name, delim)` returning a bare
`EnvSource` would force every override call site to wrap it in `some(...)`
by hand.

`opt*`/`opts*`/`flag*`'s `env` param (and the internal `ValueArg`/
`FlagArg.env` field) changes type from `string = ""` to
`Option[EnvSource] = none(EnvSource)`. The converter keeps every existing
`env = "PORT"` call site compiling unchanged; the `env(name, delim)` proc
covers the new override case:

```nim
opt[int]("-p, --port", env = "PORT")             # unchanged
opt[string]("--token", env = env("TOKEN", ";"))  # per-arg delimiter override
opt[string]("--token", env = env("TOKEN", ""))   # never split this Arg's env value
```

### Delimiter tiering

`splitEnvValue` (`backend.nim`) now resolves in this order, most-specific
first:

1. the Arg's own `EnvSource.delim` is `some("")` — never split; the whole
   raw value is one element, unconditionally, even if it contains `\x1e`
2. `\x1e` (`EnvListSep`) is present in the raw value — split on it (how
   fish auto-joins a native list variable's elements for any variable
   name, not just ones fish special-cases like `PATH`)
3. the Arg's own `EnvSource.delim` is `some(d)`, `d != ""` — split on `d`
4. otherwise — split on `Spec.config.envDelim`

`\x1e` sits above a non-empty per-Arg override (tier 2 over tier 3)
because it's a factual signal that fish already exported real separate
elements, not a stylistic choice — no author-chosen delimiter, spec- or
Arg-level, should second-guess it. An explicit *empty* override (tier 1)
is different in kind: it's not "use a different delimiter," it's "there is
no delimiter, don't split this value at all," which is a stronger and more
specific instruction than even `\x1e`'s detection heuristic.

Tier 1 falls out of `strutils.split`'s existing behavior for free —
`"abc".split("")` already returns `@["abc"]`, a no-op — so no special-case
code is needed to make "never split" work; it only needs tier 1 to be
checked before tier 2 so `\x1e` can't preempt it.

## Considered options

- **Two overloads per proc** (`env: string` and `env: tuple[name, delim: string]`
  on each of `opt*`/`opts*`/`flag*`): rejected — triples the overload
  surface for every future env-related change, for no benefit over a
  single param with a converter.
- **`Option[string]` on both `EnvSource.name` and `.delim`**: rejected —
  admits a representable-but-meaningless state (`name: none(string),
  delim: some(x)`, a delimiter override with nothing to apply it to) with
  no obviously-right runtime behavior for it.
- **A separate `envDelim` param instead of bundling into `env`**: rejected
  in favor of bundling — an Arg-level delimiter override only ever makes
  sense paired with an Arg-level env var name, so splitting them into two
  independently-optional params would just re-open the same "override with
  no name" question `EnvSource.name` being required already closes.
- **`\x1e` always wins unconditionally, even over an empty override**:
  rejected — makes "never split" an unreliable promise (defeated by
  whatever bytes happen to be in the env var), for a scenario (a real
  `\x1e` byte colliding with an explicit no-split request) rare enough
  that reliability of the explicit instruction matters more.

## Consequences

None of this changes `Spec.config.envDelim` or `\x1e`'s existing behavior
for any Arg that doesn't use `env(name, delim)` — the fully-backward-compatible
`env = "NAME"` case still resolves exactly as before (tiers 2 and 4 only).
