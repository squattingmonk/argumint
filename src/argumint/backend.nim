## The FSM's data model (`Spec`, `Arg` and its subtypes, `State`,
## `Transition`, `Matcher`) shared by `argumint/lexer`, `argumint/parser`,
## and `argumint/fsm`, plus the `{.base.}` methods (`parse*`, `envName*`,
## `configKey*`, ...) a custom `Arg` subtype must override to plug into
## parsing, env fallback, and Config Source lookup -- see
## `docs/adr/0017-argumint-reexports-for-custom-arg-types.md`. `ValueArg`/
## `FlagArg` (`argumint.nim`) are the built-in implementations of that
## interface. The graph-construction/simplification operations that build
## and mutate `State`/`Matcher` values live in `argumint/fsmgraph`, not here.
##
## Alongside the model sit the pieces that belong beside it rather than in
## spec construction (`argumint/specbuild`): the constructors for the types
## declared here that never read a usage string (`newSpecSettings`, `env`,
## `toEnvSource`), the PEGs a Variant string must match, and `subject`,
## which names an Arg in a parse-failure message. See `docs/architecture.md`
## for where that line falls and why.

import std/[hashes, pegs, strformat, strutils, tables, terminal, wordwrap]

# `Option` (the type) deliberately left unqualified-unimported --
# `options.Option[T]` instead -- see docs/gotchas.md.
from std/options import some, none, isSome, isNone, get

import ./[configsource, errors]
export configsource


type
  ArgKind* {.pure.} = enum
    Command ## A subcommand (e.g., `clone`)
    Positional ## A positional argument (e.g., `<arg>`)
    Optional ## An optional argument that takes a value (e.g., `-o value` or `--option value`)
    Flag ## An optional argument that takes no value (e.g., `-f` or `--flag`)

  SeenBy* = enum
    ## Which Value Precedence tier supplied an Arg this parse -- a Seen Arg's
    ## provenance (`CONTEXT.md`). Ordered weakest-to-strongest, mirroring the
    ## precedence chain, so ordinal comparison is meaningful and part of the
    ## public contract: `arg.seenBy > byConfig` reads "supplied above the
    ## Config Source tier". Members must never be reordered. See
    ## `docs/adr/0039-per-arg-provenance.md`.
    byNone ## Nothing supplied it; the coded default (if any) applies
    byConfig ## A Config Source supplied it
    byEnv ## An environment variable supplied it
    byCli ## The command line supplied it

  Arg* = ref object of RootObj
    kind*: ArgKind
    variants*: seq[string] ## The forms in which the argument may appear
    help*: string ## The help string for the argument
    group*: string ## The group where the argument should appear in help messages
    hidden*: bool ## Whether the arg should be shown in help messages
    seenBy*: SeenBy ## Which Value Precedence tier supplied this Arg -- written by whichever `parse` override wrote the value, so provenance can never outrun the value it describes. `byNone` is the zero value, so an unsupplied Arg is correct with no code on the default path. See `seen*` and `docs/adr/0039-per-arg-provenance.md`

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
    strictOptions*: bool ## Strict Option Checking: whether an option-shaped token may be accepted as data, in both a positional slot and an Option's value slot. Default `true`; a Non-Option Short (`-5`, `-0x1F`) is always exempt. See `docs/adr/0034-strict-option-checking.md`

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

  HookInfo* = object
    matched*: seq[Arg] ## Every Arg matched during this invocation, across
      ## every spec level in the dispatch chain (not just the receiving
      ## hook's own level) -- a view onto `fsm.nim`'s internal `MatchTable`
      ## computed once from the walk `parse*` already performs, not a
      ## re-walk. E.g. `info.matched.anyIt(it of MessageArg)` (or
      ## `showsMessage(info)` below) to detect a Message/Help request from
      ## a `before` hook and skip expensive setup for it -- see
      ## `docs/adr/0021-hook-info-matched-args.md`.

  Spec* = ref object
    ## An opaque handle to a built command-line spec: name it, pass it
    ## around, hand it back to `parse*`/`parseOrQuit*`/`dot*`/
    ## `completionScript*`. Every field below that isn't marked `*` is
    ## argumint's own bookkeeping, deliberately unreachable from outside
    ## the library -- see
    ## `docs/adr/0030-core-types-exported-spec-opaque.md`.
    prolog: string ## Front matter for a help message
    epilog: string ## Back matter for a help message
    usage: string ## Usage string used to build the FSM for parsing
    args: seq[Arg] ## List of all args known to this spec
    commands: OrderedTable[string, CommandArg] ## Maps command variants to args
    arguments: OrderedTable[string, Arg] ## Maps positional arg variants to args
    options: OrderedTable[string, Arg] ## Maps option and flag arg variants to args
    groups: OrderedTable[string, seq[Arg]] ## List of args in each group
    fsm: State ## The initial state for the FSM used for parsing
    settings*: SpecSettings ## Shared by reference with every nested subcommand's Spec -- mutating it (e.g. from a `before` hook) affects every not-yet-dispatched Spec in the tree, including this one's own message/help output (see `docs/adr/0013-message-args-fire-after-before.md`)
    before*: proc (info: HookInfo) ## Fires once this spec's own values are parsed, before dispatch descends into any Command matched at this spec's own level
    action*: proc (info: HookInfo) ## Fires once this spec's own values are parsed, only if this spec is the dynamic leaf (no nested Command matched)
    after*: proc (info: HookInfo) ## Fires once this spec's own before/action/nested dispatch has run, whether it succeeded or raised

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
      variant*: string
    of Options:
      opts*: seq[Arg]
      variants*: seq[string]
    of Command:
      cmd*: CommandArg
    else:
      discard

