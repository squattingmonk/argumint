## Value Precedence's Config Source tier -- a value read from a config file
## (or any other external source), consulted for an Option/Flag between the
## env-var tier and the coded default. See
## `docs/adr/0018-config-source.md` and `CONTEXT.md`'s **Config Source**/
## **Config Key** entries for the full design.
##
## This module is a leaf: only `std/options`, no dependency on `backend`/
## `argumint`, so a caller who defines their own `ConfigSource` subclass
## doesn't pull in anything beyond what they already need. The built-in
## `iniConfigSource`/`jsonConfigSource` adapters live in their own separate,
## opt-in modules (`argumint/configsource/ini`, `argumint/configsource/json`)
## for the same reason.

import std/options

type
  ConfigKey* = seq[string]
    ## A structured path into a Config Source, e.g. `@["Package", "Name"]`.
    ## Each adapter interprets segments its own way -- see `ConfigSource`.
    ## Deliberately not a flat delimited string: unlike Env Delimiter's
    ## central-splitting design, a Config Source's own structure (INI
    ## sections, JSON nesting) already has real boundaries a delimiter
    ## would only risk colliding with.

  ConfigSource* = ref object of RootObj
    ## Base type for one layer of the Config Source tier. Subclass and
    ## override `lookup*` to build a custom adapter for an arbitrary config
    ## format -- this is the same open, method-dispatch extension pattern
    ## `Arg` itself uses, not a closed case-object like `Validator`/
    ## `FlagClamp`, since "an arbitrary user-supplied format" needs genuine
    ## third-party subclassability.

method lookup*(self: ConfigSource, key: ConfigKey): Option[seq[string]] {.base.} =
  ## Returns the values found at `key`, already split one element per
  ## logical value (see `ConfigKey`), or `none` if `key` isn't present in
  ## this source at all. Every concrete subclass must override this --  the
  ## base implementation raises, mirroring `backend.Arg`'s own base methods.
  raise newException(Defect, "lookup() is not defined for this ConfigSource")

proc lookupConfigSources*(sources: seq[ConfigSource], key: ConfigKey): Option[seq[string]] =
  ## Consults `sources` in order; the **last** source with a hit for `key`
  ## wins outright -- never merged with an earlier hit, even for a
  ## multi-value result. Keeps one uniform "most-specific-present-tier-wins"
  ## rule across all of Value Precedence, including among layered Config
  ## Sources themselves.
  for source in sources:
    let found = source.lookup(key)
    if found.isSome:
      result = found

converter toConfigKey*(segment: string): ConfigKey =
  ## Lets a `configKey` param be given a single flat string (`configKey =
  ## "port"`), same convenience as `env*`'s implicit `EnvSource` conversion.
  @[segment]

proc configKey*(segments: varargs[string]): ConfigKey =
  ## Builds a multi-segment `ConfigKey`, e.g. `configKey("Package", "Name")`.
  @segments

when isMainModule:
  import std/unittest

  type FakeSource = ref object of ConfigSource
    data: seq[(ConfigKey, seq[string])]

  method lookup(self: FakeSource, key: ConfigKey): Option[seq[string]] =
    for (k, v) in self.data:
      if k == key:
        return some(v)
    none(seq[string])

  suite "ConfigKey":
    test "a plain string converts to a single-segment path":
      let key: ConfigKey = "port"
      check key == @["port"]

    test "configKey builds a multi-segment path":
      check configKey("Package", "Name") == @["Package", "Name"]

  suite "lookupConfigSources":
    test "no sources yields none":
      check lookupConfigSources(@[], configKey("port")).isNone

    test "one source's hit is returned":
      let a = FakeSource(data: @[(configKey("port"), @["8080"])])
      check lookupConfigSources(@[ConfigSource a], configKey("port")).get == @["8080"]

    test "a miss in every source yields none":
      let a = FakeSource(data: @[(configKey("host"), @["localhost"])])
      check lookupConfigSources(@[ConfigSource a], configKey("port")).isNone

    test "a later source without the key doesn't hide an earlier hit":
      let a = FakeSource(data: @[(configKey("port"), @["8080"])])
      let b = FakeSource(data: @[])
      check lookupConfigSources(@[ConfigSource a, ConfigSource b], configKey("port")).get == @["8080"]

    test "a later source's hit fully replaces an earlier one's, never merges":
      let a = FakeSource(data: @[(configKey("tags"), @["a", "b"])])
      let b = FakeSource(data: @[(configKey("tags"), @["c"])])
      check lookupConfigSources(@[ConfigSource a, ConfigSource b], configKey("tags")).get == @["c"]
