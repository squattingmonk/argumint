## Owns "what value, if any, does a fallback tier supply for this Arg" --
## `docs/adr/0005-env-supplied-multi-value-options-and-flags.md` and
## `docs/adr/0018-config-source.md`. `FallbackTier` names Value Precedence's
## two fallback tiers, declared strongest-first so iteration order *is* the
## precedence order; `Tiers` holds one `ValueCursor` per tier so the walk
## and the post-walk sweep each consult one thing, not two. `probe` lets a
## tier's value stand in for a missing CLI value during the walk, and
## `applyFallbacks` is the post-walk sweep that actually writes whatever
## the walk consumed. `fsm.nim` owns the walk itself and failure reporting
## -- see `docs/architecture.md` §3.
import std/[importutils, options, sets, tables]
from std/os import existsEnv, getEnv

import ./[backend, complaints, configsource]

privateAccess(Spec) ## Reaches `Spec`'s private `args` (ADR 0030) --
  ## non-generic code only, see docs/gotchas.md.

type
  FallbackTier* = enum
    ## Value Precedence's two fallback tiers, declared strongest-first so
    ## iteration order *is* the precedence order: env before Config Source,
    ## matching `docs/adr/0018-config-source.md`.
    ftEnv, ftConfig

  ValueCursor = object
    ## Owns one Value Precedence fallback tier's bookkeeping. `probe`
    ## resolves and caches an Arg's available values the first time it's
    ## consulted during the walk, then hands out one value per subsequent
    ## call; `applyFallbacks`'s post-walk sweep reads `consumed`/`values`
    ## back to apply whatever the walk consumed (or complain about
    ## oversupply).
    values: Table[Arg, seq[string]]
    consumed: Table[Arg, int]
    tried: HashSet[Arg]
      ## Ensures `resolve` runs at most once per Arg for the life of this
      ## cursor, including caching a miss -- unlike an env lookup, a
      ## user-supplied `ConfigSource.lookup` may be arbitrarily expensive.
    applied: HashSet[Arg]
      ## Ensures this tier applies to an Arg at most once, even when the Arg
      ## is reachable from more than one spec level. Used to ride on the
      ## `seenBy` gate, which can't do it now that a same-tier Arg is
      ## appended to rather than skipped.
    complained: HashSet[Arg]
      ## Ensures an Arg reachable from two spec levels only draws one
      ## oversupply complaint -- that branch applies nothing, so `seenBy`
      ## can't gate it the way it gates a real application. See ADR 0039.

  Tiers* = object
    ## Both fallback tiers together, one `ValueCursor` each, indexed by
    ## `FallbackTier` -- so `match`'s `Option` arm and `applyFallbacks`
    ## each consult one thing, not a closure-wrapped pair.
    cursors: array[FallbackTier, ValueCursor]

proc seenBy(t: FallbackTier): SeenBy =
  case t
  of ftEnv: byEnv
  of ftConfig: byConfig

proc sourceLabel(t: FallbackTier, arg: Arg): string =
  ## The source label `arg.parse` records as this tier's variant -- what
  ## `subject` (`backend.nim`) renders as e.g. `--port (env: PORT)` when a
  ## fallback value turns out to be bad.
  case t
  of ftEnv: arg.envName
  of ftConfig: arg.configKey.join

proc resolveEnv(arg: Arg, spec: Spec): options.Option[seq[string]] =
  ## Resolver for the env tier -- see architecture.md's "Env var mechanics".
  let source = arg.envSource
  if source.isNone or not existsEnv(source.get.name):
    none(seq[string])
  else:
    some(splitEnvValue(getEnv(source.get.name), source.get.delim, spec.settings.envDelim))

proc resolveConfig(arg: Arg, spec: Spec): options.Option[seq[string]] =
  ## Resolver for the Config Source tier -- see
  ## `docs/adr/0018-config-source.md`.
  let key = arg.configKey
  if key.len == 0:
    none(seq[string])
  else:
    lookupConfigSources(spec.settings.configSources, key)

proc resolve(t: FallbackTier, arg: Arg, spec: Spec): options.Option[seq[string]] =
  case t
  of ftEnv: resolveEnv(arg, spec)
  of ftConfig: resolveConfig(arg, spec)

proc probe(cursor: var ValueCursor, t: FallbackTier, arg: Arg, spec: Spec): bool =
  ## Lets `t`'s value stand in for a missing CLI value during the walk --
  ## `resolve` is called at most once per `arg` for the life of `cursor`
  ## (see `ValueCursor.tried`). Returning `false` just lets the walk fail
  ## normally; the actual value-setting happens later, in
  ## `applyFallbacks`'s post-walk sweep.
  if arg notin cursor.tried:
    cursor.tried.incl arg
    let found = t.resolve(arg, spec)
    if found.isSome:
      cursor.values[arg] = found.get
  if arg notin cursor.values:
    return false
  let consumed = cursor.consumed.getOrDefault(arg, 0)
  if consumed < cursor.values[arg].len:
    cursor.consumed[arg] = consumed + 1
    return true

