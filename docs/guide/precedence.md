# Value Precedence

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

An option or flag can take its value from more than the command line. It can
also read an environment variable or a config file, and fall back to its
default when none of them has a value:

```nim
import argumint
import argumint/configsource/json

let spec = (
  port: opt("-p, --port=<n>", default = 8080, env = "PORT", configKey = "port",
    help = "Port to listen on"),
  help: help(),
)

spec.parseOrQuit(settings = newSpecSettings(configSources = @[jsonConfigSource("serve.json")]))
echo "port=", spec.port, " from ", spec.port.seenBy
```

With a `serve.json` of `{"port": 9090}`:

```console
$ ./serve
port=9090 from byConfig
$ PORT=9000 ./serve
port=9000 from byEnv
$ PORT=9000 ./serve -p 81
port=81 from byCli
```

argumint tries each source in this order, and the first one with a value wins:

1. The command line.
2. The environment variable named by `env`.
3. The config files, at the key named by `configKey`.
4. The default.

Values from different sources are never merged. An `opts` given on the
command line ignores the values in its environment variable and config file.
`seenBy` says which source a value came from. See
[Where a Value Came From](specs.md#where-a-value-came-from).

Help shows where else each value can come from:

```console
$ ./serve --help
Usage:
  serve [options]
  serve (-h | --help)

Options:
  -p, --port=<n>  Port to listen on [default: 8080; env: PORT; configKey: port]
  -h, --help      Display this help message
```

Only options and flags have these sources. A positional argument has no name
for an environment variable or config key to use.

An environment variable or config file can also supply an option that the
usage string requires, so the user doesn't have to type it.

## Environment Variables

Pass the variable's name as `env`. Its value is converted and validated like
one typed on the command line, and a bad value is reported with the
variable's name:

```nim
import argumint

let spec = (
  port: opt("-p, --port=<n>", default = 8080, env = "PORT",
    help = "Port to listen on", validator = range(1..65535)),
  help: help(),
)

spec.parseOrQuit()
echo "port=", spec.port
```

```console
$ PORT=9000 ./serve
port=9000
$ PORT=abc ./serve
Parsing error:
  - expected an integer for -p (env: PORT) but got "abc"

Usage:
  serve [options]
  serve (-h | --help)
$ PORT=0 ./serve
Validation error:
  - for -p (env: PORT), got 0 but expected a value in 1..65535

Usage:
  serve [options]
  serve (-h | --help)
```

A variable that's set but empty still counts, so `PORT=` is an error rather
than the default.

### Splitting a Variable into Several Values

argumint splits every variable on `:`, the way `PATH` is split, so one
variable can give an `opts` several values:

```nim
import argumint

let spec = (
  paths: opts("-I, --include=<dir>", env = "INCLUDE", help = "Directories to search"),
  tags: opts("-t, --tag=<tag>", env = env("TAGS", ","), help = "Tags"),
  url: opt("--url=<url>", env = env("URL", ""), help = "Server to use"),
)

spec.parseOrQuit()
echo "paths=", spec.paths, " tags=", spec.tags, " url=", spec.url
```

```console
$ INCLUDE=src:lib TAGS=web,prod URL=http://example.com:80 ./search
paths=@["src", "lib"] tags=@["web", "prod"] url=http://example.com:80
```

`env(name, delim)` splits that variable on `delim` instead. An empty `delim`
turns splitting off, which any value that can contain the delimiter needs,
like the URL above. To change the delimiter for every variable, pass
`envDelim` to `newSpecSettings`.

fish exports a list variable with its items separated by spaces, so
`set -x TAGS web prod` gives `TAGS=web prod`. A fish user can write
`set -x TAGS web:prod` instead, which needs nothing from you. To accept
fish's list as two values too, split on a space: `env("TAGS", " ")` for one
option, `newSpecSettings(envDelim = " ")` for every variable, or
`-d:argumint.envDelim=" "` at build time. fish still separates the items of
a variable whose name ends in `PATH` with `:`, which the default already
splits.

Had `url` named its variable without turning splitting off, the URL would
split into three values:

```nim
url: opt("--url=<url>", env = "URL", help = "Server to use"),
```

An `opt` keeps only one value, so that's an error rather than a URL cut
short:

```console
$ URL=http://example.com:80 ./search
Parsing error:
  - unexpected option: --url (env: URL)

Usage:
  search [options]
```

### Flags from a Variable

A flag's variable holds the names of the flag to apply, as if the user had
typed them:

```nim
import argumint

let spec = (
  verbose: flag[int]("-v, --verbose", env = "VERBOSE", help = "Show more"),
)

spec.parseOrQuit()
echo "verbose=", spec.verbose
```

```console
$ VERBOSE=--verbose ./talk
verbose=1
$ VERBOSE=-v:-v ./talk
verbose=2
$ VERBOSE=2 ./talk
Parsing error:
  - "2" is not a known variant for the flag -v (env: VERBOSE)

Usage:
  talk [options]
```

## Config Files

A **config source** reads values from a file. Pass a list of them to
`newSpecSettings` as `configSources`, and give each option the `configKey` to
look up. argumint comes with two:

- `jsonConfigSource(path)`, from `argumint/configsource/json`.
- `iniConfigSource(path)`, from `argumint/configsource/ini`.

Both read the file as soon as you call them. They raise an `IOError` if they
can't read it, so check that an optional file exists first, and a `ValueError`
if it isn't valid JSON or INI.

A key can have more than one part. `configKey("server", "port")` looks up
`port` inside `server`. This program reads `site.json`, then `local.json`:

```nim
import argumint
import argumint/configsource/json

let spec = (
  host: opt("--host=<host>", default = "localhost",
    configKey = configKey("server", "host"), help = "Host to bind to"),
  port: opt("--port=<n>", default = 8080,
    configKey = configKey("server", "port"), help = "Port to listen on"),
  tags: opts("-t, --tag=<tag>", configKey = "tags", help = "Tags"),
  verbose: flag[int]("-v, --verbose", configKey = "verbose", help = "Show more"),
)

spec.parseOrQuit(settings = newSpecSettings(configSources = @[
  jsonConfigSource("site.json"), jsonConfigSource("local.json")]))
echo "host=", spec.host, " port=", spec.port, " tags=", spec.tags, " verbose=", spec.verbose
```

`site.json` holds:

```json
{
  "server": {"host": "0.0.0.0", "port": 9090},
  "tags": ["web", "prod"],
  "verbose": ["--verbose", "--verbose"]
}
```

A JSON array gives several values. As with an environment variable, a flag's
values are its names.

When there's more than one config source, the last one with a value for a key
wins. With a `local.json` of `{"server": {"port": 7000}}`:

```console
$ ./site
host=0.0.0.0 port=7000 tags=@["web", "prod"] verbose=2
```

An INI file uses one part for a key before any section, and two parts for a
key in a section. A key written more than once gives several values:

```ini
tag = web
tag = prod

[server]
host = 0.0.0.0
port = 9090
```

Here `configKey = "tag"` gives `@["web", "prod"]`, and
`configKey("server", "port")` gives `9090`.

### Choosing the File at Run Time

To let the user name the config file, add an option for it, and parse again
from a `before` hook once you know the file:

```nim
import std/os
import argumint
import argumint/configsource/json

let spec = (
  config: opt("--config=<file>", help = "Config file to read"),
  host: opt("--host=<host>", default = "localhost", configKey = "host", help = "Host to bind to"),
  port: opt("--port=<port>", default = 8080, configKey = "port", help = "Port to listen on"),
  help: help(),
)

proc reparseWithConfig(s: typeof(spec), _: HookInfo) =
  if s.config.len == 0:
    return
  if not fileExists(s.config):
    quit "Can't read " & s.config
  let settings = newSpecSettings(configSources = @[jsonConfigSource(s.config)])
  s.parseOrQuit(settings = settings)

spec.parseOrQuit(before = reparseWithConfig)
echo "Serving on ", spec.host, ":", spec.port
```

```console
$ ./serve
Serving on localhost:8080
$ ./serve --config=serve.json
Serving on 0.0.0.0:9090
$ ./serve --config=serve.json --port 1
Serving on 0.0.0.0:1
$ ./serve --config=nope.json
Can't read nope.json
```

The first parse finds `--config` and runs the `before` hook. The hook parses
again with the file as a config source, which fills in the other options. The
command line still wins, as `--port 1` shows. See [Commands](commands.md) for
more on hooks.

### Your Own Config Format

To read another format, or values from somewhere other than a file, make a
type of `ConfigSource` and give it a `lookup` method. `lookup` returns the
values at a key as strings, or `none` if the key isn't there:

```nim
import std/[options, strutils, tables]
import argumint

type TableSource = ref object of ConfigSource
  values: Table[string, string]

method lookup(self: TableSource, key: ConfigKey): Option[seq[string]] =
  let path = key.join(".")
  if path in self.values:
    some(self.values[path].split(','))
  else:
    none(seq[string])

let builtIn: ConfigSource = TableSource(values: {"server.port": "9000", "tags": "a,b"}.toTable)

let spec = (
  port: opt("--port=<n>", default = 8080, configKey = configKey("server", "port")),
  tags: opts("--tag=<tag>", configKey = "tags"),
)

spec.parseOrQuit(settings = newSpecSettings(configSources = @[builtIn]))
echo "port=", spec.port, " tags=", spec.tags
```

```console
$ ./custom
port=9000 tags=@["a", "b"]
```

A `ConfigKey` works like a `seq[string]`: use `key.len`, `key[i]`, or
`for part in key`. `key.join(".")` joins the parts, and `key.segments` gives
the `seq[string]` itself.
