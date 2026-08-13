# `ConfigKey` becomes a `distinct seq[string]`

`ConfigKey` was a plain alias (`ConfigKey* = seq[string]`, ADR 0018), paired
with an implicit `converter toConfigKey*(segment: string): ConfigKey` giving
the one-segment convenience form `configKey = "port"`.

Because the alias is structural, that converter is really a global
`string` -> `seq[string]` conversion. `argumint.nim` re-exports
`configsource` wholesale (ADR 0017), so it landed in the scope of every
program that so much as imports argumint, and silently participated in
every overload resolution those programs performed:

```nim
import argumint

proc wantsSeq(xs: seq[string]): int = xs.len
echo wantsSeq("oops")        # compiled, printed 1

var v: seq[string]
v = "oops"                   # compiled
```

This is not a theoretical hazard. argumint's own test suite had already
absorbed a case of it: `tests/test_cli_syntax.nim` declared
`args("<file>", default = "", help = "")`, where `args`'s `default` is a
`seq[string]`. The bare `""` was silently converted to `@[""]` — a
one-element list holding the empty string, not the empty list the author
plainly meant. It went unnoticed because that test never reads the default.

## Decision

Make `ConfigKey` a `distinct seq[string]`, and keep the converter.

A converter *into* a distinct, argumint-owned type is safe in a way one
into a structural stdlib type is not: nothing outside argumint has a
`ConfigKey` parameter, so there is no foreign overload for it to hijack.
The convenience form survives unchanged — `configKey = "port"` and
`configKey = configKey("server", "port")` both still compile, and no
user-facing spelling of a Config Key changes.

Being distinct costs the operations a `seq[string]` came with for free, so
`configsource.nim` restores the ones the codebase and the `ConfigSource`
extension point actually use:

- `len`, `==`, `$` — `{.borrow.}`ed straight through.
- `[]` and `items` — written out; neither is borrowable (see
  `docs/gotchas.md`). `items` is what keeps `for segment in key` working in
  a `lookup` override.
- `join(sep = ".")` — for the `[configKey: server.port]` help annotation
  and `setFromConfig`'s error context, which previously rendered a raw
  `@["server", "port"]` via bare `$`. Display only, never parsed back.
- `segments` — the explicit unwrap to `seq[string]`, for a custom
  `ConfigSource` that needs to hand the path to something expecting an
  `openArray[string]`, which `ConfigKey` no longer implicitly satisfies.

Deliberately *not* borrowed: `hash`. Nothing in the library or either
built-in adapter keys a `Table` by `ConfigKey`, and adding it later is
non-breaking — so it stays out until something needs it.

`noConfigKey()` replaces the bare `@[]` default in `opt*`/`opts*`/`flag*`'s
eight signatures and `Arg.configKey`'s base case, matching the existing
`noValidator()`/`noClamp()` naming rather than spelling `ConfigKey(@[])`
inline nine times.

## Considered options

**Drop the converter, require `configKey("port")` even for one segment.**
Smallest diff and no distinct-type friction, but it loses a convenience
that reads well and is used throughout the tests, examples, and README —
and it would leave `configKey` as the only one of argumint's
`env`/`validator`/`clamp`/`configKey` parameters without a shorthand, for a
reason (the leak) that the distinct type removes entirely.

**Stop re-exporting `configsource` wholesale from `argumint.nim`.** Narrows
the blast radius without closing the hole: anyone doing `import
argumint/configsource` directly — which a custom `ConfigSource` author must
— still gets the global conversion. It also works against ADR 0017's
premise that `import argumint` alone should be enough.

## Consequences

- **Breaking for custom `ConfigSource` implementors only.** A `lookup`
  override that treated its `key` as a `seq[string]` beyond `len`/`[]`/
  iteration (slicing it, passing it to a `seq`-typed helper, comparing it
  to a `seq[string]` literal) now needs `key.segments`. Both built-in
  adapters (`ini`, `json`) needed no changes at all, which is some evidence
  the borrowed set covers the realistic cases.
- **Not breaking for ordinary spec authors.** No `opt`/`opts`/`flag` call
  site changes.
- The `toEnvSource` converter (`string` -> `Option[EnvSource]`) is left
  as-is. It has the same shape but not the same problem: `Option[EnvSource]`
  is already an argumint-owned type, so the converter has nothing outside
  argumint to interfere with. This ADR's reasoning is why it's safe, not an
  oversight.
- Anything that had been silently relying on the global conversion now
  fails to compile. That is the point, and the one instance in this repo
  was a latent bug.
