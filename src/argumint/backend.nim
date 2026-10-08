## The FSM's data model (`Spec`, `Arg` and its subtypes, `State`,
## `Transition`, `Matcher`) shared by `argumint/lexer`, `argumint/parser`,
## and `argumint/fsm`, plus the `{.base.}` methods (`parse*`, `envName*`,
## `configKey*`, ...) a custom `Arg` subtype must override to plug into
## parsing, env fallback, and Config Source lookup -- see
## `docs/adr/0017-argumint-reexports-for-custom-arg-types.md`. `ValueArg`/
## `ValuesArg`/`FlagArg` (`argumint/argtypes`) are the built-in
## implementations of that interface. The graph-construction/simplification
## operations that build and mutate `State`/`Matcher` values live in
## `argumint/fsmgraph`, not here.
##
## Alongside the model sit the pieces that belong beside it rather than in
## spec construction (`argumint/specbuild`): the constructors for the types
## declared here that never read a usage string (`newSpecSettings`), the
## PEGs a Variant string must match, and `subject`, which names an Arg in a
## parse-failure message. See `docs/architecture.md` for where that line
## falls and why. The env tier's types live in `argumint/envvar`.

import std/[hashes, options, os, pegs, strformat, strutils, tables]

import ./[configsource, console, envvar, errors, style]
export configsource, envvar
export console.DefaultWidth, console.DefaultMaxWidth, console.chooseWidth,
  console.detectWidth


