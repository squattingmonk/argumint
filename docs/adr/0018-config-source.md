# Config Source: a third Value Precedence tier

> **Amended by [ADR 0041](0041-parse-is-the-write-surface.md)**: the
> `setFromConfig*` base method described below no longer exists. A Config
> Source's resolved values now go straight to `Arg.parse`, with the Config
> Key as the error context, so a custom `Arg` implements one `parse`
> override instead of one method per tier. `configKey*` is unchanged, and
> remains how an Arg declares what to look up. Everything else here — the
> tier's position, the layering rule, the walk-driven consumption and
> oversupply semantics, and `ConfigSource` as the extension point for a new
> format — stands as written.

> **Amended by
> [ADR 0029](0029-config-key-distinct.md)**: `ConfigKey` is now a
> `distinct seq[string]`, not the plain alias described in point 3 below.
> The bare-string `converter` and everything else here stand; only the
> type's representation changed.

Value Precedence had two tiers above the coded default: an explicit CLI
value, then an environment variable (`Env Source`). That wasn't enough for
an app wanting a config-file-driven layer ahead of its own coded defaults —
the motivating case is replacing `nasher`'s own hand-rolled CLI+config
handling (https://github.com/squattingmonk/nasher/blob/master/src/nasher/
utils/options.nim), which layers a global `user.cfg`, then a package-local
`user.cfg`, then CLI, with later layers overriding earlier ones.

