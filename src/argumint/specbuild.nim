## Spec construction: turns a spec tuple of `arg`/`opt`/`flag`/`command`
## values into a built `Spec` -- registering each Arg, compiling the usage
## string into an FSM, filling in the usage gaps, and cascading settings
## down the command tree.
##
## Sits *above* FSM compilation rather than beside the data model in
## `argumint/backend` -- see `docs/architecture.md` for why.
##
## Only `newSpec` is public API; `beginSpec`/`finishSpec`/`addArgs` are
## exported solely because generic `newSpec` instantiates in the caller's
## file (ADR 0030), and are not re-exported by the facade.

import std/[importutils, pegs, sequtils, sets, strformat, strutils, tables]

import ./[backend, errors, fsmgraph, parser]

privateAccess(Spec) ## Reaches `Spec`'s private fields (ADR 0030) from
  ## non-generic code only -- see `beginSpec`/`finishSpec` and docs/gotchas.md.

proc addArg(spec: Spec, arg: Arg, varName: string) =
  if arg.variants.len < 1:
    raise newException(SpecDefect, fmt"arg {varName} must have at least one variant")
  spec.args.add(arg)
  if spec.groups.hasKeyOrPut(arg.group, @[arg]):
    spec.groups[arg.group].add(arg)

  for variant in arg.variants:
    case arg.kind
    of Positional:
      # Matches `<arg>`
      if variant =~ PositionalVariantFormat:
        if spec.arguments.hasKeyOrPut(matches[0], arg):
          raise newException(SpecDefect, fmt"argument {matches[0]} already defined")
      else:
        raise newException(SpecDefect, fmt"invalid positional arg variant for {varName}: {variant}")
    of Optional, Flag:
      # Matches `-o[=<foo>]` or `--option[=<foo>]` but removes any help vars
      if variant =~ OptionalVariantFormat:
        if spec.options.hasKeyOrPut(matches[0], arg):
          raise newException(SpecDefect, fmt"option {matches[0]} already defined")
      else:
        raise newException(SpecDefect, fmt"invalid optional arg variant for {varName}: {variant}")
    of Command:
      if spec.commands.hasKeyOrPut(variant, CommandArg(arg)):
        raise newException(SpecDefect, fmt"command {variant} already defined")

proc addArgs*(self: Spec, spec: tuple) =
  for varName, arg in spec.fieldPairs:
    when arg is Arg:
      self.addArg(arg, varName)
    elif arg is tuple:
      self.addArgs(arg)
    else:
      raise newException(SpecDefect, fmt"all members of a spec tuple must be args or tuples, but {varName} is {$typeof(arg)}")

proc autoFillUsage(spec: Spec) =
  ## Fills in usage lines for whatever's unreachable (commands, positional
  ## args, `[options]`) so callers only need to hand-write the parts they
  ## want to customize -- see architecture.md's "autoFillUsage" section for
  ## the exact per-category fill-in rules.
  var newLines: seq[string]

  proc addLine(line: string) =
    ## Appends `line` to both the human-readable `spec.usage` and the
    ## `newLines` list later spliced onto `spec.fsm` -- one call keeps the
    ## two in sync instead of relying on every call site to remember both.
    spec.usage.addSep("\n")
    spec.usage.add line
    newLines.add line

  let reachable = spec.fsm.referencedArgs()
  let optionsUnreachable = spec.options.values.toSeq.deduplicate
    .anyIt(not (it of MessageArg) and it notin reachable)
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
    addLine prefix & positionals.mapIt(it.name).join(" ")
    prefixUsed = prefixUsed or optionsUnreachable

  for arg in spec.args.filterIt(it of MessageArg and it notin reachable):
    let variants = if arg.variants.len > 1: "(" & arg.variants.join(" | ") & ")" else: arg.variants[0]
    addLine variants

  if optionsUnreachable and not prefixUsed:
    addLine "[options]"

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
  ##   `docs/architecture.md`'s "autoFillUsage" section for how gaps in
  ##   `usage` are auto-filled.
  ## - `prolog` is the front matter for help messages generated from this spec.
  ## - `epilog` is the end matter for help messages generated from this spec.
  ## - `settings` holds `width`/`maxVariantsWidth`/`envDelim` -- see
  ##   `newSpecSettings`. Shared by reference -- not copied -- with every
  ##   nested subcommand's spec, so mutating it later (e.g. from a `before`
  ##   hook) applies live throughout the tree.
  ##
  ## Unlike `parseOrQuit*`, this doesn't catch `SpecDefect` (construction)
  ## or `ParseError`/`ValidationError`/`HelpError`/`MessageError` (if you
  ## call `result.parse(args, command)` yourself) -- use it when you need
  ## to handle those yourself, or just call `parse*` on the spec tuple
  ## directly for the same `newSpec` + parse in one step, still raising on
  ## failure.
  ##
  ## `spec` is **single-use**: parsing more than once accumulates into the
  ## same Args rather than starting fresh. Use `parsed*`/`parsedOrQuit*` to
  ## parse a fresh spec per call -- see
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  result = beginSpec(usage, prolog, epilog)
  result.addArgs(spec)
  result.finishSpec(settings)
