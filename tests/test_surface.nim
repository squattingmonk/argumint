# `tools/surface.nim`, which writes `tests/api/surface.txt` (ADR 0090), fed
# small pieces of `nim doc` output in place of a real `htmldocs/`.

import std/[tables, unittest]

import ../tools/surface

proc pages(files: openArray[(string, string)]): proc (path: string): string =
  ## The HTML pages a test's `htmldocs/` holds, by path from its root.
  let files = files.toTable
  result = proc (path: string): string = files.getOrDefault(path)

const noExports = "<h1><a class=\"toc-backref\" href=\"#19\">Exports</a></h1>\n<dl class=\"item\">\n</dl>"

suite "a public module's surface":
  test "its own symbols come from its .idx, under its own name":
    let idx = "nimTitle\targumint/help\targumint/help.html\tmodule src/argumint/help\t\t0\n" &
      "nim\tformatColumn\targumint/help.html#formatColumn,HelpContext\tproc formatColumn(ctx: HelpContext): string\t\t40\n" &
      "nim\twrap\targumint/help.html#wrap.t,string,int\ttemplate wrap(s: string; width: int): string\t\t50\n"
    check surface("argumint/help", idx, "", pages({"argumint/help.html": noExports})) == @[
      "argumint/help.formatColumn,HelpContext",
      "argumint/help.wrap.t,string,int",
    ]

  test "what it re-exports comes from its page's Exports section":
    # docgen numbers a second entry for the same anchor `_2`; here that's
    # one symbol reached twice.
    let help = "<h1><a class=\"toc-backref\" href=\"#19\">Exports</a></h1>\n" &
      "<dl class=\"item\">\n" &
      "<a href=\"core/backend.html#prolog,Spec\"><span class=\"Identifier\">prolog</span></a>, " &
      "<a href=\"core/errors.html#ValidationError\"><span class=\"Identifier\">ValidationError</span></a>, " &
      "<a href=\"core/errors.html#ValidationError_2\"><span class=\"Identifier\">ValidationError</span></a>\n" &
      "</dl>\n<a href=\"elsewhere.html#notExported\">after</a>"
    check surface("argumint/help", "", "", pages({"argumint/help.html": help})) == @[
      "argumint/help.ValidationError",
      "argumint/help.prolog,Spec",
    ]

  test "what it re-exports from std/ comes from its source":
    # docgen leaves these out of the Exports section; argumint's own
    # modules are there already.
    let source = """
import std/[macros, options, terminal]
import ./argumint/core/backend

export options.some, options.none # and a comment
export options.isSome,
  options.get
export backend.HookInfo
export terminal.`ForegroundColor`
"""
    check surface("argumint", "", source, pages({"argumint.html": noExports})) == @[
      "argumint.ForegroundColor",
      "argumint.get",
      "argumint.isSome",
      "argumint.none",
      "argumint.some",
    ]

  test "an enum's members are listed under it":
    # The .idx lists a non-pure enum's members on their own, but not a pure
    # one's; the type's definition on its page lists both.
    let idx = "nim\tSeenBy\targumint.html#SeenBy\tenum SeenBy\t\t39\n" &
      "nim\tbyNone\targumint.html#byNone\tSeenBy.byNone\t\t39\n" &
      "nim\tbyCli\targumint.html#byCli\tSeenBy.byCli\t\t39\n"
    let facade = "<div id=\"SeenBy\">\n" &
      "  <dt><pre><a href=\"#SeenBy\"><span class=\"Identifier\">SeenBy</span></a> <span class=\"Other\">=</span> <span class=\"Keyword\">enum</span>\n" &
      "  <span class=\"Identifier\">byNone</span><span class=\"Other\">,</span> <span class=\"Identifier\">byCli</span></pre></dt>\n" &
      "</div>\n" &
      "<h1><a class=\"toc-backref\" href=\"#19\">Exports</a></h1>\n<dl class=\"item\">\n" &
      "<a href=\"argumint/core/backend.html#ArgKind\"><span class=\"Identifier\">ArgKind</span></a>\n</dl>"
    let backend = "<div id=\"ArgKind\">\n" &
      "  <dt><pre><a href=\"#ArgKind\"><span class=\"Identifier\">ArgKind</span></a> {.<span class=\"Identifier\">pure</span>.} <span class=\"Other\">=</span> <span class=\"Keyword\">enum</span>\n" &
      "  <span class=\"Identifier\">Command</span><span class=\"Other\">,</span>                  <span class=\"Comment\">## A subcommand (e.g., `clone`)</span>\n" &
      "  <span class=\"Identifier\">Optional</span><span class=\"Other\">,</span> <span class=\"Comment\">## An optional argument, e.g. `-o value` or</span>\n" &
      "             <span class=\"Comment\">## `--option value`</span>\n" &
      "  <span class=\"Identifier\">Flag</span> <span class=\"Other\">=</span> <span class=\"StringLit\">&quot;flag&quot;</span></pre></dt>\n" &
      "</div>\n"
    check surface("argumint", idx, "", pages({"argumint.html": facade,
        "argumint/core/backend.html": backend})) == @[
      "argumint.ArgKind",
      "argumint.ArgKind.Command",
      "argumint.ArgKind.Flag",
      "argumint.ArgKind.Optional",
      "argumint.SeenBy",
      "argumint.SeenBy.byCli",
      "argumint.SeenBy.byNone",
    ]

  test "an object's or tuple's public fields are listed under it, and so are their types'":
    # docgen shows only public fields. `Level` isn't exported, but a hook
    # reaches its fields through `HookInfo.root`; `Kind`'s values it can't
    # name without the type.
    let facade = "<h1><a class=\"toc-backref\" href=\"#19\">Exports</a></h1>\n<dl class=\"item\">\n" &
      "<a href=\"argumint/core/backend.html#HookInfo\"><span class=\"Identifier\">HookInfo</span></a>, " &
      "<a href=\"argumint/core/backend.html#HelpText\"><span class=\"Identifier\">HelpText</span></a>, " &
      "<a href=\"argumint/core/backend.html#appName\"><span class=\"Identifier\">appName</span></a>\n</dl>"
    let backend = "<div id=\"HookInfo\">\n" &
      "  <dt><pre><a href=\"#HookInfo\"><span class=\"Identifier\">HookInfo</span></a> <span class=\"Other\">=</span> <span class=\"Keyword\">object</span>\n" &
      "  <span class=\"Identifier\">matched</span><span class=\"Operator\">*</span><span class=\"Other\">:</span> <span class=\"Identifier\">seq</span><span class=\"Other\">[</span><a href=\"#Arg\"><span class=\"Identifier\">Arg</span></a><span class=\"Other\">]</span> <span class=\"Comment\">## Every Arg matched*: not a field</span>\n" &
      "  <span class=\"Identifier\">root</span><span class=\"Operator\">*</span><span class=\"Other\">:</span> <a href=\"#Level\"><span class=\"Identifier\">Level</span></a>\n" &
      "  <span class=\"Keyword\">case</span> <span class=\"Identifier\">kind</span><span class=\"Operator\">*</span><span class=\"Other\">:</span> <a href=\"#Kind\"><span class=\"Identifier\">Kind</span></a>\n" &
      "  <span class=\"Keyword\">of</span> <span class=\"Identifier\">true</span><span class=\"Other\">:</span>\n" &
      "    <span class=\"Identifier\">color</span><span class=\"Operator\">*</span><span class=\"Other\">:</span> <a href=\"https://nim-lang.org/docs/terminal.html#ForegroundColor\"><span class=\"Identifier\">ForegroundColor</span></a></pre></dt>\n" &
      "</div>\n" &
      "<div id=\"Arg\">\n" &
      "  <dt><pre><a href=\"#Arg\"><span class=\"Identifier\">Arg</span></a> <span class=\"Other\">=</span> <span class=\"Keyword\">ref</span> <span class=\"Keyword\">object</span> <span class=\"Keyword\">of</span> <span class=\"Identifier\">RootObj</span></pre></dt>\n" &
      "</div>\n" &
      "<div id=\"Kind\">\n" &
      "  <dt><pre><a href=\"#Kind\"><span class=\"Identifier\">Kind</span></a> <span class=\"Other\">=</span> <span class=\"Keyword\">enum</span>\n" &
      "  <span class=\"Identifier\">kA</span><span class=\"Other\">,</span> <span class=\"Identifier\">kB</span></pre></dt>\n" &
      "</div>\n" &
      "<div id=\"Level\">\n" &
      "  <dt><pre><a href=\"#Level\"><span class=\"Identifier\">Level</span></a> <span class=\"Other\">=</span> <span class=\"Keyword\">tuple</span><span class=\"Other\">[</span><span class=\"Identifier\">spec</span><span class=\"Other\">:</span> <span class=\"Identifier\">seq</span><span class=\"Other\">[</span><span class=\"Identifier\">int</span><span class=\"Other\">,</span> <span class=\"Identifier\">int</span><span class=\"Other\">]</span><span class=\"Other\">,</span> <span class=\"Identifier\">command</span><span class=\"Other\">:</span> <span class=\"Identifier\">string</span><span class=\"Other\">]</span></pre></dt>\n" &
      "</div>\n" &
      "<div id=\"HelpText\">\n" &
      "  <dt><pre><a href=\"#HelpText\"><span class=\"Identifier\">HelpText</span></a> <span class=\"Other\">=</span> <span class=\"Keyword\">tuple</span><span class=\"Other\">[</span><span class=\"Identifier\">short</span><span class=\"Other\">,</span> <span class=\"Identifier\">long</span><span class=\"Other\">:</span> <span class=\"Identifier\">string</span><span class=\"Other\">]</span></pre></dt>\n" &
      "</div>\n" &
      "<div id=\"appName\">\n" &
      "  <dt><pre><span class=\"Keyword\">proc</span> <a href=\"#appName\"><span class=\"Identifier\">appName</span></a><span class=\"Other\">(</span><span class=\"Identifier\">x</span> <span class=\"Other\">=</span> <span class=\"Identifier\">enumThing</span><span class=\"Other\">)</span></pre></dt>\n" &
      "</div>\n"
    check surface("argumint", "", "", pages({"argumint.html": facade,
        "argumint/core/backend.html": backend})) == @[
      "argumint.HelpText",
      "argumint.HelpText.long",
      "argumint.HelpText.short",
      "argumint.HookInfo",
      "argumint.HookInfo.color",
      "argumint.HookInfo.kind",
      "argumint.HookInfo.matched",
      "argumint.HookInfo.root",
      "argumint.Level.command",
      "argumint.Level.spec",
      "argumint.appName",
    ]

  test "an exported enum keeps its values when a field reaches it first":
    let facade = "<h1><a class=\"toc-backref\" href=\"#19\">Exports</a></h1>\n<dl class=\"item\">\n" &
      "<a href=\"#Holder\"><span class=\"Identifier\">Holder</span></a>, " &
      "<a href=\"#Kind\"><span class=\"Identifier\">Kind</span></a>\n</dl>\n" &
      "<div id=\"Holder\">\n" &
      "  <dt><pre><a href=\"#Holder\"><span class=\"Identifier\">Holder</span></a> <span class=\"Other\">=</span> <span class=\"Keyword\">object</span>\n" &
      "  <span class=\"Identifier\">kind</span><span class=\"Operator\">*</span><span class=\"Other\">:</span> <a href=\"#Kind\"><span class=\"Identifier\">Kind</span></a></pre></dt>\n" &
      "</div>\n" &
      "<div id=\"Kind\">\n" &
      "  <dt><pre><a href=\"#Kind\"><span class=\"Identifier\">Kind</span></a> <span class=\"Other\">=</span> <span class=\"Keyword\">enum</span>\n" &
      "  <span class=\"Identifier\">kA</span></pre></dt>\n" &
      "</div>\n"
    check surface("argumint", "", "", pages({"argumint.html": facade})) == @[
      "argumint.Holder",
      "argumint.Holder.kind",
      "argumint.Kind",
      "argumint.Kind.kA",
    ]

