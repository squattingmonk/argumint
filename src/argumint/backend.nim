import std/[algorithm, hashes, pegs, sequtils, sets, strformat, strutils, sugar, tables, wordwrap]

# `Option` (the type) deliberately left unqualified-unimported --
# `options.Option[T]` instead -- see docs/gotchas.md.
from std/options import some, none, isSome, get

import ./configsource
export configsource


type
  ParseError* = object of CatchableError
  MessageError* = object of CatchableError
  HelpError* = object of MessageError
  CompletionError* = object of MessageError
    ## Carries the newline-joined shell-completion candidates for a
    ## `__complete` request (see `fsm.parse*`). A peer of `HelpError`, not a
    ## subtype of it -- reuses `parseOrQuit*`'s existing `except
    ## MessageError as e: quit(e.msg, QuitSuccess)` branch for free. See
    ## `docs/adr/0012-fsm-driven-shell-completion.md`.

  ArgKind* {.pure.} = enum
    Command ## A subcommand (e.g., `clone`)
    Positional ## A positional argument (e.g., `<arg>`)
    Optional ## An optional argument that takes a value (e.g., `-o value` or `--option value`)
    Flag ## An optional argument that takes no value (e.g., `-f` or `--flag`)

  Arg* = ref object of RootObj
    kind*: ArgKind
    variants*: seq[string] ## The forms in which the argument may appear
    help*: string ## The help string for the argument
    group*: string ## The group where the argument should appear in help messages
    hidden*: bool ## Whether the arg should be shown in help messages

  CommandArg* = ref object of Arg
    spec*: Spec

  MessageArg* = ref object of Arg
    message*: string

  HelpArg* = ref object of MessageArg

  SpecSettings* = ref object
    width*: int ## Column width to wrap usage/help text at
    maxVariantsWidth*: int ## Max width of the help text's variants column before wrapping; 0 means unlimited
    envDelim*: string ## Delimiter an env-configured Option/Flag's raw env value is split on (after `\x1e` and any per-Arg `EnvSource.delim` override, see `splitEnvValue`)
    configSources*: seq[ConfigSource] ## Value Precedence's Config Source tier, consulted in order -- a later source's hit for the same Arg fully replaces an earlier one's, never merged (see `lookupConfigSources`)

  EnvSource* = object
    ## Names the environment variable configured to supply an Arg's value,
    ## with an optional per-Arg override of the delimiter its raw value is
    ## split on -- see `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
    ## `name` is required (not `Option[string]`): an override with no name
    ## to apply it to is a meaningless state, so "is there an env source at
    ## all" is instead answered by wrapping this whole object in `Option`
    ## wherever it's used (e.g. `ValueArg.env`/`FlagArg.env`).
    name*: string
    delim*: options.Option[string] ## `none` inherits `Spec.settings.envDelim`; `some("")` means never split this Arg's value at all, even on `\x1e`

  Spec* = ref object
    prolog*: string ## Front matter for a help message
    epilog*: string ## Back matter for a help message
    usage*: string ## Usage string used to build the FSM for parsing
    args*: seq[Arg] ## List of all args known to this spec
    commands*: OrderedTable[string, CommandArg] ## Maps command variants to args
    arguments*: OrderedTable[string, Arg] ## Maps positional arg variants to args
    options*: OrderedTable[string, Arg] ## Maps option and flag arg variants to args
    groups*: OrderedTable[string, seq[Arg]] ## List of args in each group
    fsm*: State ## The initial state for the FSM used for parsing
    settings*: SpecSettings ## Shared by reference with every nested subcommand's Spec -- mutating it (e.g. from a `before` hook) affects every not-yet-dispatched Spec in the tree, including this one's own message/help output (see `docs/adr/0013-message-args-fire-after-before.md`)
    before*: proc () ## Fires once this spec's own values are parsed, before dispatch descends into any Command matched at this spec's own level
    action*: proc () ## Fires once this spec's own values are parsed, only if this spec is the dynamic leaf (no nested Command matched)
    after*: proc () ## Fires once this spec's own before/action/nested dispatch has run, whether it succeeded or raised

  State* = ref object
    ## The basic building block of the FSM. A state can be final or not and has
    ## transitions to other states.
    terminal*: bool
    transitions*: seq[Transition]

  Transition = ref object
    ## If a transition's matcher matches, the next state can be reached.
    matcher*: Matcher
    next*: State

  # Declaration order doubles as match priority (`priority`/
  # `sortTransitions`, below)
  MatcherKind* {.pure.} = enum
    Option, Options, Command, Argument, OptsEnd, Shortcut

  Matcher* = ref object
    ## A `ref` so a Matcher created for a `[options]` atom (see `parser.atom`'s
    ## `tkAnyOption` branch) can be patched in place after the fact -- once
    ## the whole Usage Line is parsed and `explicitOptions` is final --
    ## regardless of how many times its surrounding `Transition` gets copied
    ## by `sequence`'s local `add` helper as composition proceeds (see
    ## `docs/gotchas.md`). A value-type `Matcher` would make every such copy
    ## independent, silently discarding the patch.
    case kind*: MatcherKind
    of Argument:
      arg*: Arg
    of Option:
      opt*: Arg
    of Options:
      opts*: seq[Arg]
    of Command:
      cmd*: CommandArg
    else:
      discard

