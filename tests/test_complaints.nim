## Direct tests for failure reporting (`argumint/complaints.nim`) -- ADR 0035
## (parse-failure reporting), 0036 (rank by Reach), 0037 (missing-argument
## suppression), 0038 (name the short option that failed), and the
## Did-You-Mean rule. Until now this was verified only indirectly, through
## full-parse error-string assertions in test_parse_errors.nim/
## test_strict_options.nim/test_cli_syntax.nim; those pin the wording, these
## pin the rule. See issue #63.

import std/[strutils, unicode, unittest]

import argumint
import argumint/complaints
import argumint/tokens

suite "osaDistance":
  test "identical strings are distance 0":
    check osaDistance("abc".toRunes, "abc".toRunes) == 0

  test "an adjacent transposition costs 1, not 2":
    check osaDistance("ab".toRunes, "ba".toRunes) == 1

  test "a substitution costs 1":
    check osaDistance("ab".toRunes, "ac".toRunes) == 1

  test "an insertion or deletion costs 1":
    check osaDistance("ab".toRunes, "abc".toRunes) == 1
    check osaDistance("abc".toRunes, "ab".toRunes) == 1

  test "a multi-byte rune counts as one character, not one per byte":
    # "café" vs "cafe" differ by a single rune (é vs e) -- a byte-wise
    # distance would be larger, since é is two UTF-8 bytes.
    check osaDistance("café".toRunes, "cafe".toRunes) == 1

suite "didYouMean":
  test "the cap is keyed on the candidate's length, not the typed word's":
    # "abcdefg" (7, dash-stripped) has threshold min(2, max(1, 7 div 4)) == 1.
    # "abcdxfgh" (8) is distance 2 from it -- over that candidate's own
    # threshold, so no suggestion. Were the cap wrongly keyed on the *typed*
    # word's length instead (8 -> threshold 2), this would wrongly suggest.
    check didYouMean("abcdxfgh", @["abcdefg"]) == ""

  test "offered once inside the candidate's own threshold":
    check didYouMean("porta", @["port"]) == "; did you mean port?"

  test "declined once outside the candidate's own threshold":
    check didYouMean("portla", @["port"]) == ""

  test "an exact match is never offered":
    check didYouMean("cat", @["cat", "car"]) == "; did you mean car?"

  test "a candidate under MinSuggestable is never offered":
    # "h" is dash-stripped length 1 -- by the option PEGs' shapes this is
    # exactly "never suggest a short option" (ADR 0035).
    check didYouMean("-i", @["-h"]) == ""

  test "all best-distance ties are offered, sorted, never by declaration order":
    check didYouMean("cab", @["cat", "car"]) == "; did you mean car or cat?"

  test "nothing within range yields an empty string":
    check didYouMean("--zzzzz", @["--foo"]) == ""

suite "unknownOption":
  let spec = newSpec((verbose: flag("--verbose"),), usage = "[options]")

  test "a short-form token is narrowed to its first two characters":
    let token = RawToken(raw: "-xyz", optShape: true)
    check unknownOption(token, spec) ==
      (kind: "unrecognized option", subject: "-x (in -xyz)", names: true)

  test "the origin is omitted when it would only repeat the name":
    let token = RawToken(raw: "-x", optShape: true)
    check unknownOption(token, spec) ==
      (kind: "unrecognized option", subject: "-x", names: true)

  test "a cluster-peeled remainder's origin is the whole typed cluster":
    let token = RawToken(raw: "-yz", cluster: "-xyz", optShape: true)
    check unknownOption(token, spec) ==
      (kind: "unrecognized option", subject: "-y (in -xyz)", names: true)

  test "a long-form token draws a suggestion instead of an origin":
    let token = RawToken(raw: "--verbse", optShape: true)
    check unknownOption(token, spec) ==
      (kind: "unrecognized option", subject: "--verbse; did you mean --verbose?", names: true)

suite "formatComplaints":
  test "same-kind complaints group onto one ' | '-joined, parenthesized line":
    check formatComplaints(@[
      (kind: "missing option", subject: "-a", names: true),
      (kind: "missing option", subject: "-b", names: true),
    ]) == "  - missing option: (-a | -b)"

  test "a single subject for a kind isn't parenthesized":
    check formatComplaints(@[(kind: "missing option", subject: "-a", names: true)]) ==
      "  - missing option: -a"

  test "a kindless complaint renders as a bare bullet":
    check formatComplaints(@[(kind: "", subject: "bad value", names: false)]) ==
      "  - bad value"

  test "no leading newline":
    check not formatComplaints(@[(kind: "", subject: "x", names: false)]).startsWith("\n")

