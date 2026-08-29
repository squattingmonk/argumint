## Direct tests for the Value Precedence fallback tiers
## (`argumint/precedence.nim`) -- `docs/adr/0005-env-supplied-multi-value-
## options-and-flags.md`, `docs/adr/0018-config-source.md`, and
## `docs/adr/0039-per-arg-provenance.md`. These moved out of `fsm.nim`'s own
## `when isMainModule` block once the module they belong to existed. See
## issue #65.

import std/[importutils, options, os, unittest]

import argumint
import argumint/[backend, complaints, configsource, precedence]

privateAccess(Spec) ## `specWithConfig` builds a bare `Spec` directly,
  ## since a `TestArg` subclass can't be routed through the public
  ## `newSpec` -- see docs/gotchas.md.

type
  TestArg = ref object of Arg
    ## A minimal concrete Arg for exercising `Tiers.probe`/`applyFallbacks`
    ## directly, without going through `argumint.nim`'s `ValueArg`/
    ## `FlagArg` (which import `fsm.nim`, so the reverse import isn't
    ## available here).
    env: options.Option[EnvSource]
    cfg: ConfigKey
    recorded: seq[string]
    configRecorded: seq[string]

  FakeSource = ref object of ConfigSource
    data: seq[(ConfigKey, seq[string])]

  CountingSource = ref object of ConfigSource
    ## Counts `lookup` calls, to verify a tier's `probe` only ever resolves
    ## once per Arg even across several `probe` calls.
    lookups: int

method envSource(self: TestArg): options.Option[EnvSource] = self.env
method configKey(self: TestArg): ConfigKey = self.cfg
method parse(self: TestArg, value: string, variant = "",
             seenBy: options.Option[SeenBy] = none(SeenBy)) =
  ## Records per tier, so the fallback sweep's two paths stay
  ## distinguishable once each tier writes through `parse`.
  self.arbitrate(seenBy)
  if seenBy == some(byConfig): self.configRecorded.add value
  else: self.recorded.add value

method lookup(self: FakeSource, key: ConfigKey): options.Option[seq[string]] =
  for (k, v) in self.data:
    if k == key:
      return some(v)
  none(seq[string])

method lookup(self: CountingSource, key: ConfigKey): options.Option[seq[string]] =
  self.lookups.inc
  some(@["x"])

proc newTestArg(name: string, env = "", delim = none(string), cfg: ConfigKey = noConfigKey()): TestArg =
  ## `env`/`delim` stay separate params for the call sites' benefit; they
  ## assemble into the single `EnvSource` the contract now hands back.
  let source =
    if env.len == 0: none(EnvSource)
    else: some(EnvSource(name: env, delim: delim))
  TestArg(kind: Optional, variants: @[name], env: source, cfg: cfg)

proc specWithConfig(sources: seq[ConfigSource] = @[], args: seq[Arg] = @[]): Spec =
  Spec(settings: SpecSettings(envDelim: ":", configSources: sources), args: args)

suite "Tiers.probe (env tier)":
  # Each arg here has no config key, so `Tiers.probe`'s fall-through to the
  # config tier is a guaranteed miss -- these exercise the env tier alone.
  test "false when the arg has no env var configured":
    var tiers: Tiers
    let arg = newTestArg("--foo")
    let spec = specWithConfig()
    check not tiers.probe(arg, spec)

  test "false when the configured env var isn't set":
    delEnv("ARGUMINT_TEST_UNSET")
    var tiers: Tiers
    let arg = newTestArg("--foo", "ARGUMINT_TEST_UNSET")
    let spec = specWithConfig()
    check not tiers.probe(arg, spec)

  test "hands out a single value once, then reports exhausted":
    putEnv("ARGUMINT_TEST_SINGLE", "hello")
    defer: delEnv("ARGUMINT_TEST_SINGLE")
    var tiers: Tiers
    let arg = newTestArg("--foo", "ARGUMINT_TEST_SINGLE")
    let spec = specWithConfig()
    check tiers.probe(arg, spec)
    check not tiers.probe(arg, spec)

  test "hands out each delimiter-split value in order":
    putEnv("ARGUMINT_TEST_MULTI", "a:b:c")
    defer: delEnv("ARGUMINT_TEST_MULTI")
    var tiers: Tiers
    let arg = newTestArg("--foo", "ARGUMINT_TEST_MULTI")
    let spec = specWithConfig()
    check tiers.probe(arg, spec)
    check tiers.probe(arg, spec)
    check tiers.probe(arg, spec)
    check not tiers.probe(arg, spec)

  test "a per-arg delim override is used instead of Spec.settings.envDelim":
    putEnv("ARGUMINT_TEST_OVERRIDE", "a;b;c")
    defer: delEnv("ARGUMINT_TEST_OVERRIDE")
    var tiers: Tiers
    let arg = newTestArg("--foo", "ARGUMINT_TEST_OVERRIDE", some(";"))
    let spec = specWithConfig()
    check tiers.probe(arg, spec)
    check tiers.probe(arg, spec)
    check tiers.probe(arg, spec)
    check not tiers.probe(arg, spec)

  test "an empty per-arg delim override means the whole value is a single element":
    putEnv("ARGUMINT_TEST_NOSPLIT", "a:b")
    defer: delEnv("ARGUMINT_TEST_NOSPLIT")
    var tiers: Tiers
    let arg = newTestArg("--foo", "ARGUMINT_TEST_NOSPLIT", some(""))
    let spec = specWithConfig()
    check tiers.probe(arg, spec)
    check not tiers.probe(arg, spec)