proc probe*(tiers: var Tiers, arg: Arg, spec: Spec): bool =
  ## Tries each fallback tier in precedence order -- env, then Config
  ## Source -- for a CLI token `match`'s `Option` arm couldn't find.
  for t in FallbackTier:
    if tiers.cursors[t].probe(t, arg, spec):
      return true

proc applyTier(cursor: var ValueCursor, t: FallbackTier, arg: Arg, spec: Spec,
    report: var Report): bool =
  ## Applies `t`'s contribution to `arg` in `applyFallbacks`'s post-walk
  ## sweep, mirroring `probe`'s own consumption-count semantics: if the
  ## walk actually visited `arg`'s matcher and pulled values from this tier
  ## (`arg in cursor.consumed`), apply everything the tier had available,
  ## or complain if the walk didn't consume all of it (more values than
  ## the grammar had positions for). If the matcher was visited but
  ## `resolve` found nothing (`arg in cursor.tried` but not
  ## `cursor.consumed`), there's nothing to apply -- and, per
  ## `ValueCursor.tried`'s own contract, `resolve` must not be called
  ## again here even though it would return the same answer, since it may
  ## be an arbitrarily expensive user-supplied `ConfigSource.lookup`. Only
  ## when the matcher was never visited at all this walk (reachable only
  ## via a different, unmatched Usage Line -- `arg notin cursor.tried`)
  ## does this resolve fresh and apply every available value -- recording
  ## that in `cursor.tried` too, so an Arg reachable from two spec levels
  ## still only resolves once. Returns whether this tier had anything at
  ## all for `arg` -- a real application, or an oversupply complaint --
  ## telling the caller whether to fall through to the next-lower tier.
  if arg in cursor.applied:
    return true
  if arg in cursor.consumed:
    result = true
    let consumed = cursor.consumed[arg]
    let total = cursor.values[arg].len
    if consumed < total:
      if arg notin cursor.complained:
        cursor.complained.incl arg
        report.unexpected(arg)
    else:
      cursor.applied.incl arg
      for v in cursor.values[arg]:
        arg.parse(v, t.sourceLabel(arg), some(t.seenBy))
  elif arg notin cursor.tried:
    cursor.tried.incl arg
    let found = t.resolve(arg, spec)
    if found.isSome:
      result = true
      cursor.applied.incl arg
      for v in found.get:
        arg.parse(v, t.sourceLabel(arg), some(t.seenBy))

proc applyFallbacks*(tiers: var Tiers, specs: seq[Spec], report: var Report) =
  ## Sweeps every spec level actually entered during this parse (the chain
  ## the walk recorded -- see architecture.md §5), falling back to each
  ## not-yet-supplied Arg's env var, then (only if env had nothing) its
  ## Config Source value. Deliberately outside `walk`'s FSM/backtracking,
  ## so an Arg only reachable via `[options]` still picks up its fallback
  ## values -- see architecture.md's "Env var mechanics",
  ## `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`, and
  ## `docs/adr/0018-config-source.md` for the value-count/`ParseError`
  ## rules, shared identically by both tiers.
  ##
  ## Each tier is gated on `Arg.seenBy`, which the command-line tier has
  ## already written by the time this runs (`parseAllValues`): `arg.seenBy
  ## > t.seenBy` breaks out for the rest of this Arg's tiers, since tiers
  ## descend in strength -- an Arg already at a given tier is appended to,
  ## not skipped, so a pre-seed declaring `byEnv` still collects the env
  ## var's own values. Clearing a weaker pre-seed happens where the write
  ## does (`parse`), not here -- a tier consulted but resolving nothing must
  ## leave a pre-seed intact. `ValueCursor.applied`, not this gate, is what
  ## stops an Arg reachable from two spec levels being applied twice.
  ## See `docs/adr/0039-per-arg-provenance.md` and
  ## `docs/adr/0041-parse-is-the-write-surface.md`.
  ##
  ## Runs to completion (or raises) entirely before `dispatch` is called --
  ## so a fallback problem at any level blocks every level's hooks from
  ## firing at all, not just that level's, since `dispatch` never starts.
  for s in specs:
    let spec = s # local copy -- a `for` loop's `lent` yield can't be captured below
    for a in spec.args:
      let arg = a # local copy, for the same reason
      for t in FallbackTier:
        if arg.seenBy > t.seenBy:
          break
        if tiers.cursors[t].applyTier(t, arg, spec, report):
          break
