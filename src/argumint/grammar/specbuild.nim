## Spec construction: turns a spec tuple of `arg`/`opt`/`flag`/`command`
## values into a built `Spec` -- registering each Arg, compiling the usage
## string into an FSM, filling in the usage gaps, and cascading settings
## down the command tree.
##
## Sits *above* FSM compilation rather than beside the data model in
## `argumint/core/backend` -- see `docs/architecture.md`, "Spec construction",
## for why.
##
## `newSpec` and `eachArg` are public API (the facade wraps `eachArg`, ADR
## 0087); `beginSpec`/`finishSpec`/`addArgs` are exported solely because
## generic `newSpec` instantiates in the caller's file (ADR 0030), and are
## not re-exported by the facade.

import std/[importutils, macros, options, sequtils, sets, strformat, strutils, tables]

import ./[fsmgraph, parser, usage], ../core/[backend, errors, variant]

privateAccess(Spec) ## Reaches `Spec`'s private fields (ADR 0030) from
  ## non-generic code only -- see `beginSpec`/`finishSpec` and docs/gotchas.md.

proc addArg(spec: Spec, arg: Arg, varName: string) =
  if arg.variants.len < 1:
    raise newException(SpecDefect, fmt"arg {varName} must have at least one variant")
  spec.args.add(arg)
  # Filled in on the Arg itself, so everything reading `group` agrees.
  arg.group = arg.group.groupOr(arg.kind)
  if spec.groups.hasKeyOrPut(arg.group, @[arg]):
    spec.groups[arg.group].add(arg)

  for variant in arg.variants:
    let shape =
      case arg.kind
      of Positional: VariantShape.Positional
      of Optional: VariantShape.Option
      of Flag: VariantShape.Flag
      of Command: VariantShape.Command
    let parts = parseVariant(variant, shape)
    if parts.isNone:
      raise newException(SpecDefect, fmt"invalid {($arg.kind).toLowerAscii} arg variant for {varName}: {variant}")
    let name = parts.get.name
    case arg.kind
    of Positional:
      if spec.arguments.hasKeyOrPut(name, arg):
        raise newException(SpecDefect, fmt"argument {name} already defined")
    of Optional, Flag:
      if spec.options.hasKeyOrPut(name, arg):
        raise newException(SpecDefect, fmt"option {name} already defined")
    of Command:
      if spec.commands.hasKeyOrPut(name, CommandArg(arg)):
        raise newException(SpecDefect, fmt"command {name} already defined")

proc registerArgs(spec: Spec, args: seq[(Arg, string)]) =
  ## Adds each of `args` (an Arg and its tuple field name), first sizing
  ## `spec`'s tables for them -- see docs/gotchas.md, table default capacity.
  var arguments, options, commands = 0
  var groups: seq[string]
  for (arg, _) in args:
    let group = arg.group.groupOr(arg.kind)
    if group notin groups:
      groups.add group
    case arg.kind
    of Positional: arguments += arg.variants.len
    of Optional, Flag: options += arg.variants.len
    of Command: commands += arg.variants.len
  # Even pre-sized for 0 keys a table allocates, so an unused one is skipped.
  if arguments > 0:
    spec.arguments = initOrderedTable[string, Arg](arguments)
  if options > 0:
    spec.options = initOrderedTable[string, Arg](options)
  if commands > 0:
    spec.commands = initOrderedTable[string, CommandArg](commands)
  if groups.len > 0:
    spec.groups = initOrderedTable[string, seq[Arg]](groups.len)
  for (arg, varName) in args:
    spec.addArg(arg, varName)

proc spelling(n: NimNode): string =
  ## The name an ident, symbol or symbol choice spells.
  if n.kind in {nnkOpenSymChoice, nnkClosedSymChoice}: n[0].strVal
  else: n.strVal

proc unbind(n: NimNode, names: openArray[string]): NimNode =
  ## `n` with each symbol spelled like one of `names` turned back into an
  ## ident -- see docs/gotchas.md, a generic's prepass binding a macro's
  ## loop names.
  if n.kind in {nnkSym, nnkOpenSymChoice, nnkClosedSymChoice} and
      n.spelling in names:
    return ident(n.spelling)
  result = n
  for i in 0 ..< n.len:
    result[i] = unbind(n[i], names)