const DefaultWidth* = 80
const DefaultMaxVariantsWidth* = 30
const DefaultEnvDelim* = ":"
const EnvListSep* = "\x1e" ## Tried before `Spec.settings.envDelim` and any non-empty per-Arg `EnvSource.delim` override -- see `splitEnvValue`

proc splitEnvValue*(value: string, delimOverride: options.Option[string], envDelim: string): seq[string] =
  ## Splits a raw env var's value into the (possibly several) values it
  ## supplies to Value Precedence's environment-variable tier. Resolves in
  ## order, most-specific first -- see
  ## `docs/adr/0015-per-arg-env-delimiter-overrides.md`:
  ## 1. `delimOverride` (the matched Arg's own `EnvSource.delim`) is
  ##    `some("")` -- never split; `value` is the only element.
  ## 2. `EnvListSep` (`\x1e`) is present in `value` -- split on it, since
  ##    that's how fish auto-joins a native list variable's elements for
  ##    any variable name when exporting it to a subprocess, regardless of
  ##    any configured delimiter.
  ## 3. `delimOverride` is `some(d)`, `d != ""` -- split on `d`.
  ## 4. Otherwise -- split on `envDelim` (`Spec.settings.envDelim`, the
  ##    `PATH`-style `:` convention by default).
  ##
  ## Empty segments (a stray leading/trailing/doubled delimiter) are kept
  ## as literal values, not dropped, so an env value is never treated
  ## differently from one typed on the command line -- see
  ## `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`.
  if delimOverride == some(""): @[value]
  elif EnvListSep in value: value.split(EnvListSep)
  elif delimOverride.isSome: value.split(delimOverride.get)
  else: value.split(envDelim)

proc formatUsage*(usage: string, command: string, width = DefaultWidth): string =
  ## Formats `usage` (a spec's raw usage string, one alternative per line) as
  ## a "Usage:" block, prefixing each alternative with `command`. Lines
  ## longer than `width` are wrapped, with continuations hanging-indented to
  ## align under the first token after `command` rather than restarting at
  ## the left margin.
  var lines = @["Usage:"]
  for line in usage.split(peg"\n!\s"):
    let prefix = "  {command} ".fmt
    let indent = ' '.repeat(prefix.len)
    let lineWidth = max(width - prefix.len, 20)
    lines.add prefix & line.wrapWords(lineWidth, splitLongWords = false, newLine = "\n" & indent)
  result = lines.join("\n")

proc raiseParseError*(msg: string) =
  raise newException(ParseError, msg)

proc raiseParseError*(msg: string, command: string, spec: Spec) =
  raiseParseError("{msg}\n\n{spec.usage.formatUsage(command, spec.settings.width)}".fmt)

