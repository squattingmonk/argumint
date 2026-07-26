# Bootstraps a Config Source (ADR 0018) from an ordinary `--config=<file>`
# option, declared right alongside the options it configures. A `before`
# hook triggers a second `parse()` call once `--config` is known -- see ADR
# 0018's "Corrected claim" for why a single parse can't apply a config value
# to its own walk.
#
# Try it with:
#   nim c -r examples/config_bootstrap.nim -- --help
#   nim c -r examples/config_bootstrap.nim -- --port=9000
#   nim c -r examples/config_bootstrap.nim -- --config=examples/config_bootstrap.json --port=9000
#   nim c -r examples/config_bootstrap.nim -- --config=examples/config_bootstrap.json

import std/strformat

import argumint
import argumint/configsource/json

let spec = (
  config: opt("--config=<file>", help = "Path to a JSON config file, consulted before --host/--port defaults"),
  host: opt("--host=<host>", default = "localhost", configKey = "host", help = "Host to bind to"),
  port: opt("--port=<port>", default = 8080, configKey = "port", help = "Port to listen on"),
  help: help()
)

proc reparseWithConfig(s: typeof(spec), info: HookInfo) =
  if s.config.len == 0:
    return
  let settings = newSpecSettings(configSources = @[jsonConfigSource(s.config)])
  spec.parseOrQuit(settings = settings, prolog = "Serve demo")

spec.parseOrQuit(prolog = "Serve demo", before = reparseWithConfig)
echo fmt"Serving on {spec.host}:{spec.port}"