suite "Tiers.probe (config tier)":
  # Each arg here has no env var configured, so `Tiers.probe`'s env attempt
  # is a guaranteed miss -- these exercise the config tier alone.
  test "false when the arg has no config key configured":
    var tiers: Tiers
    let arg = newTestArg("--foo")
    let spec = specWithConfig(@[ConfigSource FakeSource(data: @[(configKey("foo"), @["x"])])])
    check not tiers.probe(arg, spec)

  test "false when no configured source has the key":
    var tiers: Tiers
    let arg = newTestArg("--foo", cfg = configKey("foo"))
    let spec = specWithConfig(@[ConfigSource FakeSource(data: @[])])
    check not tiers.probe(arg, spec)

  test "hands out each value in order, then reports exhausted":
    var tiers: Tiers
    let arg = newTestArg("--foo", cfg = configKey("foo"))
    let spec = specWithConfig(@[ConfigSource FakeSource(data: @[(configKey("foo"), @["a", "b"])])])
    check tiers.probe(arg, spec)
    check tiers.probe(arg, spec)
    check not tiers.probe(arg, spec)

  test "a later source's hit fully replaces an earlier one's":
    var tiers: Tiers
    let arg = newTestArg("--foo", cfg = configKey("foo"))
    let spec = specWithConfig(@[
      ConfigSource FakeSource(data: @[(configKey("foo"), @["a", "b"])]),
      ConfigSource FakeSource(data: @[(configKey("foo"), @["c"])]),
    ])
    check tiers.probe(arg, spec)
    check not tiers.probe(arg, spec)

  test "resolve runs at most once per arg, even across several probes":
    var tiers: Tiers
    let arg = newTestArg("--foo", cfg = configKey("foo"))
    let source = CountingSource()
    let spec = specWithConfig(@[ConfigSource source])
    check tiers.probe(arg, spec)
    check not tiers.probe(arg, spec)
    check source.lookups == 1

