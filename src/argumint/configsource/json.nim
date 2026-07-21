## A JSON-file `ConfigSource` backed by `std/json`. A `JArray` value's
## elements become the result's `seq[string]` natively -- no central
## delimiter-splitting the way env has, since a JSON array already knows
## its own element boundaries. See `docs/adr/0018-config-source.md`.

import std/[json, options]
import ../configsource

type
  JsonConfigSource = ref object of ConfigSource
    root: JsonNode

proc jsonConfigSource*(path: string): ConfigSource =
  ## Reads and parses the JSON file at `path` eagerly, right here at this
  ## call -- `std/json.parseFile` raises an ordinary `IOError` (missing
  ## file) or `JsonParsingError` (malformed JSON) in the caller's own code,
  ## deliberately outside argumint's `SpecDefect`/`ParseError` taxonomy,
  ## since this happens before any Spec construction or parsing has even
  ## begun.
  JsonConfigSource(root: parseFile(path))

proc stringify(node: JsonNode): Option[string] =
  ## Stringifies a scalar JSON value for `parseImpl` -- deliberately via
  ## `getStr`/`getInt`/`getFloat`/`getBool` per kind, not `$node`, which
  ## would re-serialize a `JString` with stray quotes (`"foo"` instead of
  ## `foo`). `none` for anything that isn't a scalar (`JObject`/`JArray`/
  ## `JNull`).
  case node.kind
  of JString: some(node.getStr)
  of JInt: some($node.getInt)
  of JFloat: some($node.getFloat)
  of JBool: some($node.getBool)
  else: none(string)

method lookup(self: JsonConfigSource, key: ConfigKey): Option[seq[string]] =
  ## Walks `key` one segment per nested-object level. A missing or
  ## non-object segment along the way returns `none`, not a crash. At the
  ## terminal node: a `JArray`'s elements become the seq directly (`none`
  ## if any element isn't itself a scalar -- there's no sensible string for
  ## a nested object/array element); a scalar becomes a 1-element seq;
  ## anything else (`JObject`/`JNull`) is `none`.
  var node = self.root
  for segment in key:
    if node.isNil or node.kind != JObject or not node.hasKey(segment):
      return none(seq[string])
    node = node[segment]

  case node.kind
  of JArray:
    var values: seq[string]
    for elem in node.elems:
      let s = stringify(elem)
      if s.isNone:
        return none(seq[string])
      values.add s.get
    some(values)
  else:
    let s = stringify(node)
    if s.isSome: some(@[s.get]) else: none(seq[string])

when isMainModule:
  import std/unittest
  import std/os as osmod

  proc withTempJson(content: string, body: proc (path: string)) =
    let path = osmod.getTempDir() / "argumint_test_" & $osmod.getCurrentProcessId() & ".json"
    writeFile(path, content)
    try: body(path)
    finally: osmod.removeFile(path)

  suite "jsonConfigSource":
    test "a JArray's elements become a multi-element seq":
      withTempJson("""{"tags": ["a", "b", "c"]}""") do (path: string):
        let source = jsonConfigSource(path)
        check source.lookup(configKey("tags")).get == @["a", "b", "c"]

    test "a scalar becomes a 1-element seq":
      withTempJson("""{"name": "nasher"}""") do (path: string):
        let source = jsonConfigSource(path)
        check source.lookup(configKey("name")).get == @["nasher"]

    test "a JString stringifies without stray quotes":
      withTempJson("""{"name": "nasher"}""") do (path: string):
        let source = jsonConfigSource(path)
        check source.lookup(configKey("name")).get[0] == "nasher"
        check source.lookup(configKey("name")).get[0] != "\"nasher\""

    test "int/float/bool scalars stringify via their own getters":
      withTempJson("""{"port": 8080, "ratio": 1.5, "debug": true}""") do (path: string):
        let source = jsonConfigSource(path)
        check source.lookup(configKey("port")).get == @["8080"]
        check source.lookup(configKey("ratio")).get == @["1.5"]
        check source.lookup(configKey("debug")).get == @["true"]

    test "a nested multi-segment path walks each level":
      withTempJson("""{"package": {"name": "nasher"}}""") do (path: string):
        let source = jsonConfigSource(path)
        check source.lookup(configKey("package", "name")).get == @["nasher"]

    test "a missing path segment returns none, not a crash":
      withTempJson("""{"package": {"name": "nasher"}}""") do (path: string):
        let source = jsonConfigSource(path)
        check source.lookup(configKey("missing")).isNone
        check source.lookup(configKey("package", "missing")).isNone

    test "a wrong-shaped path segment (indexing into a scalar) returns none":
      withTempJson("""{"name": "nasher"}""") do (path: string):
        let source = jsonConfigSource(path)
        check source.lookup(configKey("name", "nested")).isNone

    test "an object or null at the terminal position returns none":
      withTempJson("""{"package": {"name": "nasher"}, "extra": null}""") do (path: string):
        let source = jsonConfigSource(path)
        check source.lookup(configKey("package")).isNone
        check source.lookup(configKey("extra")).isNone

    test "malformed JSON raises":
      withTempJson("""{"unterminated": """) do (path: string):
        expect JsonParsingError:
          discard jsonConfigSource(path)

    test "a missing file raises":
      expect IOError:
        discard jsonConfigSource("/nonexistent/path/to/argumint_test.json")
