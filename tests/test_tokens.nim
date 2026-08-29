## Direct tests for the token layer (`argumint/tokens.nim`) -- ADR 0019
## (lazy token classification) and ADR 0034 (Strict Option Checking). Until
## now this was verified only indirectly, through full-parse error-string
## assertions in test_parse_errors.nim/test_strict_options.nim/
## test_cli_syntax.nim; those pin the wording, these pin the rule. See
## issue #61.

import std/unittest

import argumint
import argumint/tokens

proc restSpec(): auto =
  (rest: args("<rest>"),)

proc nameSpec(): auto =
  (name: opt("--name=<s>", default = ""),)

suite "isOptShape":
  test "recognizes bare short and long options":
    check "-o".isOptShape
    check "--opt".isOptShape

  test "recognizes attached-value forms":
    check "-o=val".isOptShape
    check "--opt=value".isOptShape
    check "-o:val".isOptShape

  test "recognizes a cluster candidate":
    check "-abc".isOptShape

  test "a literal -- is not option-shaped":
    check not "--".isOptShape

  test "a bare - is not option-shaped":
    check not "-".isOptShape

  test "`--5` isn't option-shaped -- two dashes need two trailing characters":
    # `longOption <- '--' \w (\w / ('-' \w))+`. Pinned because it looks like
    # a hole rather than an intentional exemption -- see ADR 0034.
    check not "--5".isOptShape

suite "isNonOptionShort":
  test "every documented Non-Option Short qualifies":
    for tok in ["-5", "-.5", "-1e9", "-0x1F", "-+3", "-5x", "-1_000"]:
      check tok.isNonOptionShort

  test "a normal short option never qualifies":
    check not "-a".isNonOptionShort
    check not "-abc".isNonOptionShort

  test "two leading dashes never qualify":
    check not "--5".isNonOptionShort
    check not "--1_000".isNonOptionShort

suite "exemptFromStrict":
  test "a Non-Option Short typed directly is exempt":
    check RawToken(raw: "-.5").exemptFromStrict

  test "the same text as a cluster remainder is not exempt":
    # With `-1` declared as a Flag, `-1.5` peels to a `-.5` remainder --
    # a cluster continuation, refused exactly as `-1x`'s `-x` is, not the
    # Non-Option Short exemption. See ADR 0034's "a cluster remainder is
    # not a Non-Option Short" deviation. The suite below drives the real
    # peel end to end rather than constructing this shape by hand.
    check not RawToken(raw: "-.5", cluster: "-1.5").exemptFromStrict

  test "a normal short option is never exempt, cluster or not":
    check not RawToken(raw: "-x").exemptFromStrict
    check not RawToken(raw: "-x", cluster: "-1x").exemptFromStrict

suite "the issue's own example: `-1.5` against a declared `-1` Flag":
  test "peels to a `-.5` remainder that is refused, not exempt":
    # Issue #61's "one correction to the artifact" names this exact
    # scenario -- drives classify/consume for real, rather than
    # constructing the peeled RawToken by hand as the suite above does.
    let spec = newSpec((one: flag("-1"),), usage = "[options]")
    var cur = initCursor(spec, @["-1.5"])
    let c = cur.classify(0)
    check c.kind == ArgKind.Flag
    check c.flagName == "-1"
    check c.remainder == "-.5"
    cur.consume(0, c)
    check cur.len == 1
    check cur[0].raw == "-.5"
    check cur[0].cluster == "-1.5"
    check not cur[0].exemptFromStrict

suite "classify: cluster peel":
  test "a Flag cluster peels one letter, leaving the remainder as a RawToken":
    let spec = newSpec((v: flag("-v"), a: flag("-a")), usage = "[options]")
    let cur = initCursor(spec, @["-va"])
    let c = cur.classify(0)
    check c.kind == ArgKind.Flag
    check c.flagName == "-v"
    check c.remainder == "-a"

  test "an Optional in a cluster swallows the rest as its attached value":
    let spec = newSpec((p: opt("-p=<n>", default = "")), usage = "[options]")
    let cur = initCursor(spec, @["-p80"])
    let c = cur.classify(0)
    check c.kind == ArgKind.Optional
    check c.optVal == "80"
    check c.consumed == 1

  test "a declared spelling resolves before an undeclared letter would starve the scan":
    let spec = newSpec((n: opt("-n=<s>", default = "")), usage = "[options]")
    let cur = initCursor(spec, @["-nan"])
    let c = cur.classify(0)
    check c.kind == ArgKind.Optional
    check c.optName == "-n"
    check c.optVal == "an"

suite "classify: attached values via `-o=val`":
  test "a short option's attached value":
    let spec = newSpec((p: opt("-p=<n>", default = "")), usage = "[options]")
    let cur = initCursor(spec, @["-p=80"])
    let c = cur.classify(0)
    check c.kind == ArgKind.Optional
    check c.optName == "-p"
    check c.optSep == "="
    check c.optVal == "80"
    check c.consumed == 1

  test "a long option's attached value":
    let spec = newSpec((port: opt("--port=<n>", default = "")), usage = "[options]")
    let cur = initCursor(spec, @["--port=80"])
    let c = cur.classify(0)
    check c.kind == ArgKind.Optional
    check c.optName == "--port"
    check c.optVal == "80"

suite "classify: starvation":
  let spec = newSpec(nameSpec(), usage = "[options]")

  test "a declared Optional with nothing after it starves":
    let cur = initCursor(spec, @["--name"])
    let c = cur.classify(0)
    check c.kind == ArgKind.Positional
    check not c.starvedOpt.isNil
    check c.starvedName == "--name"

  test "a declared Optional followed by another option-shaped token starves":
    let cur = initCursor(spec, @["--name", "--nope"])
    let c = cur.classify(0)
    check c.kind == ArgKind.Positional
    check not c.starvedOpt.isNil
    check c.starvedName == "--name"

