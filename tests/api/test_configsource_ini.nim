# Pins for what `import argumint/configsource/ini` alone reaches (ADR 0090).

import std/[os, unittest]

import argumint/configsource/ini

suite "`import argumint/configsource/ini` alone":
  test "an INI file becomes a Config Source":
    let path = getTempDir() / "argumint_test_pin.ini"
    writeFile(path, "[server]\nport = 9000\n")
    defer: removeFile(path)
    # pins: argumint/configsource/ini.iniConfigSource,string
    check not iniConfigSource(path).isNil