const DefaultWidth* = 80 ## `newSpecSettings`'s default `width` when no terminal width can be auto-detected (e.g. piped output with `COLUMNS` unset)
const DefaultMaxVariantsWidth* = 30 ## `newSpecSettings`'s default `maxVariantsWidth`
const DefaultEnvDelim* = ":" ## `newSpecSettings`'s default `envDelim`, the `PATH`-style convention
const DefaultStrictOptions* = true ## `newSpecSettings`'s default `strictOptions` -- see `docs/adr/0034-strict-option-checking.md`
const EnvListSep* = "\x1e" ## Tried before `Spec.settings.envDelim` and any non-empty per-Arg `EnvSource.delim` override -- see `splitEnvValue`

# The comma separator every `variants`/`ops` string is split on, and the
# formats an `arg`/`opt`/`flag` Variant string must match. Exported for
# siblings (spec construction, `subject`, the Arg constructors, the
# `ValueArg`/`FlagArg` machinery in `argumint/argtypes`) but never
# re-exported by the facade -- reachable only via `import argumint/backend`,
# like everything else internal here.
let
  Comma* = peg"\s* ',' \s*"

  PositionalVariantFormat* = peg"""
    # Allows you to capture <arg>
    argument <- ^ {'<' \w (\w / ('-' \w))* '>'} $
  """

  OptionalVariantFormat* = peg"""
    # Allows you to capture [-o, var] / [--option, var] in -o=<var> / --option=<var>
    option <- ^ (shortOption / longOption) (equals helpVar)? $
    equals <- '=' / ':'
    shortOption <- {'-' \w}
    longOption <- {'--' \w (\w / ('-' \w))+}
    helpVar <- '<' {\w (\w / ('-' \w))*} '>'
  """

  FlagVariantFormat* = peg"""
    # A bare flag spelling, no embedded <op><value> -- that's supplied
    # explicitly via flagOp's own op/value params instead (see flag*/
    # flagOp*).
    flag <- ^ (shortFlag / longFlag) $
    shortFlag <- {'-' \w}
    longFlag <- {'--' \w (\w / ('-' \w))+}
  """

  FlagOpVariantFormat* = peg"""
    # A flag spelling with an optional embedded <op><value> suffix --
    # convenience sugar for flag*'s own `variants` string only (see
    # `splitFlagSpellings`/`parseFlagOpsString` in argumint/argtypes): a
    # bare spelling keeps the implicit blank-op behavior, a suffixed one
    # becomes its own single-spelling explicit FlagOp Alias group,
    # equivalent to passing one `flagOp*` call via `ops` instead. flagOp*'s
    # own (multi-spelling) `variants` list never allows this suffix -- see
    # FlagVariantFormat.
    flag <- ^ (shortFlag / longFlag) (op value)? $
    shortFlag <- {'-' \w}
    longFlag <- {'--' \w (\w / ('-' \w))+}
    op <- {equals / (\W? equals)}
    equals <- '=' / ':'
    value <- {.*}
  """