type
  ArgKind* {.pure.} = enum
    Command
      ## A subcommand (e.g., `clone`)
    Positional
      ## A positional argument (e.g., `<arg>`)
    Optional
      ## An optional argument that takes a value (e.g., `-o value` or
      ## `--option value`)
    Flag
      ## An optional argument that takes no value (e.g., `-f` or `--flag`)

  PathCompletion* {.pure.} = enum
    ## Which paths shell completion offers for a value with no enumerable
    ## values of its own -- see
    ## `docs/adr/0066-completion-falls-back-to-paths.md`.
    Files
      ## Files, and directories to descend into
    Dirs
      ## Directories only
    None
      ## No paths

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

  Arbitration* = enum
    ## What one contribution at a Value Precedence tier does to an Arg,
    ## judged against its current provenance -- see `arbitration*`. A
    ## weaker tier is refused, so it has no member.
    arExtend ## Same tier, or none declared: add to what is there
    arReplace ## A stronger tier: clear what is there, then store

  Contribution* = object
    ## One value offered to an Arg by one Value Precedence tier (`CONTEXT.md`).
    value*: string
      ## The raw string to convert; for a Flag, the Variant whose Flag
      ## Operation applies, whichever tier supplied it.
    variant*: string
      ## The Variant typed on the command line, or `""` if none was.
    tier*: Option[SeenBy]
      ## The tier declared for it; `none` extends at the Arg's current tier.

  HelpText* = tuple[short, long: string]
    ## An Arg's Help Text and optional Long-Form Help Text (`""` if none) --
    ## see `docs/adr/0049-help-text-short-long-pair.md`.

  Arg* = ref object of RootObj
    kind*: ArgKind
    variants*: seq[string]
      ## The forms in which the argument may appear
    help*: HelpText
      ## The argument's Help Text (`short`) and optional Long-Form Help Text
      ## (`long`); Paragraph Style prefers `long` when declared -- see
      ## `docs/adr/0049-help-text-short-long-pair.md`.
    group*: string
      ## The group where the argument should appear in help messages
    hidden*: bool
      ## Whether the arg is kept out of help messages and shell completion
    complete*: PathCompletion
      ## Which paths completion offers for this Arg's value, unless it has
      ## enumerable values -- see
      ## `docs/adr/0066-completion-falls-back-to-paths.md`.
    seenBy*: SeenBy
      ## Which Value Precedence tier supplied this Arg -- written by `parse`
      ## right after `accept` stores the value, so provenance can never outrun
      ## the value it describes. `byNone` is the zero value, so an unsupplied
      ## Arg is correct with no code on the default path. See `seen*` and ADR 0039.

  CommandArg* = ref object of Arg
    spec*: Spec

  MessageArg* = ref object of Arg
    message*: string

  SpecSettings* = ref object
    width: int
      ## `0` until the `width` getter first detects it
    maxVariantsWidth*: int
      ## Max width of the help text's variants column before wrapping; 0 means
      ## unlimited
    envDelim*: string
      ## Delimiter an env-configured Option/Flag's raw env value is split on,
      ## unless it has its own `EnvSource.delim` (see `envvar.splitEnvValue`)
    configSources*: seq[ConfigSource]
      ## Value Precedence's Config Source tier, consulted in order -- a later
      ## source's hit for the same Arg fully replaces an earlier one's, never
      ## merged (see `lookupConfigSources`)
    strictOptions*: bool
      ## Strict Option Checking: whether an option-shaped token may be accepted
      ## as data, in both a positional slot and an Option's value slot. Default
      ## `true`; a Non-Option Short (`-5`, `-0x1F`) is always exempt. See
      ## `docs/adr/0034-strict-option-checking.md`
    style: Styler
      ## `autoStyler` until the `style` getter first resolves it
    theme: Theme
      ## What an `autoStyler` style resolves to colour with

  HookInfo* = object
    matched*: seq[Arg]
      ## Every Arg matched during this invocation, across every spec level in
      ## the dispatch chain (not just the receiving hook's own level) -- a view
      ## onto `fsm.nim`'s internal `MatchTable` computed once from the walk
      ## `parse*` already performs, not a re-walk. E.g.
      ## `info.matched.anyIt(it of MessageArg)` (or `showsMessage(info)` below)
      ## to detect a Message/Help request from a `before` hook and skip
      ## expensive setup for it -- see
      ## `docs/adr/0021-hook-info-matched-args.md`.

  Spec* = ref object
    ## An opaque handle to a built command-line spec: name it, pass it around,
    ## hand it back to `parse*`/`parseOrQuit*`/`dot*`/ `completionScript*`.
    ## Every field below that isn't marked `*` is argumint's own bookkeeping,
    ## deliberately unreachable from outside the library -- see
    ## `docs/adr/0030-core-types-exported-spec-opaque.md`.
    prolog: string
      ## Front matter for a help message
    epilog: string
      ## Back matter for a help message
    usage: string
      ## Usage string used to build the FSM for parsing
    args: seq[Arg]
      ## List of all args known to this spec
    commands: OrderedTable[string, CommandArg]
      ## Maps command variants to args
    arguments: OrderedTable[string, Arg]
      ## Maps positional arg variants to args
    options: OrderedTable[string, Arg]
      ## Maps option and flag arg variants to args
    groups: OrderedTable[string, seq[Arg]]
      ## List of args in each group
    fsm: State
      ## The initial state for the FSM used for parsing
    settings*: SpecSettings
      ## Shared by reference with every nested subcommand's Spec -- mutating it
      ## (e.g. from a `before` hook) affects every not-yet-dispatched Spec in
      ## the tree, including this one's own message/help output (see
      ## `docs/adr/0013-message-args-fire-after-before.md`)
    before*: proc (info: HookInfo)
      ## Fires once this spec's own values are parsed, before dispatch descends
      ## into any Command matched at this spec's own level
    action*: proc (info: HookInfo)
      ## Fires once this spec's own values are parsed, only if this spec is the
      ## dynamic leaf (no nested Command matched)
    after*: proc (info: HookInfo)
      ## Fires once this spec's own before/action/nested dispatch has run,
      ## whether it succeeded or raised

  State* = ref object
    ## The basic building block of the FSM. A state can be final or not and has
    ## transitions to other states.
    terminal*: bool
    transitions*: seq[Transition]

  Transition* = ref object
    ## If a transition's matcher matches, the next state can be reached.
    matcher*: Matcher
    next*: State

  # Declaration order doubles as match priority (`priority`/ `sortTransitions`).
  MatcherKind* {.pure.} = enum
    mkOption, mkOptions, mkCommand, mkArgument, mkOptsEnd, mkShortcut

  Matcher* = ref object
    ## A `ref` so a Matcher created for a `[options]` atom (see `parser.atom`'s
    ## `tkAnyOption` branch) can be patched in place after the fact -- once
    ## the whole Usage Line is parsed and `explicitOptions` is final --
    ## regardless of how many times its surrounding `Transition` gets copied
    ## by `sequence`'s local `add` helper as composition proceeds (see
    ## `docs/gotchas.md`). A value-type `Matcher` would make every such copy
    ## independent, silently discarding the patch.
    case kind*: MatcherKind
    of mkArgument:
      arg*: Arg
    of mkOption:
      opt*: Arg
      variant*: string
    of mkOptions:
      opts*: seq[Arg]
      variants*: seq[string]
    of mkCommand:
      cmd*: CommandArg
    else:
      discard