suite "the snapshot":
  test "a rewrite keeps the `!` on lines already marked, and marks no new one":
    let old = "# A header the rewrite replaces.\n" &
      "!argumint.items.i,ConfigKey\nargumint.Spec\nargumint.removed\n"
    check snapshot(@["argumint.Spec", "argumint.added", "argumint.items.i,ConfigKey"], old) ==
      "# The Public Surface (ADR 0090), written by `nimble surface`. A line\n" &
      "# without a leading `!` is supported, so a Pin in tests/api/ must back it.\n" &
      "argumint.Spec\nargumint.added\n!argumint.items.i,ConfigKey\n"

suite "the pin check":
  const snap = "# header\nargumint.Spec\nargumint.Spec.settings\n!argumint.items.i,ConfigKey\n" &
    "argumint/help.HelpContext\n"

  test "every supported line backed, every tag a line: no failures":
    let a = """
import std/unittest
{.push warning[UnusedImport]: off.}
import std/[dirs,
  files]
{.pop.}
import argumint except foo

test "x":
  # pins: argumint.Spec
  # pins: argumint.Spec.settings
  discard
"""
    let b = "import argumint/[help]\n# pins: argumint/help.HelpContext\n"
    let c = "import argumint, argumint/help # no tags, so two modules are fine\n"
    check pinFailures(snap, {"tests/api/a.nim": a, "tests/api/b.nim": b,
      "tests/api/c.nim": c}) == newSeq[string]()

  test "each way a Pin can go wrong is named":
    let a = "import argumint\n# pins: argumint.Spec\n# pins: argumint.nope\n" &
      "# pins: argumint.items.i,ConfigKey\n# pins: argumint/help.HelpContext\n"
    let b = "import argumint, argumint/help\n# pins: argumint.Spec\n"
    let c = "from argumint/core/backend import Arg\nimport argumint\n"
    let d = "import \"../../src/argumint/grammar/lexer\"\ninclude argumint/core/errors\n"
    check pinFailures(snap, {"tests/api/a.nim": a, "tests/api/b.nim": b,
      "tests/api/c.nim": c, "tests/api/d.nim": d}) == @[
      "tests/api/a.nim: `# pins: argumint.nope` matches no line",
      "tests/api/a.nim: `# pins: argumint.items.i,ConfigKey` pins a `!` line, which is unsupported",
      "tests/api/a.nim: `# pins: argumint/help.HelpContext` names a line of argumint/help, not argumint",
      "tests/api/b.nim: a Pin imports one public module, not argumint, argumint/help",
      "tests/api/c.nim: imports argumint/core/backend, which isn't public",
      "tests/api/d.nim: imports argumint/grammar/lexer, which isn't public",
      "tests/api/d.nim: imports argumint/core/errors, which isn't public",
      "argumint.Spec.settings has no Pin",
      "argumint/help.HelpContext has no Pin",
    ]
