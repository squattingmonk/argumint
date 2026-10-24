# A program whose bare `config` Command shows its help through
# `parseOrQuit`, for `tests/test_show_help.nim`.

import argumint

proc config(spec: tuple, info: HookInfo) = showHelp(info)

let
  configSpec = (key: opt("--key=<key>", help = "The key to read"), help: help())
  spec = (config: command("config", configSpec, action = config), help: help())

spec.parseOrQuit(settings = newSpecSettings(style = nil))