This adds a third tier, **Config Source**, between env and the coded
default: **CLI > env > Config Source(s) > coded default**, for Option/Flag
only (never positional args, matching env's existing scope). Reached
through a structured design interview; see `CONTEXT.md`'s **Config
Source**/**Config Key** entries for the user-facing shape and updated
**Value Precedence** entry for the full ordering.

This work was split into two commits: `SpecConfig` was first renamed to
`SpecSettings` (pure rename, no behavior change), specifically so
`configSources` wouldn't collide with the type's own name
(`spec.config.configSources` would have read as two different senses of
"config" nested inside each other).

## Decision

1. **Value shape**: every value surfaced by a Config Source is a `string`,
   funneled through the exact same `parseImpl`/converter path as CLI/env —
   no typed (`T`-native) passthrough. Keeps one conversion/validation path
   for every tier, matching the existing CLI/env precedent.
2. **No central delimiter-splitting**: unlike env (one raw string, always
   centrally split via `splitEnvValue`), a `ConfigSource.lookup` returns
   `seq[string]` **directly** — already one element per logical value. A
   JSON array's elements become the seq natively (`argumint/configsource/
   json.nim`); the INI adapter (`argumint/configsource/ini.nim`) uses
   `std/parsecfg`'s low-level streaming `CfgParser`/`CfgEvent` API rather
   than `loadConfig` specifically so a key repeated more than once in the
   file accumulates into a real `seq[string]` (`loadConfig`'s `Config` only
   holds one string per key, last write wins).
3. **Per-Arg key**: a structured path, `ConfigKey = seq[string]`
   (`argumint/configsource.nim`), not a flat delimited string. Each adapter
   interprets segments its own way — the INI adapter treats a 1-segment
   path as the global scope (before any `[section]` header) and a
   2-segment path as `[section, key]`; the JSON adapter walks one nested
   object level per segment. A 1-segment path has a `converter` from a
   bare string for ergonomics (`configKey = "port"`).
4. **Multiple, ordered, layered Config Sources**: `SpecSettings.
   configSources: seq[ConfigSource]`, consulted in order via
   `lookupConfigSources`; the last source with a hit for a given key **fully
   replaces** an earlier hit — never merged, including for a multi-value
   Arg. Keeps one uniform "most-specific-present-tier-wins" rule across the
   *entire* Value Precedence chain, with no special case just for
   multi-source layering.
5. **I/O ownership**: `iniConfigSource(path)`/`jsonConfigSource(path)` own
   their file I/O and parsing, eagerly, at the caller's construction call —
   before `parse*`/`parseOrQuit*` ever runs. A missing file or malformed
   syntax raises an ordinary `IOError`/`ValueError`/`JsonParsingError`
   right there, in the caller's own code — deliberately outside argumint's
   `SpecDefect`/`ParseError`/`ValidationError`/`MessageError` taxonomy,
   since it happens before any Spec construction or parsing begins.
6. **Extension point**: `ConfigSource* = ref object of RootObj` with an
   open `method lookup*` (`{.base.}`) — the same open, method-dispatch
   extensibility pattern the `Arg` hierarchy itself uses, not a closed
   case-object like `Validator`/`FlagClamp`. A closed variant set can't
   support "an arbitrary user-supplied format," which is a hard
   requirement here.
7. **`configSources` lives directly on `SpecSettings`**, not a separate
   wrapper type/field. It inherits `SpecSettings`' existing shared-`ref`
   cascade (`cascadeSpecSettings`) for free: every `Spec` in the tree reads
   the same `seq`, and a caller holding the `SpecSettings` they passed to
   `parse*` can mutate `configSources` and have a *later, separate*
   `parse()` call see the change. See "Corrected claim" below for a
   justification that was tested and found false.
8. **Required-option interaction**: mirrors env/ADR 0004 exactly — a Config
   Source value satisfies a required Option/Flag unconditionally.
9. **Walk mechanics**: `fsm.nim`'s `EnvCursor` was generalized into
   `ValueCursor`, reused for both the env and Config Source tiers — same
   per-Arg walk-time consumption tracking (`probe`, now parameterized by a
   `resolve` closure instead of hardcoding env lookup), same "unexpected
   option"/"unexpected flag" oversupply error, same
   unwalked-Arg-gets-everything rule (`applyTier`/`applyFallbacks`,
   replacing the old single-tier `apply`). `ValueCursor` gained a `tried:
   HashSet[Arg]` field so `resolve` runs at most once per Arg per walk,
   caching a miss too — safe for env (`existsEnv` is cheap and idempotent)
   and necessary for Config Source (`ConfigSource.lookup` is
   user-supplied and may be arbitrarily expensive).

## Corrected claim: `before`-hook mutation does *not* reach a same-parse descendant

An earlier draft of this design argued that folding `configSources` into
`SpecSettings` (rather than a separate structure) was needed so a `before`
hook could detect something at runtime (e.g. a project root) and
`configSources.add(...)` a local source, with the change visible to a
not-yet-dispatched nested Spec in the *same* parse call — directly modeled
on the nasher global-then-local-config case.

Built and tested against the real implementation, this turned out to be
false: `applyFallbacks` (where Config Source values are actually applied)
runs to completion, for every level in the tree, entirely *before*
`dispatch` — and therefore before any `before`/`action`/`after` hook —
ever fires. This is exactly the same carve-out `Spec.settings.envDelim`
already has, and for the same reason (shared `ValueCursor` mechanics): "the
env-var fallback sweep runs to completion across the whole tree before
dispatch/any hook is ever called, so a hook-time mutation ... has no effect
on that parse's env-var handling" (architecture.md). A `before` hook
mutating `configSources` is therefore always too late for the parse
already in progress. `tests/test_argumint.nim`'s `"a before hook mutating
configSources has no effect on the current parse, same carve-out as
envDelim"` test demonstrates and locks in the actual behavior: the
mutation has no effect on the in-progress parse, but is visible to a
*later, separate* `parse()` call reusing the same held `SpecSettings`.

This doesn't change the decision to fold `configSources` into
`SpecSettings` — see "Rejected alternatives" below for why that's still
right — it just means the justification changed. The nasher case is still
fully supported; it just requires building the local `ConfigSource` (e.g.
after detecting the project root) *before* the `parse()` call that should
see it, not from inside that same call's `before` hook.

## Rejected alternatives

- **A single, non-layered `ConfigSource`** (not a `seq`): doesn't cover the
  nasher motivating case (global-then-local layering) at all.
- **Central, env-style delimiter splitting for Config Source values**: a
  JSON array or a repeated INI key already knows its own element
  boundaries; forcing a `ConfigSource.lookup` to return one joined string
  that then gets centrally re-split would be a lossy, pointless round-trip
  for formats that don't need it.
- **Typed (`T`-native) value passthrough**, bypassing `parseImpl`: would
  need a parallel conversion/validation path per format, and doesn't fit
  an INI adapter at all (`parsecfg` only ever hands back strings) — the two
  built-in adapters would behave asymmetrically.
- **A closed case-object design**, like `Validator`/`FlagClamp`: rejected
  specifically because "an arbitrary user-supplied format" requires real
  third-party subclassability, which a fixed-kind case object can't offer.
- **A separate `ConfigSourceChain` wrapper type/field**, sibling to
  `SpecSettings` rather than folded into it: rejected as unnecessary
  complexity once the (now-corrected) live-mutation-during-dispatch
  justification was removed — `SpecSettings` already provides the cascade
  and cross-call sharing that's actually needed, with no new type, no
  parallel cascade proc, and no extra top-level param on `newSpec*`/
  `parse*`/`parseOrQuit*` (Config Sources ride along on the existing
  `settings: SpecSettings` param, exactly like `width`/`envDelim`
  already do).

## Consequences

- Two new template-generated base-method pairs, `configKey*`/
  `setFromConfig*`, generated by `defineArg`/`defineFlagArg` per `T` and
  arity, mirroring `envName*`/`setFromEnv*`. No new
  `docs/adr/0017-argumint-reexports-for-custom-arg-types.md`-style openSym
  re-export was needed: the generated bodies use `$self.cfgKey` (bare `$`,
  always in scope) rather than `strutils.join`, specifically to avoid
  introducing a new unqualified-symbol dependency.
- `backend.nim` gained its first-ever dependency on another `argumint/*`
  module (`import ./configsource` + `export configsource`) — previously
  zero internal imports. Justified since the cascade and the `Arg` base
  methods (`configKey`/`setFromConfig`) both need `ConfigKey`/
  `ConfigSource` at the `Spec`/`Arg` type-definition level.
- The `configsource/` subdirectory (`configsource/ini.nim`,
  `configsource/json.nim`) coexists with the `configsource.nim` leaf
  module at the same path prefix — Nim resolves `import
  argumint/configsource` to the `.nim` file and `import
  argumint/configsource/ini` into the directory without ambiguity. The two
  adapters are separate, opt-in modules (not folded into `configsource.nim`
  itself) so a caller who defines their own `ConfigSource` subclass, or
  doesn't use file-based config at all, never pulls in
  `std/parsecfg`/`std/json`.
- An inherited, pre-existing nuance — not introduced by this feature,
  already true of CLI-vs-env mixing — is called out explicitly rather than
  silently propagated: `applyFallbacks`'s post-walk sweep skips an Arg
  entirely once it has *any* real CLI match, even if the walk already let
  a fallback tier (env or Config Source) stand in for a *different*
  occurrence of the same repeated grammar position. The grammar is
  satisfied (the walk reaches a terminal state), but the fallback-supplied
  occurrence's value is silently never applied. Documented with an
  exploratory test (`tests/test_argumint.nim`, `"exploratory: a mixed
  CLI+config-satisfied repeated position silently drops the config
  contribution"`) that asserts current behavior rather than promising a
  contract, so it's caught if this ever changes.