suite "finalComplaints: suppression":
  let spec = newSpec((
    go: command("go", (rest: args("<rest>"),)),
    stop: command("stop", (rest: args("<rest>"),)),
  ), usage = "(go|stop)")

  test "a Naming Complaint drops every missing option":
    let verbose = flag("--verbose")
    var r = initReport(spec, "app")
    r.missingOption("--foo")
    r.unexpected(verbose)
    check r.finalComplaints == @[(kind: "unexpected flag", subject: "--verbose", names: true)]

  test "an unrecognized command additionally drops missing command":
    var r = initReport(spec, "app")
    r.missingCommand("go")
    r.missingCommand("stop")
    r.leftover(initCursor(spec, @["nope"]))
    check r.finalComplaints == @[(kind: "unrecognized command", subject: "nope", names: true)]

  test "a Command-classified leftover reports 'unexpected command' regardless of wantedCommand":
    var r = initReport(spec, "app")
    r.missingOption("--foo") # no "missing command" recorded -- wantedCommand is false
    r.leftover(initCursor(spec, @["go"])) # "go" is itself a declared command
    # The naming complaint drops "missing option" (unconditional, ADR 0035's
    # rule 2) whether or not it's command-related.
    check r.finalComplaints == @[(kind: "unexpected command", subject: "go", names: true)]

  test "suppressed past `--`: missing command survives alongside the real wording":
    var r = initReport(spec, "app")
    r.missingCommand("go")
    var cur = initCursor(spec, @["nope"])
    cur.optsEnd = true
    r.leftover(cur)
    # Only a command-labeled naming complaint drops "missing command" (the
    # second filter in `finalComplaints`) -- an ordinary one doesn't, unlike
    # "missing option", which the first filter drops unconditionally.
    check r.finalComplaints == @[
      (kind: "missing command", subject: "go", names: false),
      (kind: "unexpected argument", subject: "nope", names: true),
    ]

  test "suppressed for an option-shaped token: missing command survives too":
    var r = initReport(spec, "app")
    r.missingCommand("go")
    r.leftover(initCursor(spec, @["--nope"]))
    check r.finalComplaints == @[
      (kind: "missing command", subject: "go", names: false),
      (kind: "unrecognized option", subject: "--nope", names: true),
    ]

suite "Report bookkeeping":
  let spec = newSpec((
    name: opt("--name=<s>", default = ""),
    verbose: flag("--verbose"),
  ), usage = "[options]")

  test "leftover is a no-op on an empty cursor":
    var r = initReport(spec, "")
    r.leftover(initCursor(spec, newSeq[string]()))
    check r.isEmpty

  test "leftover dedups by the first raw token":
    var r = initReport(spec, "")
    r.leftover(initCursor(spec, @["nope", "extra"]))
    r.leftover(initCursor(spec, @["nope"])) # same leading token -- dropped
    check r.finalComplaints.len == 1

  test "distinct leftovers both survive":
    var r = initReport(spec, "")
    r.leftover(initCursor(spec, @["nope"]))
    r.leftover(initCursor(spec, @["other"]))
    check r.finalComplaints.len == 2

  test "starved returns false on a non-option leading token":
    var r = initReport(spec, "")
    check not r.starved(initCursor(spec, @["plain"]))
    check r.isEmpty

  test "starved returns false on an empty cursor":
    var r = initReport(spec, "")
    check not r.starved(initCursor(spec, newSeq[string]()))

  test "starved names the starver only when it's genuinely unknown":
    var r = initReport(spec, "")
    check r.starved(initCursor(spec, @["--name", "--nope"]))
    check r.finalComplaints == @[
      (kind: "missing value", subject: "option --name requires a value", names: true),
      (kind: "unrecognized option", subject: "--nope", names: true),
    ]

  test "starved stays silent about a starver that's itself a declared option":
    var r = initReport(spec, "")
    check r.starved(initCursor(spec, @["--name", "--verbose"]))
    check r.finalComplaints ==
      @[(kind: "missing value", subject: "option --name requires a value", names: true)]

  test "mark/rollback discards everything recorded since the mark":
    var r = initReport(spec, "")
    r.missingOption("--foo")
    let m = r.mark()
    r.missingOption("--bar")
    r.leftover(initCursor(spec, @["extra"]))
    r.rollback(m)
    check r.finalComplaints == @[(kind: "missing option", subject: "--foo", names: false)]

  test "merge dedups exact-duplicate messages but keeps new ones":
    var a = initReport(spec, "")
    a.missingOption("--foo")
    var b = initReport(spec, "")
    b.missingOption("--foo")
    b.missingOption("--bar")
    a.merge(b)
    check a.finalComplaints.len == 2

  test "merge dedups leftovers by first raw token too":
    var a = initReport(spec, "")
    a.leftover(initCursor(spec, @["nope"]))
    var b = initReport(spec, "")
    b.leftover(initCursor(spec, @["nope", "extra"]))
    a.merge(b)
    check a.finalComplaints.len == 1

  test "clear empties messages/leftovers but leaves spec/command intact":
    var r = initReport(spec, "app")
    r.missingOption("--foo")
    r.leftover(initCursor(spec, @["extra"]))
    r.clear()
    check r.isEmpty
    r.note("boom")
    check "app" in r.failureMessage