proc name*(self: Arg, variant = ""): string =
  ## Returns the seen name `variant` or the first name of `self` if blank.
  if variant.len > 0: variant else: self.variants[0]

proc hash*(self: Arg): Hash =
  ## Hash function for args so they can be used as keys in tables.
  hash(self.name)

method parse*(self: Arg, value: string, variant = "") {.base.} =
  raise newException(Defect, fmt"parse() is not defined for {self.name(variant)}")

method parse*(self: Arg, command: string, spec: Spec, variant = "") {.base.} =
  raise newException(Defect, fmt"parse() is not defined for {self.name(variant)}")

method defaultStr*(self: Arg): string {.base.} =
  ## Returns `self`'s default value formatted for display in help text (e.g.
  ## via `[default: <value>]`), or an empty string if there's nothing worth
  ## showing. The base case (commands, flags, and message args) has no
  ## notion of a displayable default; `ValueArg` overrides this per-type via
  ## `defineArg`.
  ""

method completions*(self: Arg): seq[string] {.base.} = @[]
  ## Returns every value `self` would accept as a *value* (not a variant
  ## spelling), for shell-completion purposes -- or `@[]` if unenumerable or
  ## not applicable. The base case (commands, flags, message args -- none of
  ## which carry a `Validator`) has nothing to show; `ValueArg` overrides
  ## this per-type via `defineArg` (`argumint.nim`).

method validatorHelp*(self: Arg): string {.base.} =
  ## Returns a short description of what values `self` accepts (e.g.
  ## "choices: foo, bar, baz"), or an empty string if `self` has no
  ## `Validator` or there's nothing meaningful to show. The base case
  ## (commands, flags, and message args, none of which have validators) has
  ## nothing to show; `ValueArg` overrides this per-type via `defineArg`.
  ""

method variantDesc*(self: Arg, variant: string): string {.base.} =
  ## Returns a short description of what a specific `variant` of `self`
  ## does (e.g. "Increase by 5"), or an empty string if there's nothing to
  ## disambiguate. The base case (everything but flags with divergent
  ## per-variant ops) has nothing to show; `FlagArg` overrides this
  ## per-type via `defineArg`.
  ""

method envName*(self: Arg): string {.base.} =
  ## Returns the environment variable configured to supply this arg's
  ## value, or "" if none. Base case (positional args, commands, message
  ## args) has no notion of one; `ValueArg`/`FlagArg` override this
  ## per-type via `defineArg`/`defineFlagArg`. Consulted regardless of
  ## whether the arg is required or optional in the usage grammar -- see
  ## `docs/adr/0004-required-options-env-fallback.md`.
  ""

method envDelim*(self: Arg): options.Option[string] {.base.} =
  ## Returns this arg's own `EnvSource.delim` override, or `none` if it has
  ## none configured (including if it has no `envName` at all). Base case
  ## mirrors `envName`; `ValueArg`/`FlagArg` override this per-type via
  ## `defineArg`/`defineFlagArg`. See
  ## `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  none(string)

method setFromEnv*(self: Arg, values: seq[string]) {.base.} =
  ## Applies an already-fetched, already-split environment variable value
  ## to this arg, as if each value in `values` had matched on the command
  ## line in order (but not overriding an explicit CLI value -- callers
  ## are expected to check that first). Goes through the same
  ## conversion/validation as a CLI-supplied value. See
  ## `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`.
  raise newException(Defect, fmt"setFromEnv() is not defined for {self.name}")

method configKey*(self: Arg): ConfigKey {.base.} =
  ## Returns the structured path this arg's value is looked up under in
  ## Value Precedence's Config Source tier, or `@[]` if none configured.
  ## Base case (positional args, commands, message args) has no notion of
  ## one; `ValueArg`/`FlagArg` override this per-type via
  ## `defineArg`/`defineFlagArg`. See `docs/adr/0018-config-source.md`.
  @[]