proc newSpecSettings*(width = terminalWidth(), maxVariantsWidth = DefaultMaxVariantsWidth,
    envDelim = DefaultEnvDelim, configSources: seq[ConfigSource] = @[],
    strictOptions = DefaultStrictOptions): SpecSettings =
  ## Creates a `SpecSettings` for `newSpec`/`parse*`/`parseOrQuit*`'s `settings`
  ## param.
  ## - `width` is the column width usage/help text wraps at. Defaults to the
  ##   caller's detected terminal width or 80 columns when none can be
  ##   detected (e.g., piped output with `COLUMNS` unset). Pass an explicit
  ##   width to opt out of auto-detection.
  ## - `maxVariantsWidth` caps the variants column's width before it wraps
  ##   onto extra indented lines (`0` for unlimited).
  ## - `envDelim` is the delimiter an env-configured Option/Flag's raw value
  ##   is split on to supply more than one value (`\x1e` is always tried
  ##   first, since that's how fish auto-joins a list variable) -- see
  ##   `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`. A
  ##   single Option/Flag can override this delimiter (or opt out of
  ##   splitting entirely) via `env*`'s two-arg form -- see
  ##   `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  ## - `configSources` is Value Precedence's Config Source tier -- an
  ##   ordered list of `ConfigSource`s (e.g. `iniConfigSource(path)`,
  ##   `jsonConfigSource(path)`, or a custom subclass), consulted in order
  ##   for any Option/Flag declaring a `configKey`. A later source's hit
  ##   fully replaces an earlier one's, never merged. See
  ##   `docs/adr/0018-config-source.md`.
  ##
  ## - `strictOptions` is Strict Option Checking: whether an option-shaped
  ##   token resolving against no declared option may be accepted as data.
  ##   On by default, and it governs two slots. In the common
  ##   `[options] <file>...` shape, off means a typo'd `--recrusive`
  ##   silently becomes a filename; and with any value-taking option, off
  ##   means `--name --help` sets `name` to `"--help"` rather than
  ##   reporting that `--name` has no value. A Non-Option Short -- one dash
  ##   whose second character isn't an ASCII letter (`-5`, `-3.5`,
  ##   `-0x1F`) -- is exempt either way, which is what keeps negative
  ##   numbers usable. Set `false` for a grammar that genuinely takes
  ##   dash-leading literal text, though a typed `--`, a usage-string
  ##   `[--]` marker, the leading-space form (`" -x"`), or the attached
  ##   form (`--name=--nope`) each force one token literally without
  ##   disabling the check everywhere. See
  ##   `docs/adr/0034-strict-option-checking.md`.
  ##
  ## Hold onto the returned `SpecSettings` and pass the same instance to
  ## `command()`'s enclosing `newSpec`/`parse*`/`parseOrQuit*` call to mutate
  ## it later (e.g. from a `before` hook) and have the change apply live to
  ## every not-yet-dispatched `Spec` in the tree -- see
  ## `docs/adr/0013-message-args-fire-after-before.md`.
  SpecSettings(width: width, maxVariantsWidth: maxVariantsWidth, envDelim: envDelim,
    configSources: configSources, strictOptions: strictOptions)

converter toEnvSource*(name: string): options.Option[EnvSource] =
  ## Lets `opt*`/`opts*`/`flag*`'s `env` param be given a plain env var
  ## name (`env = "PORT"`), same as before -- see `env*` for the two-arg
  ## form that also overrides the delimiter.
  some(EnvSource(name: name))

proc env*(name: string, delim: string): options.Option[EnvSource] =
  ## Names an environment variable to supply an arg's value, overriding
  ## the delimiter its raw value is split on for this arg only, instead of
  ## inheriting `Spec.settings.envDelim`. `delim = ""` means never split this
  ## arg's env value at all, even on `\x1e` -- see
  ## `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  some(EnvSource(name: name, delim: some(delim)))

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

proc withUsage*(msg: string, command: string, spec: Spec): string =
  ## `msg` followed by `spec.usage` formatted via `formatUsage` -- the shape
  ## every parse-time failure message uses, whatever exception carries it.
  "{msg}\n\n{spec.usage.formatUsage(command, spec.settings.width)}".fmt

proc raiseParseError*(msg: string) =
  ## Raises `ParseError` with `msg` verbatim, no usage block appended -- use
  ## the `(msg, command, spec)` overload when a usage block should follow.
  raise newException(ParseError, msg)

