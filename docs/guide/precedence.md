# Value Precedence

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

## Value Precedence

`opt`/`opts`/`flag` (not `arg`/`args` — there's no env var or config key to
name a positional argument by) can fall back to more than a coded `default`
when the user gives no value on the command line. In order, **Value
Precedence** tries:

1. an explicit value from the command line
2. an environment variable (`env`)
3. a registered Config Source (`configKey`)
4. the coded `default`

The most specific tier present always wins outright — nothing is ever
merged across tiers — and this applies whether the Option/Flag is required
or optional in the usage grammar.

### Env Vars

`env` names an environment variable to consult: a plain string is the
common case, or `env(name, delim)` overrides how a multi-value env string
is split (default `:`, `Spec.settings.envDelim`'s own default; `delim = ""`
disables splitting entirely).

```nim
let spec = (
  port: opt("--port=<n>", default = 8080, env = "PORT"),
  tags: opts("--tag=<t>", env = env("TAGS", ","))
)
```

`PORT=9000` sets `spec.port` to `9000` with no `--port` on the command
line; `TAGS=a,b,c` sets `spec.tags` to `@["a", "b", "c"]`. A CLI value
always wins over either. For a `flag`, each env value must instead name one
of the flag's own variants (e.g. `LOGGING=--verbose`), applied via that
variant's own Flag Operation.

### Config Sources

`configKey` names a structured path into a registered Config Source,
consulted below env vars, above the coded default:

```nim
import argumint/configsource/json

let spec = (
  port: opt[int]("--port=<n>", default = 8080, configKey = "port")
)

spec.parseOrQuit(
  settings = newSpecSettings(configSources = @[jsonConfigSource("config.json")]))
```

A bare string is a one-segment path; nest with `configKey("server",
"port")`. A `ConfigKey` is a `distinct seq[string]`, so a custom
`ConfigSource` addresses it with `key.len`, `key[i]`, and `for segment in
key`, and calls `key.segments` for the underlying `seq[string]` — see
`docs/adr/0029-config-key-distinct.md` for why it isn't a plain alias.

Built-in adapters: `iniConfigSource(path)` (`std/parsecfg`-backed) and
`jsonConfigSource(path)` (`std/json`-backed), both reading and parsing
eagerly at that call. Write your own by subclassing `ConfigSource` and
overriding `lookup`. `SpecSettings.configSources` can hold more than one —
the last one with a hit for a given `configKey` wins outright, the same
never-merge rule as the rest of Value Precedence. See
`examples/config_bootstrap.nim` for a full runnable demo bootstrapping a
Config Source from a `--config=<file>` option via a `before` hook, and
`docs/adr/0018-config-source.md` for the full design.
