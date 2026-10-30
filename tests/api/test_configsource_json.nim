# Pins for what `import argumint/configsource/json` alone reaches (ADR 0090).

import std/[os, unittest]

import argumint/configsource/json

suite "`import argumint/configsource/json` alone":
  test "a JSON file becomes a Config Source":
    let path = getTempDir() / "argumint_test_pin.json"
    writeFile(path, """{"server": {"port": 9000}}""")
    defer: removeFile(path)
    # pins: argumint/configsource/json.jsonConfigSource,string
    check not jsonConfigSource(path).isNil