# Each `Default*` below can be overridden at compile time with its
# `-d:argumint.*` define -- see `docs/adr/0053-compile-time-defaults.md`.
const
  DefaultMaxVariantsWidth* {.intdefine: "argumint.maxVariantsWidth".} = 30
    ## `newSpecSettings`'s default `maxVariantsWidth`. Set with
    ## `-d:argumint.maxVariantsWidth`.
  DefaultStrictOptions* {.booldefine: "argumint.strictOptions".} = true
    ## `newSpecSettings`'s default `strictOptions` -- see
    ## `docs/adr/0034-strict-option-checking.md`. Set with
    ## `-d:argumint.strictOptions`.

static:
  doAssert DefaultMaxVariantsWidth >= 0,
    "-d:argumint.maxVariantsWidth must be 0 (unlimited) or more, got " &
    $DefaultMaxVariantsWidth

# The comma separator every `variants`/`ops` string is split on, and the
# formats an `arg`/`opt`/`flag` Variant string must match. Exported for
# siblings (spec construction, `subject`, the Arg constructors, the
# `ValueArg`/`FlagArg` machinery in `argumint/argtypes`) but never
# re-exported by the facade -- reachable only via `import argumint/backend`,
# like everything else internal here.
let
  Comma* = peg"\s* ',' \s*"

  PositionalVariantFormat* = peg"""
    # Allows you to capture <arg> or ARG
    argument <- ^ {angled / upper} $
    angled <- '<' \w (\w / ('-' \w))* '>'
    upper <- [A-Z0-9] ([A-Z0-9] / ([_-] [A-Z0-9]))*
  """

  OptionalVariantFormat* = peg"""
    # Allows you to capture [-o, var] / [--option, var] in -o=<var> /
    # --option=<var>, or VAR in place of <var>
    option <- ^ (shortOption / longOption) (equals helpVar)? $
    equals <- '=' / ':'
    shortOption <- {'-' \w}
    longOption <- {'--' \w (\w / ('-' \w))+}
    helpVar <- ('<' {\w (\w / ('-' \w))*} '>') / {upper}
    upper <- [A-Z0-9] ([A-Z0-9] / ([_-] [A-Z0-9]))*
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

func defaultGroup*(kind: ArgKind): string =
  ## The help group an Arg of `kind` goes in when its `group` is empty.
  case kind
  of ArgKind.Command: "Commands"
  of ArgKind.Positional: "Arguments"
  of ArgKind.Optional, ArgKind.Flag: "Options"

func groupOr*(group: string, kind: ArgKind): string =
  ## `group`, or `kind`'s `defaultGroup` if it's empty.
  if group.len > 0: group else: kind.defaultGroup

proc appName*(): string =
  ## The running binary's file name, minus any `.exe` -- the default `command`
  ## naming the program in usage lines and completion scripts.
  result = getAppFilename().extractFilename
  when ExeExt.len > 0:
    if result.toLowerAscii.endsWith("." & ExeExt):
      result.setLen(result.len - ExeExt.len - 1)

proc newSpecSettings*(width = 0,
    maxVariantsWidth = DefaultMaxVariantsWidth,
    envDelim = DefaultEnvDelim, configSources: seq[ConfigSource] = @[],
    strictOptions = DefaultStrictOptions, style: Styler = autoStyler,
    theme = defaultTheme): SpecSettings =
  ## Creates a `SpecSettings` for `newSpec`/`parse*`/`parseOrQuit*`'s `settings`
  ## param. Every default below can be changed at compile time with a
  ## `-d:argumint.*` define -- see `docs/adr/0053-compile-time-defaults.md`.
  ## - `width` is the column width usage/help text wraps at. `0` (the
  ##   default) detects it on first read: the terminal's width, capped at
  ##   `DefaultMaxWidth` (100) so help doesn't sprawl on a wide terminal, or
  ##   `DefaultWidth` (80) when none can be detected (e.g., piped output with
  ##   `COLUMNS` unset). An explicit width is used as given: `width =
  ##   detectWidth()` for no cap, or `width = min(detectWidth(), 120)` for
  ##   your own.
  ## - `maxVariantsWidth` caps the variants column's width before it wraps
  ##   onto extra indented lines (`0` for unlimited).
  ## - `envDelim` is the delimiter an env-configured Option/Flag's raw value
  ##   is split on to supply more than one value (`" "` suits a list fish
  ##   exports) -- see
  ##   `docs/adr/0005-env-supplied-multi-value-options-and-flags.md` and
  ##   `docs/adr/0064-no-record-separator-env-split.md`. A single Option/Flag
  ##   can override this delimiter (or opt out of splitting entirely) via
  ##   `env*`'s two-arg form -- see
  ##   `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  ## - `configSources` is Value Precedence's Config Source tier -- an
  ##   ordered list of `ConfigSource`s (e.g. `iniConfigSource(path)`,
  ##   `jsonConfigSource(path)`, or a custom subclass), consulted in order
  ##   for any Option/Flag declaring a `configKey`. A later source's hit
  ##   fully replaces an earlier one's, never merged. See
  ##   `docs/adr/0018-config-source.md`.
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
  ## - `style` decorates help and parse-error output (colour, bold, etc.) by
  ##   Style Role. `autoStyler` (the default) resolves it on first read: the
  ##   built-in ANSI theme when output is going to a terminal, else plain.
  ##   Pass `nil` for plain text always, or `ansiStyler(theme)` or your own
  ##   `Styler` to colour always. To change the colours but keep detection,
  ##   pass `theme` instead. See `docs/adr/0051-help-and-error-styling.md`.
  ## - `theme` is the colours `autoStyler` uses when it colours output. It
  ##   only matters while `style` is `autoStyler`; for your own `Styler`,
  ##   check `wantsColor()` yourself. See
  ##   `docs/adr/0067-theme-keeps-colour-detection.md`.
  ##
  ## Neither default touches the terminal here, so building settings (or a
  ## Spec) never probes it; only reading `width` or `style` does, which help
  ## and error rendering do just before printing. See
  ## `docs/adr/0058-lazy-terminal-detection.md`.
  ##
  ## Hold onto the returned `SpecSettings` and pass the same instance to
  ## `command()`'s enclosing `newSpec`/`parse*`/`parseOrQuit*` call to mutate
  ## it later (e.g. from a `before` hook) and have the change apply live to
  ## every not-yet-dispatched `Spec` in the tree -- see
  ## `docs/adr/0013-message-args-fire-after-before.md`.
  SpecSettings(width: width, maxVariantsWidth: maxVariantsWidth, envDelim: envDelim,
    configSources: configSources, strictOptions: strictOptions, style: style,
    theme: theme)

proc width*(s: SpecSettings): int =
  ## The column width usage/help text wraps at. A `0` is detected here, on
  ## first read, and kept: `detectWidth()` capped at `DefaultMaxWidth`.
  if s.width == 0: s.width = resolvedWidth()
  s.width

proc `width=`*(s: SpecSettings, width: int) =
  ## Sets the wrap width; `0` has the next read detect it again.
  s.width = width

proc style*(s: SpecSettings): Styler =
  ## Decorates help and error output by Style Role; nil for plain text. An
  ## `autoStyler` is resolved here, on first read, and kept -- so nothing
  ## probes the terminal until output is rendered. See
  ## `docs/adr/0058-lazy-terminal-detection.md`.
  if s.style == autoStyler: s.style = resolvedStyler(s.theme)
  s.style

proc `style=`*(s: SpecSettings, style: Styler) =
  ## Sets the styler; `autoStyler` has the next read resolve it again.
  s.style = style

# Read-only views of private `Spec` fields (ADR 0030). Only `specbuild` writes
# them. `prolog`/`epilog`/`usage` are re-exported by `argumint/help` for Help
# Formatters (ADR 0048); none are re-exported by the facade.
proc prolog*(spec: Spec): string =
  ## Front matter for `spec`'s help message.
  spec.prolog

proc epilog*(spec: Spec): string =
  ## Back matter for `spec`'s help message.
  spec.epilog

proc usage*(spec: Spec): string =
  ## `spec`'s raw usage string, one alternative per line.
  spec.usage

proc args*(spec: Spec): lent seq[Arg] {.inline.} =
  ## Every Arg declared on `spec`, in declaration order.
  spec.args

proc commands*(spec: Spec): lent OrderedTable[string, CommandArg] {.inline.} =
  ## Maps each command variant to its Arg.
  spec.commands

proc arguments*(spec: Spec): lent OrderedTable[string, Arg] {.inline.} =
  ## Maps each positional arg variant to its Arg.
  spec.arguments

proc options*(spec: Spec): lent OrderedTable[string, Arg] {.inline.} =
  ## Maps each option and flag variant to its Arg.
  spec.options

proc groups*(spec: Spec): lent OrderedTable[string, seq[Arg]] {.inline.} =
  ## Maps each help group to its Args, in declaration order.
  spec.groups

proc fsm*(spec: Spec): State {.inline.} =
  ## The initial state of `spec`'s FSM.
  spec.fsm

converter toHelpText*(s: string): HelpText =
  ## Lets `argumint.nim`'s arg constructors pass help text as a single string.
  (short: s, long: "")

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

proc metavars*(arg: Arg): seq[string] =
  ## The value placeholder names in `arg`'s variants, without brackets (`kn`
  ## for `--speed=<kn>`), for Help Markup to tell a metavar from a
  ## positional in `arg`'s own help text.
  for variant in arg.variants:
    var m: array[2, string]
    if variant.match(OptionalVariantFormat, m) and m[1].len > 0 and m[1] notin result:
      result.add m[1]

proc hash*(self: Arg): Hash =
  ## Hash function for args so they can be used as keys in tables.
  hash(self.name)

proc hash*(self: State): Hash =
  ## Identity hash, matching `ref`'s default `==`; see docs/gotchas.md.
  ## Remove it once `nimPreviewHashRef` is Nim's default.
  hash(cast[pointer](self))

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

proc arbitration*(self: Arg, tier: Option[SeenBy]): Option[Arbitration] =
  ## The tier rule: what a contribution at `tier` does to `self`, or `none`
  ## when `tier` is weaker than `self.seenBy` and is refused. A `none` tier
  ## extends at whatever tier is current. `parse` never demotes; call
  ## `clear` first to hand an Arg back to a weaker tier. Every write routes
  ## through this -- restating the rule by hand is how a write silently
  ## demotes, or accumulates where it should reset. See
  ## `docs/adr/0041-parse-is-the-write-surface.md`.
  let seen = tier.get(otherwise = self.seenBy)
  if seen < self.seenBy: none(Arbitration)
  elif seen > self.seenBy: some(arReplace)
  else: some(arExtend)

method accept*(self: Arg, c: Contribution, how: Arbitration) {.base.} =
  ## Converts, validates and stores `c` onto `self` -- the one thing a
  ## value-carrying Arg overrides. `parse` has already arbitrated: `how` says
  ## whether `c` extends what is there or replaces it. An override checks `c`
  ## first (against the stored history on `arExtend`, against none on
  ## `arReplace`), then on `arReplace` calls `clear` before storing, so a
  ## value that fails leaves `self` untouched. The base stores nothing.
  if how == arReplace:
    self.clear

proc parse*(self: Arg, value: string, variant = "", seenBy: Option[SeenBy] = none(SeenBy)) =
  ## Writes `value` onto `self` at Value Precedence tier `seenBy`: refused if
  ## weaker than `self.seenBy`, appended if equal (or `none`), replacing if
  ## stronger -- see `arbitration*`. `variant` is the Variant typed on the
  ## command line, naming `self` in an error. For a Flag, `value` is the
  ## Variant whose Flag Operation applies. Not overridable: a custom Arg
  ## overrides `accept`, so it can't skip the tier rule. See
  ## `docs/adr/0041-parse-is-the-write-surface.md`.
  let how = self.arbitration(seenBy)
  if how.isNone:
    return
  self.accept(Contribution(value: value, variant: variant, tier: seenBy), how.get)
  if how.get == arReplace:
    self.seenBy = seenBy.get

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

method action(self: MessageArg, command: string, spec: Spec, variant = "") =
  ## Raises `MessageError` with `self.message`, short-circuiting the rest
  ## of parsing so `parse*`/`parseOrQuit*` can deliver it directly (see
  ## `message*`/`version*`).
  raise newPlainError(MessageError, self.message)

method defaultStr*(self: Arg): string {.base.} =
  ## Returns `self`'s default value formatted for display in help text (e.g.
  ## via `[default: <value>]`), or an empty string if there's nothing worth
  ## showing. The base case (commands, flags, and message args) has no
  ## notion of a displayable default; `ValueArg`/`ValuesArg` override it
  ## through their untyped base (`argumint/argtypes`).
  ""

method accumulates*(self: Arg): bool {.base.} = false
  ## Whether `self` builds its value from more than one match (see Match
  ## Accumulation in CONTEXT.md): `args`/`opts` append, flags compose.
  ## `autoFillUsage` writes an accumulating Positional Argument as
  ## `<name>...`, though a usage string that says otherwise still wins, and
  ## a fallback tier gives one that doesn't at most one value (ADR 0005). A
  ## custom subtype that keeps several values overrides it.

method completions*(self: Arg): seq[string] {.base.} = @[]
  ## Returns every value `self` would accept as a *value* (not a variant
  ## spelling), for shell-completion purposes -- or `@[]` if unenumerable or
  ## not applicable. The base case (commands, flags, message args -- none of
  ## which carry a `Validator`) has nothing to show; `ValueArg`/`ValuesArg`
  ## override it through their untyped base (`argumint/argtypes`).

method validatorHelp*(self: Arg): StyledText {.base.} =
  ## Returns a short description of what values `self` accepts (e.g.
  ## `choices: "foo", "bar"`), or empty text if `self` has no `Validator`
  ## or there's nothing meaningful to show. A `desc` gets Help Markup, ticks
  ## and all: help drops them for styled output. The base case (commands and
  ## message args, neither of which has a validator) has nothing to show;
  ## `ValueArg`/`ValuesArg` override it through their untyped base, and
  ## `FlagArg` per type via `defineFlagArg` (`argumint/argtypes`).
  discard

method variantDesc*(self: Arg, variant: string): string {.base.} =
  ## Returns `variant`'s Flag Operation Description (e.g. "Increase by 5"),
  ## or an empty string if there's nothing to disambiguate: every variant of
  ## `self` would be described the same way. Help and completion show any
  ## non-empty result as-is, so an override must keep this rule itself --
  ## see `docs/adr/0063-flag-operation-description-in-completion.md`. The
  ## base case (everything but a flag) has nothing to show; `FlagArg`
  ## overrides this per-type via `defineFlagArg`.
  ""

method envSource*(self: Arg): Option[EnvSource] {.base.} =
  ## Returns the Env Source configured to supply this arg's value -- the
  ## environment variable's name plus any per-Arg delimiter override -- or
  ## `none` if this arg has no environment-variable tier. Base case
  ## (positional args, commands, message args) has none; `ValueArg`/
  ## `ValuesArg` override it through their untyped base, and `FlagArg` per
  ## type via `defineFlagArg`.
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
  ## label-shaped: it names the source in help text (`env: PORT`) and in a
  ## failing `parse`'s error (see `subject`).
  let source = self.envSource
  if source.isSome: source.get.name else: ""

method configKey*(self: Arg): ConfigKey {.base.} =
  ## Returns the structured path this arg's value is looked up under in
  ## Value Precedence's Config Source tier, or `noConfigKey()` if none
  ## configured.
  ## Base case (positional args, commands, message args) has no notion of
  ## one; `ValueArg`/`ValuesArg` override it through their untyped base,
  ## and `FlagArg` per type via `defineFlagArg`. See
  ## `docs/adr/0018-config-source.md`.
  noConfigKey()

proc subjectParts*(arg: Arg, c: Contribution): tuple[name, source: string] =
  ## `subject`'s two halves, for a caller that styles them apart: the name,
  ## and where the value came from (`" (env: PORT)"`, or `""` for the
  ## command line).
  let (kind, label) =
    if c.tier == some(byEnv): ("env", arg.envName)
    elif c.tier == some(byConfig): ("configKey", arg.configKey.join)
    else: ("", "")
  if label.len == 0:
    return (arg.name(c.variant), "")
  # `variants[0]` keeps any value placeholder (`--port=<n>`), but every other
  # complaint names the bare option (`--port`) -- so trim with the same PEG
  # spec construction already keys `spec.options` by. Leaves a Positional
  # (`<src>`) or Command untouched, since neither matches it.
  var bare = arg.name
  if bare =~ OptionalVariantFormat:
    bare = matches[0]
  (bare, " ($#: $#)" % [kind, label])

proc subject*(arg: Arg, c: Contribution): string =
  ## How to name `arg` in a parse-failure message about `c`. The command line
  ## names the Variant the user actually typed; a fallback tier names `arg`
  ## *plus* where the value came from, so a typo in an env var or a config
  ## file doesn't read as something typed at the prompt. The `env:`/
  ## `configKey:` prefixes match how help text annotates the same two
  ## sources, and the label is read off `arg` itself, so a Contribution never
  ## carries one. Exported for the same reason as `name` (`docs/adr/0017`):
  ## the generated `accept` methods resolve it by bare name in the caller's
  ## module.
  let (name, source) = arg.subjectParts(c)
  name & source

method aliases*(self: Arg, a, b: string): bool {.base.} =
  ## Returns whether `a` and `b` are aliases for `self`. Overridden by
  ## `FlagArg[T]`, which restricts this to FlagOp Aliases (variants sharing
  ## an equivalent Flag Operation). Every call site guarantees `a` and `b`
  ## are both already-declared variants of `self` -- never a foreign string
  ## -- so this doesn't re-derive that from `self.variants`; a plain
  ## (non-Flag) Arg has no notion of FlagOp Aliasing, so any two of its own
  ## variants are unconditionally aliases of one another.
  true

when isMainModule:
  import std/unittest

  suite "arbitration":
    test "compares the declared tier with the current one":
      let arg = Arg(variants: @["--port"], seenBy: byEnv)
      check arg.arbitration(some(byConfig)) == none(Arbitration)
      check arg.arbitration(some(byEnv)) == some(arExtend)
      check arg.arbitration(some(byCli)) == some(arReplace)

    test "no declared tier extends at the current one":
      for seen in SeenBy:
        check Arg(variants: @["--port"], seenBy: seen).arbitration(none(SeenBy)) == some(arExtend)

    test "an unsupplied Arg takes any tier":
      let arg = Arg(variants: @["--port"])
      check arg.arbitration(some(byNone)) == some(arExtend)
      check arg.arbitration(some(byConfig)) == some(arReplace)