suite "classify: end-of-options short-circuit":
  test "past optsEnd every token classifies as plain Positional text":
    let spec = newSpec(restSpec(), usage = "<rest>...")
    var cur = initCursor(spec, @["--nope"])
    cur.optsEnd = true
    let c = cur.classify(0)
    check c.kind == ArgKind.Positional
    check c.argVal == "--nope"
    check c.starvedOpt.isNil

suite "classify: command and positional":
  test "a declared command name classifies as Command":
    let spec = newSpec((go: command("go", restSpec())), usage = "go")
    let cur = initCursor(spec, @["go"])
    let c = cur.classify(0)
    check c.kind == ArgKind.Command
    check c.cmdName == "go"

  test "plain text falls through to Positional":
    let spec = newSpec((n: arg("<n>")), usage = "<n>")
    let cur = initCursor(spec, @["hello"])
    let c = cur.classify(0)
    check c.kind == ArgKind.Positional
    check c.argVal == "hello"

  test "never raises, whatever shape the token is":
    let spec = newSpec(restSpec(), usage = "<rest>...")
    for tok in ["-", "--", "-=", "--=", "-o=", "=", "-1.5.6", "-o=val=extra", ""]:
      let cur = initCursor(spec, @[tok])
      discard cur.classify(0)

suite "consume":
  test "a peeled remainder inherits idx and increments subIdx":
    # ADR 0038: idx must name the whole physical CLI argument for Flag
    # Operation composition order, so a peel can't reset it -- constructed
    # directly, rather than via a fresh initCursor, so the parent's idx
    # (7) is clearly distinct from its position (0).
    let spec = newSpec((v: flag("-v"), a: flag("-a")), usage = "[options]")
    var cur = TokenCursor(spec: spec,
      tokens: @[RawToken(raw: "-va", optShape: true, idx: 7, subIdx: 2)])
    let c = cur.classify(0)
    check c.remainder == "-a"
    cur.consume(0, c)
    check cur.len == 1
    check cur[0].raw == "-a"
    check cur[0].idx == 7
    check cur[0].subIdx == 3
    check cur[0].cluster == "-va"

  test "a detached value consumes both its own token and the next":
    let spec = newSpec((port: opt("--port=<n>", default = "")), usage = "[options]")
    var cur = initCursor(spec, @["--port", "80", "extra"])
    let c = cur.classify(0)
    check c.consumed == 2
    cur.consume(0, c)
    check cur.len == 1
    check cur[0].raw == "extra"

suite "consumeOptsEnd":
  test "drops a literal -- once, sets optsEnd, and returns false after":
    let spec = newSpec(restSpec(), usage = "<rest>...")
    var cur = initCursor(spec, @["--", "--nope"])
    check cur.consumeOptsEnd(0)
    check cur.optsEnd
    check cur.len == 1
    check cur[0].raw == "--nope"
    check not cur.consumeOptsEnd(0)
    check cur.len == 1

  test "does nothing to a token that isn't a literal --":
    let spec = newSpec(restSpec(), usage = "<rest>...")
    var cur = initCursor(spec, @["--nope"])
    check not cur.consumeOptsEnd(0)
    check not cur.optsEnd
    check cur.len == 1

suite "value-slot Strict Option Checking (refusesAsValue, via classify)":
  test "strictOptions on: an option-shaped following token starves rather than being eaten":
    let spec = newSpec(nameSpec(), usage = "[options]")
    let cur = initCursor(spec, @["--name", "--nope"])
    let c = cur.classify(0)
    check c.kind == ArgKind.Positional
    check not c.starvedOpt.isNil

  test "strictOptions off: the same following token is eaten as the value":
    let settings = newSpecSettings(strictOptions = false)
    let spec = newSpec(nameSpec(), usage = "[options]", settings = settings)
    let cur = initCursor(spec, @["--name", "--nope"])
    let c = cur.classify(0)
    check c.kind == ArgKind.Optional
    check c.optVal == "--nope"
    check c.consumed == 2

suite "refusesAsPositional":
  test "strictOptions on: refuses an unresolved option-shaped token":
    let spec = newSpec(restSpec(), usage = "<rest>...")
    let cur = initCursor(spec, @["--nope"])
    let c = cur.classify(0)
    check cur.refusesAsPositional(0, c)

  test "strictOptions off: accepts it as literal positional text":
    let settings = newSpecSettings(strictOptions = false)
    let spec = newSpec(restSpec(), usage = "<rest>...", settings = settings)
    let cur = initCursor(spec, @["--nope"])
    let c = cur.classify(0)
    check not cur.refusesAsPositional(0, c)

  test "a starved declared Optional is refused whatever strictOptions says":
    let settings = newSpecSettings(strictOptions = false)
    let spec = newSpec(nameSpec(), usage = "[options]", settings = settings)
    let cur = initCursor(spec, @["--name"])
    let c = cur.classify(0)
    check not c.starvedOpt.isNil
    check cur.refusesAsPositional(0, c)

  test "a post-`--` token is exempt even with strictOptions on":
    let spec = newSpec(restSpec(), usage = "<rest>...")
    var cur = initCursor(spec, @["--", "--nope"])
    discard cur.consumeOptsEnd(0)
    let c = cur.classify(0)
    check c.kind == ArgKind.Positional
    check not cur.refusesAsPositional(0, c)