proc retarget(n: NimNode, walk, visit: NimNode, inLoop = false,
    inBlock = false): NimNode =
  ## `n` with each bare `break` sent to `walk` and each `continue` to
  ## `visit`, but for a `break` in a loop or block, a `continue` in a loop,
  ## or either in a routine or nested `eachArg` that `n` opens itself.
  result = n
  if n.kind in CallNodes and n[0].kind != nnkEmpty:
    let callee = if n[0].kind == nnkDotExpr: n[0][1] else: n[0]
    if callee.kind in {nnkIdent, nnkSym, nnkOpenSymChoice,
        nnkClosedSymChoice} and callee.spelling == "eachArg":
      return
  case n.kind
  of nnkBreakStmt:
    if n[0].kind == nnkEmpty and not (inLoop or inBlock):
      return nnkBreakStmt.newTree(walk)
  of nnkContinueStmt:
    if not inLoop:
      return nnkBreakStmt.newTree(visit)
  of RoutineNodes:
    return
  of nnkForStmt, nnkWhileStmt:
    for i in 0 ..< n.len:
      result[i] = retarget(n[i], walk, visit, true, inBlock)
  of nnkBlockStmt, nnkBlockExpr:
    for i in 0 ..< n.len:
      result[i] = retarget(n[i], walk, visit, inLoop, true)
  else:
    for i in 0 ..< n.len:
      result[i] = retarget(n[i], walk, visit, inLoop, inBlock)

macro eachArg*(spec: tuple, name, arg, body: untyped): untyped =
  ## Runs `body` once for each Arg `newSpec(spec)` registers -- see the
  ## facade's `eachArg`.
  let
    names = [name.spelling, arg.spelling]
    name = ident(name.spelling)
    arg = ident(arg.spelling)
    body = unbind(body, names)
    walk = genSym(nskLabel, "walk")
    tup = genSym(nskLet, "spec")
    seen = genSym(nskVar, "seen")
    argType = bindSym"Arg"
  var visits = newStmtList()

  proc visitLeaves(access, tupleType: NimNode) =
    ## Adds to `visits` a visit of each Arg in the tuple `access`, of type
    ## `tupleType`, going into nested tuples in field order.
    var i = 0
    for def in tupleType.getTypeImpl:
      let (fieldNames, fieldType) =
        if def.kind == nnkIdentDefs: (def[0 ..^ 3].mapIt(it.strVal), def[^2])
        else: (@["Field" & $i], def)
      for fieldName in fieldNames:
        let field = nnkBracketExpr.newTree(access, newLit(i))
        inc i
        if fieldType.getTypeImpl.kind in {nnkTupleTy, nnkTupleConstr}:
          visitLeaves(field, fieldType)
          continue
        let
          visit = genSym(nskLabel, "visit")
          visitBody = retarget(body.copyNimTree, walk, visit)
        # Not `fmt`: see docs/gotchas.md, `fmt`'s braces in a generic proc.
        visits.add quote do:
          when `field` is `argType`:
            if `argType`(`field`) notin `seen`:
              `seen`.add `argType`(`field`)
              block `visit`:
                let `name` {.used.} = `fieldName`
                let `arg` {.used.} = `field`
                `visitBody`
          else:
            {.error: "all members of a spec tuple must be args or tuples, " &
              "but " & `fieldName` & " is " & $typeof(`field`).}

  visitLeaves(tup, spec.getTypeInst)
  result = quote do:
    block `walk`:
      let `tup` = `spec`
      var `seen`: seq[`argType`]
      `visits`

proc addArgs*(self: Spec, spec: tuple) =
  var args: seq[(Arg, string)]
  spec.eachArg(name, arg):
    args.add (Arg(arg), name)
  self.registerArgs(args)