suite "applyFallbacks (env tier)":
  test "sets an unconsulted arg's value directly from env":
    putEnv("ARGUMINT_TEST_DIRECT", "hi")
    defer: delEnv("ARGUMINT_TEST_DIRECT")
    let arg = newTestArg("--foo", "ARGUMINT_TEST_DIRECT")
    let spec = specWithConfig(args = @[Arg arg])
    var tiers: Tiers
    var report = initReport(spec, "")
    applyFallbacks(tiers, @[spec], report)
    check report.isEmpty
    check arg.recorded == @["hi"]

  test "applies every split value once the walk fully consumed them":
    putEnv("ARGUMINT_TEST_CONSUMED", "a:b")
    defer: delEnv("ARGUMINT_TEST_CONSUMED")
    let arg = newTestArg("--foo", "ARGUMINT_TEST_CONSUMED")
    let spec = specWithConfig(args = @[Arg arg])
    var tiers: Tiers
    check tiers.probe(arg, spec)
    check tiers.probe(arg, spec)
    var report = initReport(spec, "")
    applyFallbacks(tiers, @[spec], report)
    check report.isEmpty
    check arg.recorded == @["a", "b"]

  test "complains about env values the walk didn't consume":
    putEnv("ARGUMINT_TEST_LEFTOVER", "a:b:c")
    defer: delEnv("ARGUMINT_TEST_LEFTOVER")
    let arg = newTestArg("--foo", "ARGUMINT_TEST_LEFTOVER")
    let spec = specWithConfig(args = @[Arg arg])
    var tiers: Tiers
    discard tiers.probe(arg, spec) # consumes only 1 of the 3 available values
    var report = initReport(spec, "")
    applyFallbacks(tiers, @[spec], report)
    check report.finalComplaints == @[(kind: "unexpected option", subject: arg.name, names: true)]

  test "an arg reachable from two spec levels only complains once":
    # The oversupply branch applies nothing, so `seenBy` stays `byNone` and
    # can't gate the second visit -- `cursor.complained` does. See ADR 0039.
    putEnv("ARGUMINT_TEST_TWICE", "a:b:c")
    defer: delEnv("ARGUMINT_TEST_TWICE")
    let arg = newTestArg("--foo", "ARGUMINT_TEST_TWICE")
    let spec = specWithConfig(args = @[Arg arg])
    var tiers: Tiers
    discard tiers.probe(arg, spec) # consumes only 1 of 3
    var report = initReport(spec, "")
    applyFallbacks(tiers, @[spec, spec], report) # same arg, two levels
    check report.finalComplaints == @[(kind: "unexpected option", subject: arg.name, names: true)]

  test "skips an arg already explicitly matched on the command line":
    putEnv("ARGUMINT_TEST_SKIP", "hi")
    defer: delEnv("ARGUMINT_TEST_SKIP")
    let arg = newTestArg("--foo", "ARGUMINT_TEST_SKIP")
    let spec = specWithConfig(args = @[Arg arg])
    var tiers: Tiers
    # The gate is the Arg's own tier, which `parse*` sets from the match
    # table before calling this -- not a `matches` lookup here. See ADR 0039.
    arg.seenBy = byCli
    var report = initReport(spec, "")
    applyFallbacks(tiers, @[spec], report)
    check report.isEmpty
    check arg.recorded.len == 0

suite "applyFallbacks (config tier)":
  test "sets an unconsulted arg's value directly from a Config Source":
    let arg = newTestArg("--foo", cfg = configKey("foo"))
    let source = FakeSource(data: @[(configKey("foo"), @["hi"])])
    let spec = specWithConfig(@[ConfigSource source], args = @[Arg arg])
    var tiers: Tiers
    var report = initReport(spec, "")
    applyFallbacks(tiers, @[spec], report)
    check report.isEmpty
    check arg.configRecorded == @["hi"]

  test "complains about config values the walk didn't consume":
    let arg = newTestArg("--foo", cfg = configKey("foo"))
    let source = FakeSource(data: @[(configKey("foo"), @["a", "b", "c"])])
    let spec = specWithConfig(@[ConfigSource source], args = @[Arg arg])
    var tiers: Tiers
    discard tiers.probe(arg, spec) # consumes only 1 of 3
    var report = initReport(spec, "")
    applyFallbacks(tiers, @[spec], report)
    check report.finalComplaints == @[(kind: "unexpected option", subject: arg.name, names: true)]

  test "env present takes precedence, config is never consulted":
    putEnv("ARGUMINT_TEST_PRECEDENCE", "from-env")
    defer: delEnv("ARGUMINT_TEST_PRECEDENCE")
    let arg = newTestArg("--foo", "ARGUMINT_TEST_PRECEDENCE", cfg = configKey("foo"))
    let source = FakeSource(data: @[(configKey("foo"), @["from-config"])])
    let spec = specWithConfig(@[ConfigSource source], args = @[Arg arg])
    var tiers: Tiers
    var report = initReport(spec, "")
    applyFallbacks(tiers, @[spec], report)
    check arg.recorded == @["from-env"]
    check arg.configRecorded.len == 0

  test "falls through to config when env is unset":
    let arg = newTestArg("--foo", "ARGUMINT_TEST_ABSENT", cfg = configKey("foo"))
    let source = FakeSource(data: @[(configKey("foo"), @["from-config"])])
    let spec = specWithConfig(@[ConfigSource source], args = @[Arg arg])
    var tiers: Tiers
    var report = initReport(spec, "")
    applyFallbacks(tiers, @[spec], report)
    check report.isEmpty
    check arg.recorded.len == 0
    check arg.configRecorded == @["from-config"]
