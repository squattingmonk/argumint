## Writes `tests/api/surface.txt`, the Public Surface (ADR 0090), for
## `nimble surface`, then checks every supported line has a Pin. Run it
## from the project root after `nimble docs`.
##
## Each line is `<public module>.<doc anchor>`; the anchor names an
## overload's parameter types, though not its return type. Three sources,
## since none is complete alone: a module's `.idx` (its own symbols), its
## page's Exports section (what it re-exports, after `except` lists), and
## its source's `std/` exports, which docgen leaves out of Exports. An
## enum's values and a type's public fields come from its definition on its
## page, as `Type.member`.
##
## It has two gaps, which `tests/api/README.md` describes: `std/` types'
## members, and a generic first parameter left out of an anchor.

import std/[algorithm, os, sequtils, sets, strutils]

type Symbol = tuple
  page: string
    ## The HTML page that documents it, by path from `htmldocs/`
  anchor: string
    ## Its anchor there, which names an overload's parameter types

proc resolve(page, href: string): Symbol =
  ## The symbol `href` links to from `page`.
  let parts = href.split('#', 1)
  let target = if parts[0].len == 0: page
               else: normalizedPath(page.parentDir / parts[0]).replace('\\', '/')
  (target, parts[1])

proc stripDup(anchor: string): string =
  ## `ValidationError_2` -> `ValidationError`: docgen's suffix for a second
  ## entry with the same anchor, which here is the same symbol reached twice.
  let name = anchor.split(',')[0]
  let i = name.rfind('_')
  if i > 0 and name[i+1 .. ^1].allCharsInSet(Digits):
    name[0 ..< i] & anchor[name.len .. ^1]
  else: anchor

proc fromIdx(idx: string, symbols: var seq[Symbol]) =
  for line in idx.splitLines:
    let cols = line.split('\t')
    if cols.len < 4 or cols[0] != "nim": continue
    if ' ' notin cols[3]: continue # `SeenBy.byCli`: see `members`
    symbols.add resolve("", cols[2])

iterator hrefs(html: string, start = 0, stop = html.high): string =
  ## The targets of the links in `html[start .. stop]`.
  var i = start
  while true:
    i = html.find("<a href=\"", i)
    if i < 0 or i > stop: break
    i += "<a href=\"".len
    yield html[i ..< html.find('"', i)]

proc fromExports(page, html: string, symbols: var seq[Symbol]) =
  ## The links in `html`'s Exports section, the only place docgen lists
  ## what a module re-exports after its `except` lists.
  let start = html.rfind(">Exports</a></h1>")
  if start < 0: return
  for href in html.hrefs(start, html.find("</dl>", start)):
    symbols.add resolve(page, href)

proc statements(source: string, keywords: openArray[string]): seq[string] =
  ## `source`'s top-level statements that open with one of `keywords`, such
  ## as `"export "`, each joined with its indented continuation lines, with
  ## comments and the keyword dropped.
  var open = false
  for raw in source.splitLines:
    let line = raw.split('#')[0]
    open = open and line.startsWith("  ")
    if open:
      result[^1].add line
    for keyword in keywords:
      if line.startsWith(keyword):
        result.add line[keyword.len .. ^1]
        open = true

proc fromStdExports(source: string): seq[string] =
  ## The names `source` re-exports from `std/` modules, such as
  ## `export options.some, options.none`.
  var stdMods: HashSet[string]
  for s in statements(source, ["import std/"]):
    for m in s.strip(chars = {'[', ']', ' '}).split(','):
      stdMods.incl m.strip
  for s in statements(source, ["export "]):
    for item in s.split(','):
      let parts = item.strip.split('.', 1)
      if parts.len == 2 and parts[0] in stdMods:
        result.add parts[1].strip(chars = {'`', ' '})

proc definition(html, anchor: string): string =
  ## The highlighted definition `html` shows for `anchor`, or "" if none.
  let start = html.find("<div id=\"" & anchor & "\">")
  if start < 0: return
  let open = html.find("<pre>", start)
  result = html[open + "<pre>".len ..< html.find("</pre>", open)]