proc autoFillUsage(spec: Spec) =
  ## Fills in usage lines for whatever's unreachable (commands, positional
  ## args, `[options]`) so callers only need to hand-write the parts they
  ## want to customize -- see architecture.md's "Auto-filled usage" section
  ## for the exact per-category fill-in rules.
  var newLines: seq[string]

  proc addLine(line: string) =
    ## Appends `line` to both the human-readable `spec.usage` and the
    ## `newLines` list later spliced onto `spec.fsm` -- one call keeps the
    ## two in sync instead of relying on every call site to remember both.
    ## `newLines` gets it through `splitUsage`, as `genFsm` would.
    spec.usage.addSep("\n")
    spec.usage.add line
    newLines.add line.splitUsage

  let reachable = spec.fsm.referencedArgs()
  let optionsUnreachable = spec.options.values.toSeq.deduplicate
    .anyIt(not it.isMessage and it notin reachable)
  let prefix = if optionsUnreachable: "[options] " else: ""
  var prefixUsed = false

  let unreachableCommands = spec.args.filterIt(it.kind == Command and it notin reachable)
  if unreachableCommands.len > 0:
    let variants = unreachableCommands.mapIt(it.variants).concat
    let combined = if variants.len > 1: "(" & variants.join(" | ") & ")" else: variants[0]
    addLine prefix & combined
    prefixUsed = prefixUsed or optionsUnreachable

  let positionals = spec.args.filterIt(it.kind == Positional)
  if positionals.len > 0 and positionals.allIt(it notin reachable):
    let accumulating = positionals.filterIt(it.accumulates).mapIt(it.name)
    # How values split between several is the author's call -- see
    # architecture.md's "Auto-filled usage" section.
    if accumulating.len > 1:
      let names = accumulating.join(", ")
      raise newException(SpecDefect,
        "can't auto-fill a usage line for more than one multi-value " &
        fmt"Positional Argument ({names}); write a usage line that shows " &
        "how values split between them")
    let names = positionals.mapIt(if it.name in accumulating: it.name & "..." else: it.name)
    addLine prefix & names.join(" ")
    prefixUsed = prefixUsed or optionsUnreachable

  # Before the Message Argument lines -- see architecture.md's "Auto-filled
  # usage" section.
  if optionsUnreachable and not prefixUsed:
    addLine "[options]"

  # A Positional one already sits in the positional line above.
  let messageArgs = spec.args.filterIt(it.isMessage and it.kind != Positional and
    it notin reachable)
  # Nothing else accepts an empty command line -- see architecture.md's
  # "Auto-filled usage" section.
  if spec.usage.len == 0 and messageArgs.len > 0:
    addLine "{cmd}"

  for arg in messageArgs:
    let variants = if arg.variants.len > 1: "(" & arg.variants.join(" | ") & ")" else: arg.variants[0]
    addLine variants

  if newLines.len > 0:
    spec.addUsageLines(spec.fsm, newLines)
    spec.fsm.prepare()

proc cascadeSpecSettings(spec: Spec, settings: SpecSettings) =
  ## Shares `settings` by reference with `spec` and every nested subcommand's
  ## spec, so a value given to the top-level `newSpec`/`parse*` call --  or a
  ## later mutation of that same `SpecSettings` instance -- applies uniformly
  ## throughout the whole command tree without needing to be repeated at
  ## each `command()` call.
  spec.settings = settings
  for cmd in spec.commands.values:
    cmd.spec.cascadeSpecSettings(settings)

proc beginSpec*(usage, prolog, epilog: string): Spec =
  ## Creates an argless `Spec` for `newSpec*` to populate. Non-generic
  ## bookend, with `finishSpec` -- see docs/gotchas.md.
  Spec(usage: usage, prolog: prolog, epilog: epilog)

proc finishSpec*(spec: Spec, settings: SpecSettings) =
  ## Compiles `spec`'s FSM, fills in the usage gaps, and cascades
  ## `settings`. Non-generic bookend, with `beginSpec` -- see docs/gotchas.md.
  spec.fsm = spec.genFsm()
  spec.autoFillUsage()
  spec.cascadeSpecSettings(settings)

proc newSpec*(spec: tuple, usage = "", prolog = "", epilog = "",
    settings = newSpecSettings()): Spec =
  ## Creates a new spec from a spec tuple and builds its FSM.
  ## - `usage` is the usage string used to build the FSM. See
  ##   `docs/architecture.md`'s "Auto-filled usage" section for how gaps in
  ##   `usage` are auto-filled.
  ## - `prolog` is the front matter for help messages generated from this spec.
  ## - `epilog` is the end matter for help messages generated from this spec.
  ## - `settings` is the `SpecSettings` the whole tree shares -- see
  ##   `newSpecSettings`. Shared by reference -- not copied -- with every
  ##   nested subcommand's spec, so mutating it later (e.g. from a `before`
  ##   hook) applies live throughout the tree.
  ##
  ## Unlike `parseOrQuit*`, this doesn't catch `SpecDefect` (construction)
  ## or `ParseError`/`MessageError` and their subtypes (if you call
  ## `result.parse(args, command)` yourself) -- use it when you need to
  ## handle those yourself, or just call `parse*` on the spec tuple directly
  ## for the same `newSpec` + parse in one step, still raising on failure.
  ##
  ## `spec` is **single-use**: parsing more than once accumulates into the
  ## same Args rather than starting fresh. Use `parsed*`/`parsedOrQuit*` to
  ## parse a fresh spec per call -- see
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  result = beginSpec(usage, prolog, epilog)
  result.addArgs(spec)
  result.finishSpec(settings)
