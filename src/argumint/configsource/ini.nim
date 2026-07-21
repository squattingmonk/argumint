## An INI-file `ConfigSource` backed by `std/parsecfg`. Uses `parsecfg`'s
## low-level streaming `CfgParser`/`CfgEvent` API directly rather than
## `loadConfig` -- `loadConfig` builds a `Config` (one string per key, last
## write wins), which can't represent a key repeated more than once in the
## file. Streaming lets a repeated key accumulate into a real `seq[string]`
## instead. See `docs/adr/0018-config-source.md`.

import std/[options, parsecfg, streams, tables]
import ../configsource

type
  IniConfigSource = ref object of ConfigSource
    data: Table[(string, string), seq[string]]
      ## Keyed by `(section, key)`; the global scope (before any
      ## `[section]` header) is the empty-string section `""`.

proc iniConfigSource*(path: string): ConfigSource =
  ## Reads and parses the INI file at `path` eagerly, right here at this
  ## call -- an ordinary `IOError` (missing/unreadable file) or `ValueError`
  ## (malformed syntax) is raised in the caller's own code, deliberately
  ## outside argumint's `SpecDefect`/`ParseError` taxonomy, since this
  ## happens before any Spec construction or parsing has even begun.
  let stream = newFileStream(path, fmRead)
  if stream.isNil:
    raise newException(IOError, "cannot open config file: " & path)

  var p: CfgParser
  p.open(stream, path)
  var section = ""
  var data: Table[(string, string), seq[string]]
  try:
    while true:
      let e = p.next()
      case e.kind
      of cfgSectionStart:
        section = e.section
      of cfgKeyValuePair, cfgOption:
        data.mgetOrPut((section, e.key), @[]).add(e.value)
      of cfgError:
        # parsecfg documents that no exception is thrown on cfgError --
        # this adapter raises one itself so a malformed file fails loudly,
        # per requirement 6's "raises there" I/O-ownership decision.
        raise newException(ValueError, p.errorStr(e.msg))
      of cfgEof:
        break
  finally:
    p.close()

  IniConfigSource(data: data)

method lookup(self: IniConfigSource, key: ConfigKey): Option[seq[string]] =
  ## `key.len == 1` addresses the global scope (before any `[section]`);
  ## `key.len == 2` addresses `[key[0]]`'s `key[1]`. Any other length is an
  ## addressing shape this adapter simply doesn't support -- treated the
  ## same as absent (`none`), not an error.
  let sectionKey =
    case key.len
    of 1: ("", key[0])
    of 2: (key[0], key[1])
    else: return none(seq[string])
  if self.data.hasKey(sectionKey):
    some(self.data[sectionKey])
  else:
    none(seq[string])

when isMainModule:
  import std/unittest
  import std/os as osmod

  proc withTempIni(content: string, body: proc (path: string)) =
    let path = osmod.getTempDir() / "argumint_test_" & $osmod.getCurrentProcessId() & ".ini"
    writeFile(path, content)
    try: body(path)
    finally: osmod.removeFile(path)

  suite "iniConfigSource":
    test "a repeated key accumulates into a multi-element seq":
      withTempIni("tag=a\ntag=b\ntag=c\n") do (path: string):
        let source = iniConfigSource(path)
        check source.lookup(configKey("tag")).get == @["a", "b", "c"]

    test "a 1-segment key addresses the global scope":
      withTempIni("name=nasher\n") do (path: string):
        let source = iniConfigSource(path)
        check source.lookup(configKey("name")).get == @["nasher"]

    test "a 2-segment key addresses [section] key":
      withTempIni("[Package]\nname=nasher\n") do (path: string):
        let source = iniConfigSource(path)
        check source.lookup(configKey("Package", "name")).get == @["nasher"]

    test "a key present in a section is not visible globally, and vice versa":
      withTempIni("global=1\n[Package]\nname=nasher\n") do (path: string):
        let source = iniConfigSource(path)
        check source.lookup(configKey("name")).isNone
        check source.lookup(configKey("Package", "global")).isNone

    test "a missing key returns none":
      withTempIni("name=nasher\n") do (path: string):
        let source = iniConfigSource(path)
        check source.lookup(configKey("missing")).isNone

    test "malformed syntax raises":
      withTempIni("[unterminated\n") do (path: string):
        expect ValueError:
          discard iniConfigSource(path)

    test "a missing file raises":
      expect IOError:
        discard iniConfigSource("/nonexistent/path/to/argumint_test.ini")
