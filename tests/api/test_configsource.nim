# Pins for what `import argumint/configsource` alone reaches (ADR 0090):
# enough to write a Config Source.

import std/[options, unittest]

import argumint/configsource

# pins: argumint/configsource.ConfigSource
type TableSource = ref object of ConfigSource
  path: string

# pins: argumint/configsource.lookup.e,ConfigSource,ConfigKey
method lookup(self: TableSource, key: ConfigKey): Option[seq[string]] =
  self.path = key.join(".")
  some(@["9000"])

suite "`import argumint/configsource` alone":
  test "a Config Source's `lookup` dispatches":
    let source = TableSource()
    check ConfigSource(source).lookup(configKey("server", "port")) == some(@["9000"])
    check source.path == "server.port"

  test "a ConfigKey reads like a seq[string]":
    # pins: argumint/configsource.ConfigKey
    # pins: argumint/configsource.configKey,varargs[string]
    let key = configKey("server", "port")
    # pins: argumint/configsource.len,ConfigKey
    check key.len == 2
    # pins: argumint/configsource.[],ConfigKey,int
    check key[0] == "server"
    var parts: seq[string]
    # pins: argumint/configsource.items.i,ConfigKey
    for part in key: parts.add part
    check parts == @["server", "port"]
    # pins: argumint/configsource.join,ConfigKey,string
    check key.join == "server.port"
    # pins: argumint/configsource.segments,ConfigKey
    check key.segments == @["server", "port"]
    # pins: argumint/configsource.$,ConfigKey
    check $key == "@[\"server\", \"port\"]"
    # pins: argumint/configsource.==,ConfigKey,ConfigKey
    check key == configKey("server", "port")
    # pins: argumint/configsource.toConfigKey.c,string
    let flat: ConfigKey = "port"
    check flat.len == 1
    # pins: argumint/configsource.noConfigKey
    check noConfigKey().len == 0