proc plainText(code: string): string =
  ## Highlighted `code` as plain source, its doc comments dropped.
  var i = 0
  while i < code.len:
    if code.continuesWith("<span class=\"Comment\">", i):
      i = code.find("</span>", i) + "</span>".len
    elif code[i] == '<':
      i = code.find('>', i) + 1
    else:
      result.add code[i]
      inc i
  result = result.multiReplace(("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"),
    ("&#39;", "'"), ("&amp;", "&"))

proc leadingIdent(s: string): string =
  for c in s.strip:
    if c notin IdentChars: break
    result.add c

proc links(page, code: string): seq[Symbol] =
  ## The argumint symbols `code` on `page` links to; a link into the Nim
  ## manual or stdlib docs is absolute.
  for href in code.hrefs:
    if not href.startsWith("http"):
      result.add resolve(page, href)

proc tupleFields(fields: string): seq[string] =
  ## The names in `fields`, a tuple's `a, b: T; c: U`.
  var depth = 0
  var part = ""
  for c in fields & ",":
    case c
    of '[', '(': inc depth
    of ']', ')': dec depth
    else: discard
    if depth == 0 and c in {',', ';'}:
      result.add part.split(':')[0].strip
      part = ""
    else:
      part.add c

proc members(name, code: string, fieldsOnly: bool): seq[string] =
  ## The members `code`, the definition of type `name`, makes public: an
  ## object's or tuple's public fields, or unless `fieldsOnly`, an enum's
  ## values. docgen already leaves out private fields. Empty if `code`
  ## isn't such a type.
  let text = code.plainText.strip
  if text.leadingIdent != name: return
  let eq = text.find('=')
  if eq < 0: return
  let body = text[eq + 1 .. ^1].strip
  if body.startsWith("enum") and not fieldsOnly:
    for item in body["enum".len .. ^1].split(','):
      result.add item.leadingIdent
  elif body.startsWith("tuple["):
    result = tupleFields(body["tuple[".len ..< body.rfind(']')])
  elif body.startsWith("object") or body.startsWith("ref object"):
    for i, c in body:
      if c == '*':
        var j = i
        while j > 0 and body[j - 1] in IdentChars: dec j
        if j < i: result.add body[j ..< i]

proc surface*(module, idx, source: string,
    page: proc (path: string): string): seq[string] =
  ## The Public Surface lines of `module`, sorted. `idx` is its `.idx` file
  ## and `source` its `.nim` file; `page` reads an HTML page of `htmldocs/`
  ## by path from its root.
  let own = module & ".html"
  var symbols: seq[Symbol]
  fromIdx(idx, symbols)
  fromExports(own, page(own), symbols)
  var lines: HashSet[string]
  var seen: HashSet[(Symbol, bool)]
  proc addMembers(s: Symbol, reached: bool) =
    ## `s`'s members, and the fields of the types its definition links to,
    ## such as a field's: `HookInfo.root` reaches `Level.spec`. A `reached`
    ## type isn't in scope, so its enum values can't be named.
    if (s, reached) in seen: return
    seen.incl (s, reached)
    let name = s.anchor.stripDup
    let code = page(s.page).definition(s.anchor)
    let names = members(name, code, fieldsOnly = reached)
    for m in names:
      lines.incl module & "." & name & "." & m
    if names.len > 0:
      for t in links(s.page, code):
        addMembers(t, reached = true)
  for s in symbols:
    lines.incl module & "." & s.anchor.stripDup
    addMembers(s, reached = false)
  for name in fromStdExports(source):
    lines.incl module & "." & name
  result = lines.toSeq.sorted

const header = "# The Public Surface (ADR 0090), written by `nimble surface`. A line\n" &
  "# without a leading `!` is supported, so a Pin in tests/api/ must back it.\n"

proc snapshot*(lines: seq[string], old: string): string =
  ## `surface.txt` listing `lines`, sorted, each marked `!` if `old`, the
  ## file it replaces, marked it.
  var marked: HashSet[string]
  for line in old.splitLines:
    if line.startsWith("!"): marked.incl line[1 .. ^1]
  result = header
  for line in lines.sorted:
    result.add (if line in marked: "!" else: "") & line & "\n"