proc raiseParseError*(msg: string, command: string, spec: Spec) =
  ## Raises `ParseError` with `msg` followed by `spec.usage` formatted via
  ## `formatUsage` -- the shape most parse-time failures use.
  raiseParseError(msg.withUsage(command, spec))

proc name*(self: Arg, variant = ""): string =
  ## Returns the seen name `variant` or the first name of `self` if blank.
  if variant.len > 0: variant else: self.variants[0]

proc seen*(self: Arg): bool =
  ## Whether some Value Precedence tier supplied `self` this parse -- i.e.
  ## `self.seenBy > byNone`. True for a matched Command or Help Arg too,
  ## which carry no value of their own.
  ##
  ## Distinguishes a supplied value from a coded default that happens to
  ## equal it, which reading the Arg alone cannot. Safe to consult from a
  ## `before`/`action`/`after` hook at any depth: both provenance and values
  ## are resolved for the whole matched tree before dispatch starts (see
  ## `docs/adr/0032-parse-all-values-before-dispatch.md`), so an Arg that is
  ## `seen` there already reads its supplied value, even one belonging to a
  ## subcommand this hook's level hasn't descended into yet. See
  ## `docs/adr/0039-per-arg-provenance.md`.
  self.seenBy > byNone

proc subject*(arg: Arg, variant: string, seenBy: options.Option[SeenBy] = none(SeenBy)): string =
  ## How to name `arg` in a parse-failure message. The command line names the
  ## Variant the user actually typed; a fallback tier names `arg` *plus* where
  ## the value came from, so a typo in an env var or a config file doesn't read
  ## as something typed at the prompt. The `env:`/`configKey:` prefixes match
  ## how help text annotates the same two sources.
  ##
  ## Only answerable because `parse` carries the tier -- the variant slot alone
  ## can't say whether it holds a Variant or a source label. Exported for the
  ## same reason as `name` (`docs/adr/0017`): the generated `parse` methods
  ## resolve it by bare name in the caller's module.
  if variant.len == 0 or seenBy.isNone or seenBy.get notin {byConfig, byEnv}:
    return arg.name(variant)
  # `variants[0]` keeps any value placeholder (`--port=<n>`), but every other
  # complaint names the bare option (`--port`) -- so trim with the same PEG
  # spec construction already keys `spec.options` by. Leaves a Positional
  # (`<src>`) or Command untouched, since neither matches it.
  var bare = arg.name
  if bare =~ OptionalVariantFormat:
    bare = matches[0]
  let kind = if seenBy.get == byEnv: "env" else: "configKey"
  "$# ($#: $#)" % [bare, kind, variant]

proc hash*(self: Arg): Hash =
  ## Hash function for args so they can be used as keys in tables.
  hash(self.name)

proc showsMessage*(info: HookInfo): bool =
  ## True if `info.matched` includes a Message Argument (Help or a plain
  ## `message()`/`version()`) -- i.e. this invocation's dispatch will
  ## short-circuit into printing a message and exiting rather than
  ## reaching a real `action`.
  for arg in info.matched:
    if arg of MessageArg:
      return true
  false

method clear*(self: Arg) {.base.} =
  ## Removes the `seenBy` provenance of an arg. Value-carrying args should use
  ## this method to also remove their value, restoring any default.
  self.seenBy = byNone

template arbitrate*(self: Arg, tier: options.Option[SeenBy], eqBody: untyped, gtBody: untyped): untyped =
  ## Arbitrates one contribution at Value Precedence `tier` against `self`'s
  ## current provenance, running whichever body applies. Every `parse`
  ## override routes through this -- it *is* the tier rule, and rewriting it
  ## by hand is how an override silently ends up demoting, or accumulating
  ## where it should reset.
  ##
  ## - **first body** -- `tier` is `none()`, or equal to `self.seenBy`: this
  ##   contribution *extends* what is there, so nothing is cleared and the
  ##   body runs against `self`'s existing value.
  ## - **`do` body** -- `tier` outranks `self.seenBy`: this contribution
  ##   *replaces* what is there. The body runs **before** `self` is cleared,
  ##   so a body that raises leaves `self` untouched, and one that inspects
  ##   `self.value` still sees the values about to be discarded.
  ## - **neither** -- `tier` is weaker than `self.seenBy`: `return`s out of
  ##   the calling scope. `parse` never demotes; call `clear` first to hand
  ##   an Arg back to a weaker tier.
  ##
  ## The parameter is `tier`, not `seenBy`: naming it after the field the
  ## body reads off `self` gensyms over that field wherever this expands
  ## inside another template. See docs/gotchas.md.
  ## See `docs/adr/0041-parse-is-the-write-surface.md`.
  let seen = tier.get(otherwise = self.seenBy)
  if seen < self.seenBy:
    return
  elif seen > self.seenBy:
    gtBody
    self.clear
    self.seenBy = seen
  else:
    eqBody