method setFromConfig*(self: Arg, values: seq[string]) {.base.} =
  ## Applies an already-resolved Config Source value to this arg, the same
  ## shape as `setFromEnv` (each value in `values` applied as if it had
  ## matched on the command line, in order, not overriding an explicit CLI
  ## or env value -- callers are expected to check those first). Goes
  ## through the same conversion/validation as a CLI-supplied value. See
  ## `docs/adr/0018-config-source.md`.
  raise newException(Defect, fmt"setFromConfig() is not defined for {self.name}")

func priority(m: Matcher): int {.inline.} =
  ## Returns the priority of the matcher, allowing them to be sorted by
  ## priority.
  ord(m.kind)

proc name*(m: Matcher): string {.inline.} =
  ## Returns the name of the matcher. Usually, this will be the first declared
  ## variant of its arg, but some matchers have special names.
  case m.kind
  of Shortcut: "*"
  of OptsEnd: "--"
  of Command: fmt"Cmd({m.cmd.name})"
  of Argument: fmt"Arg({m.arg.name})"
  of Option: fmt"Opt({m.opt.name})"
  of Options:
    let names = collect:
      for opt in m.opts: opt.name
    fmt"""Opts({names.join(" | ")})"""

func isShortcut*(m: Matcher): bool {.inline.} =
  ## Returns whether a given matcher is a shortcut.
  m.kind == Shortcut

proc underlyingArg*(m: Matcher): Arg =
  ## The Arg an Option or Argument matcher matches directly, or `nil` for any
  ## other kind -- `Options`/`Command`/`Shortcut` don't match a single Arg the
  ## way a caller collapsing a trivial choice alternative needs.
  case m.kind
  of Option: m.opt
  of Argument: m.arg
  else: nil

proc excludeOptions*(m: Matcher, exclude: HashSet[Arg]) =
  ## Removes every Arg in `exclude` from an `Options` matcher's candidate
  ## list -- used so `[options]` can drop an option mentioned explicitly
  ## elsewhere on the same Usage Line (see `parser.genFsm`).
  assert m.kind == Options
  m.opts = m.opts.filterIt(it notin exclude)

proc newShortcut*(): Matcher =
  ## Returns a new shortcut `Matcher`. A shortcut will always match.
  Matcher(kind: Shortcut)

proc newOptsEndMatcher*(): Matcher =
  ## Returns a new end-of-options-marker `Matcher`. Always matches -- see
  ## `docs/adr/0020-usage-string-end-of-options-marker.md`.
  Matcher(kind: OptsEnd)

proc newArgMatcher*(arg: Arg): Matcher =
  ## Creates a new `Matcher` for an argument `arg`.
  assert arg.kind == Positional
  Matcher(kind: Argument, arg: arg)

proc newOptMatcher*(opt: Arg): Matcher =
  ## Creates a new `Matcher` for an option or flag `opt`.
  assert opt.kind in [Optional, Flag]
  Matcher(kind: Option, opt: opt)

proc newOptsMatcher*(opts: openArray[Arg]): Matcher =
  ## Creates a new `Matcher` for an option or flag in `opts`.
  assert opts.allIt(it.kind in [Optional, Flag])
  Matcher(kind: Options, opts: @opts)

proc newCmdMatcher*(cmd: CommandArg): Matcher =
  ## Creates a new `Matcher` for a command `cmd`.
  assert cmd.kind == Command
  Matcher(kind: Command, cmd: cmd)

func newState*(terminal = false): State =
  ## Creates a new `State`. If `terminal` is true and there are no more
  ## arguments to process after the state has been reached, FSM navigation will
  ## be deemed successful.
  State(terminal: terminal)

proc add*(s: State, next: State, matcher: Matcher) =
  ## Creates a transition between two states that can be followed if `matcher`
  ## matches.
  s.transitions.add(Transition(matcher: matcher, next: next))

proc add*(s: State, matcher: Matcher): State =
  ## Creates a new State, adds a transition from `s` to it that can be followed
  ## if `matcher` matches, and returns the new state.
  result = State(terminal: false)
  s.add(result, matcher)