const PublicModules = ["argumint", "argumint/customarg", "argumint/configsource",
  "argumint/configsource/ini", "argumint/configsource/json", "argumint/help"]
  ## ADR 0080's public modules.

proc moduleName(path: string): string =
  ## `path` as an import names it, but `"../src/argumint/core/backend"` as
  ## `argumint/core/backend`.
  result = path.strip(chars = {'"', ' '})
  let i = result.rfind("src/argumint")
  if i >= 0: result = result[i + "src/".len .. ^1]

proc imports(source: string): seq[string] =
  ## The modules `source`'s top-level `import`, `include` and `from`
  ## statements name.
  for s in statements(source, ["from "]):
    result.add moduleName(s.strip.split(' ')[0])
  for s in statements(source, ["import ", "include "]):
    var depth = 0
    var item = ""
    for c in s.split(" except ")[0] & ",":
      if c == '[': inc depth
      elif c == ']': dec depth
      if depth == 0 and c == ',':
        let parts = item.strip.split(" as ")[0].strip.split('[', 1)
        if parts.len == 1:
          result.add moduleName(parts[0])
        else:
          for sub in parts[1].strip(chars = {']', ' '}).split(','):
            result.add moduleName(parts[0] & sub.strip)
        item = ""
      else:
        item.add c

proc pinFailures*(listing: string, tests: openArray[(string, string)]): seq[string] =
  ## Why `listing`, a `surface.txt`, and `tests`, each test file's path and
  ## source, break ADR 0090's rules; empty if they don't.
  var supported, marked, pinned: HashSet[string]
  for line in listing.splitLines:
    if line.len == 0 or line.startsWith("#"): continue
    if line.startsWith("!"): marked.incl line[1 .. ^1]
    else: supported.incl line
  for (path, source) in tests:
    let mods = imports(source).filterIt(it == "argumint" or it.startsWith("argumint/"))
    for m in mods:
      if m notin PublicModules:
        result.add path & ": imports " & m & ", which isn't public"
    var tags: seq[string]
    for line in source.splitLines:
      let i = line.find("# pins: ")
      if i >= 0: tags.add line[i + "# pins: ".len .. ^1].strip
    if tags.len == 0: continue
    if mods.len != 1 or mods[0] notin PublicModules:
      result.add path & ": a Pin imports one public module, not " & mods.join(", ")
      continue
    for tag in tags:
      let prefix = path & ": `# pins: " & tag & "` "
      if tag in marked:
        result.add prefix & "pins a `!` line, which is unsupported"
      elif tag notin supported:
        result.add prefix & "matches no line"
      elif not tag.startsWith(mods[0] & "."):
        result.add prefix & "names a line of " & tag.split('.')[0] & ", not " & mods[0]
      else:
        pinned.incl tag
  for line in supported.toSeq.sorted:
    if line notin pinned:
      result.add line & " has no Pin"

when isMainModule:
  const docs = "htmldocs"
  const snapshotPath = "tests/api/surface.txt"
  if not fileExists(docs / "argumint.idx"):
    quit "no " & docs & "/argumint.idx: run `nimble docs` first"
  proc page(path: string): string =
    if fileExists(docs / path): readFile(docs / path) else: ""
  var lines: seq[string]
  for m in PublicModules:
    lines.add surface(m, readFile(docs / m & ".idx"), readFile("src" / m & ".nim"), page)
  let old = if fileExists(snapshotPath): readFile(snapshotPath) else: ""
  let snap = snapshot(lines, old)
  writeFile(snapshotPath, snap)
  var tests: seq[(string, string)]
  for path in walkDirRec("tests/api", relative = false):
    if path.endsWith(".nim"):
      tests.add (path.replace('\\', '/'), readFile(path))
  let failures = pinFailures(snap, tests.sortedByIt(it[0]))
  for f in failures: echo f
  if failures.len > 0:
    quit $failures.len & " Public Surface failure(s); see tests/api/README.md", QuitFailure