template arbitrate*(self: Arg, tier: options.Option[SeenBy]): untyped =
  ## `arbitrate` for an Arg with nothing to do on either branch -- it still
  ## skips a weaker tier, and still clears and records on a stronger one.
  arbitrate(self, tier):
    discard
  do:
    discard

method parse*(self: Arg, value: string, variant = "", seenBy: options.Option[SeenBy] = none(SeenBy)) {.base.} =
  ## Called on all seen args after a successful parse. Non-value-carrying args
  ## like `MessageArg` or `CommandArg` only record `seenBy`. Value-carrying
  ## args like `ValueArg` and `FlagArg` also implement this to
  ## convert/validate/store a matched `value` (raw command-line/env/config
  ## string) onto `self` using the variant that matched.
  ##
  ## Overrides must arbitrate through `arbitrate*`.
  self.arbitrate(seenBy)

method action*(self: Arg, command: string, spec: Spec, variant = "") {.base.} =
  ## Fires this Arg's Action -- what a matched Message Argument does in place
  ## of the enclosing Spec's own `action` hook (see `CONTEXT.md`'s Action
  ## entry and `docs/adr/0013-message-args-fire-after-before.md`).
  ##
  ## One signature for every kind, rather than one per what each needs:
  ## `command`/`spec` are what a `HelpArg` uses to render help text, and a
  ## plain `MessageArg` simply ignores them. That is what lets the per-level
  ## message pass dispatch once, with no test for which kind it holds.
  raise newException(Defect, fmt"action() is not defined for {self.name(variant)}")

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

method envSource*(self: Arg): options.Option[EnvSource] {.base.} =
  ## Returns the Env Source configured to supply this arg's value -- the
  ## environment variable's name plus any per-Arg delimiter override -- or
  ## `none` if this arg has no environment-variable tier. Base case
  ## (positional args, commands, message args) has none; `ValueArg`/
  ## `FlagArg` override this per-type via `defineArg`/`defineFlagArg`.
  ##
  ## One method rather than a name/delimiter pair, so the two can't
  ## disagree: a delimiter override with no variable to apply it to is a
  ## meaningless state (see `EnvSource`). Consulted regardless of whether
  ## the arg is required or optional in the usage grammar -- see
  ## `docs/adr/0004-required-options-env-fallback.md` and
  ## `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  none(EnvSource)

proc envName*(self: Arg): string =
  ## The name of the environment variable configured to supply this arg's
  ## value, or `""` if it has no Env Source. Derived from `envSource`
  ## rather than dispatched, so it is not part of the custom-`Arg`
  ## contract -- override `envSource` and this follows. Display- and
  ## label-shaped: it names the source in help text (`env: PORT`) and in
  ## the variant slot of a failing `parse` (see `subject`).
  let source = self.envSource
  if source.isSome: source.get.name else: ""

method configKey*(self: Arg): ConfigKey {.base.} =
  ## Returns the structured path this arg's value is looked up under in
  ## Value Precedence's Config Source tier, or `noConfigKey()` if none
  ## configured.
  ## Base case (positional args, commands, message args) has no notion of
  ## one; `ValueArg`/`FlagArg` override this per-type via
  ## `defineArg`/`defineFlagArg`. See `docs/adr/0018-config-source.md`.
  noConfigKey()

method aliases*(self: Arg, a, b: string): bool {.base.} =
  ## Returns whether `a` and `b` are aliases for `self`. Overridden by
  ## `FlagArg[T]`, which restricts this to FlagOp Aliases (variants sharing
  ## an equivalent Flag Operation). Every call site guarantees `a` and `b`
  ## are both already-declared variants of `self` -- never a foreign string
  ## -- so this doesn't re-derive that from `self.variants`; a plain
  ## (non-Flag) Arg has no notion of FlagOp Aliasing, so any two of its own
  ## variants are unconditionally aliases of one another.
  true