proc addShortcut*(s: State, next: State) =
  ## Adds a shortcut between two states.
  s.add(next, newShortcut())

proc terminals(s: State, states: var seq[State], visited = newTable[State, bool]()) =
  visited[s] = true
  for tr in s.transitions:
    if tr.next notin visited:
      if tr.next.terminal:
        states.add tr.next
      tr.next.terminals(states, visited)

iterator terminals*(s: State): State =
  ## Iterates over all terminal states in the fsm with root note `s` using a
  ## depth-first approach.
  var states: seq[State] = @[]
  s.terminals(states)
  for state in states:
    yield state

proc collectArgs(s: State, args: var HashSet[Arg], visited = newTable[State, bool]()) =
  if visited.hasKeyOrPut(s, true):
    return
  for tr in s.transitions:
    case tr.matcher.kind
    of Argument: args.incl tr.matcher.arg
    of Option: args.incl tr.matcher.opt
    of Options:
      for opt in tr.matcher.opts:
        args.incl opt
    of Command: args.incl tr.matcher.cmd
    of OptsEnd: discard
    of Shortcut: discard
    tr.next.collectArgs(args, visited)

proc referencedArgs*(s: State): HashSet[Arg] =
  ## Returns every `Arg` referenced by a matcher reachable from `s`. Used to
  ## detect whether a declared arg (e.g. one created by `help()`) is actually
  ## reachable via the usage grammar, so it can be added automatically if not.
  s.collectArgs(result)

proc sortTransitions(s: State, visited = newTable[State, bool]()) =
  ## Recursively sorts all transitions for `s` by their matchers' priorities.
  ## `visited` tracks whether the state has been sorted already to avoid an
  ## infinite loop.
  if visited.hasKeyOrPut(s, true):
    return

  s.transitions.sort((a, b: Transition) => cmp(a.matcher.priority, b.matcher.priority))
  for t in s.transitions:
    sortTransitions(t.next, visited)

proc shortcutClosure(s: State): tuple[states: seq[State], terminal: bool] =
  ## Every state reachable from `s` via zero or more Shortcut-kind
  ## transitions (the epsilon-closure), in discovery order, plus whether any
  ## of them is terminal. `states` grows as it's scanned (a queue via
  ## index, not `.pop()`), preserving the same left-to-right discovery order
  ## `simplifySelf` used to produce, so downstream ordering (e.g. grouped
  ## error messages) doesn't depend on `HashSet[State]`'s unspecified
  ## iteration order. Bounded by `seen`, so this always terminates
  ## regardless of shortcut chains or cycles -- see docs/gotchas.md.
  var seen: HashSet[State]
  seen.incl s
  result.states.add s
  result.terminal = s.terminal
  var idx = 0
  while idx < result.states.len:
    let cur = result.states[idx]
    for tr in cur.transitions:
      if tr.matcher.isShortcut and tr.next notin seen:
        seen.incl tr.next
        result.states.add tr.next
        if tr.next.terminal:
          result.terminal = true
    idx.inc

proc simplifySelf(s: State) =
  ## Collapses every shortcut chain or cycle reachable from `s` directly
  ## onto `s`'s own transitions, via `s`'s shortcut-closure.
  let closure = s.shortcutClosure()
  var newTransitions: seq[Transition]
  for st in closure.states:
    for tr in st.transitions:
      if not tr.matcher.isShortcut and tr notin newTransitions:
        newTransitions.add tr
  s.transitions = newTransitions
  s.terminal = closure.terminal

proc simplify(s: State, visited = newTable[State, bool]()) =
  ## Recursively simplifies the transitions of `s` -- see `simplifySelf`.
  ## `visited` tracks whether the state has been simplified already to avoid
  ## an infinite loop.
  if visited.hasKeyOrPut(s, true):
    return

  for tr in s.transitions:
    tr.next.simplify(visited)

  s.simplifySelf()

proc prepare*(s: State) =
  ## Simplifies the fsm with root node `s` and recursively sorts all transitions
  ## according to their matchers' priorities.
  s.simplify()
  s.sortTransitions()
