## The FSM's data model (`Spec`, `Arg` and its subtypes, `State`,
## `Transition`, `Matcher`) shared by `argumint/lexer`, `argumint/parser`,
## and `argumint/fsm`, plus the `{.base.}` methods (`parse*`, `envName*`,
## `configKey*`, ...) a custom `Arg` subtype must override to plug into
## parsing, env fallback, and Config Source lookup -- see
## `docs/adr/0017-argumint-reexports-for-custom-arg-types.md`. `ValueArg`/
## `FlagArg` (`argumint.nim`) are the built-in implementations of that
## interface. The graph-construction/simplification operations that build
## and mutate `State`/`Matcher` values live in `argumint/fsmgraph`, not here
## -- this module is the data model only.

import std/[hashes, pegs, strformat, strutils, tables, wordwrap]

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

  Transition* = ref object
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

const DefaultWidth* = 80 ## `newSpecSettings`'s default `width` when no terminal width can be auto-detected (e.g. piped output with `COLUMNS` unset)
const DefaultMaxVariantsWidth* = 30 ## `newSpecSettings`'s default `maxVariantsWidth`
const DefaultEnvDelim* = ":" ## `newSpecSettings`'s default `envDelim`, the `PATH`-style convention
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
  ## Raises `ParseError` with `msg` verbatim, no usage block appended -- use
  ## the `(msg, command, spec)` overload when a usage block should follow.
  raise newException(ParseError, msg)

proc raiseParseError*(msg: string, command: string, spec: Spec) =
  ## Raises `ParseError` with `msg` followed by `spec.usage` formatted via
  ## `formatUsage` -- the shape most parse-time failures use.
  raiseParseError("{msg}\n\n{spec.usage.formatUsage(command, spec.settings.width)}".fmt)

proc name*(self: Arg, variant = ""): string =
  ## Returns the seen name `variant` or the first name of `self` if blank.
  if variant.len > 0: variant else: self.variants[0]

proc hash*(self: Arg): Hash =
  ## Hash function for args so they can be used as keys in tables.
  hash(self.name)

method parse*(self: Arg, value: string, variant = "") {.base.} =
  ## Converts/validates/stores a matched `value` (raw command-line/env/config
  ## string) onto `self`, or otherwise fires `self`'s side effect for the
  ## variant that matched -- `ValueArg`/`FlagArg`/`MessageArg` (`argumint.nim`)
  ## all override this. Base case is unreachable for every built-in Arg
  ## subtype except `HelpArg`, which instead overrides the `(command, spec)`
  ## overload below since it needs the enclosing spec to render help text.
  raise newException(Defect, fmt"parse() is not defined for {self.name(variant)}")

method parse*(self: Arg, command: string, spec: Spec, variant = "") {.base.} =
  ## Like the single-`value` overload above, but for an Arg (only `HelpArg`,
  ## in practice) whose side effect needs the enclosing `spec`/`command` --
  ## e.g. to render a full help message -- rather than a matched value.
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
