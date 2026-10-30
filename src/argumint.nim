## `argumint`'s public API: declare a spec as a tuple of `arg`/`args`/`opt`/
## `opts`/`flag`/`command`/`help`/`message`/`version` values, then build and
## parse it with `newSpec`/`parse*`/`parseOrQuit*`. A usage string (given
## explicitly or auto-filled from the declared args) is compiled into an FSM
## (`argumint/grammar/specbuild`, `argumint/core/backend`,
## `argumint/grammar/lexer`, `argumint/grammar/parser`) that drives actual
## matching (`argumint/walk/fsm`) -- docopt-style patterns like
## `[-r] <src>... <dest>` or mutually exclusive options fall out of that FSM's
## grammar rather than hand-written validation code.
##
## See the [user guide](guide/index.html) for how to use it, and
## `examples/naval_fate.nim` for a full worked example with subcommands.

{.experimental: "openSym".}

import std/[macros, os, options, pegs, sugar, strutils, terminal]

import ./argumint/[configsource, help]
import ./argumint/core/[backend, envvar, errors, outcome, variant]
import ./argumint/text/[console, style]
import ./argumint/grammar/[dot, specbuild]
import ./argumint/values/[annotationtext, argtypes, flagclamp, validators]
import ./argumint/walk/[completion, fsm]

# Re-exported so `import argumint` alone is enough to catch everything
# `parse*`/`parseOrQuit*`/`newSpec` can raise.
export errors except newPlainError

# Ergonomics, and fixes an openSym resolution bug for custom Arg types --
# see docs/gotchas.md and docs/adr/0017-argumint-reexports-for-custom-arg-types.md.
export validators except styledHelp, seesHistory
export flagclamp except styledHelp
export annotationtext.AnnotationText, annotationtext.toAnnotationText
export configsource
export backend.name

# A `desc`'s `some("")` hides a Help Annotation (`AnnotationText`, see
# issue #12 and ADR 0089), which makes `Option`-construction part of the
# public API surface -- re-exported narrowly (not wholesale `std/options`,
# which would flood the namespace with `map`/`filter`/`flatMap`/... unrelated
# to spec construction), so `import argumint` alone is enough to write
# `desc = some("")`.
#
# The three accessors joined them in #59, when `envSource*` became the first
# exported signature to *return* an `Option` -- reading one back needs them,
# which is ADR 0029's demonstrated-caller bar met.
export options.some, options.none
export options.isSome, options.isNone, options.get

# `before`/`action`/`after` hooks' `info: HookInfo` parameter -- see
# docs/adr/0021-hook-info-matched-args.md.
export backend.HookInfo
export backend.showsMessage

# The core vocabulary types, so a spec can cross a proc or module boundary
# (`var built: Spec`, `proc buildCli(): Spec`) and `HookInfo.matched` can
# actually be inspected (`it.isMessage`, `it.kind == Optional`).
# `State`/`Transition`/`Matcher`/`MatcherKind` are deliberately left out --
# they're FSM plumbing, not API. See
# docs/adr/0030-core-types-exported-spec-opaque.md.
export backend.Spec, backend.SpecSettings
export backend.Arg, backend.ArgKind, backend.CommandArg, backend.MessageArg
export envvar.EnvSource

# Per-Arg provenance: `spec.port.seenBy == byCli`, `spec.verbose.seen`. See
# docs/adr/0039-per-arg-provenance.md.
export backend.SeenBy, backend.seen, backend.seenBy

# What a Spec is built from, read-only: `kind`, `variants` and a command's
# nested `spec`. A Custom Arg sets them with `argumint/customarg.initArg`.
export backend.kind, backend.variants, backend.spec

# `Option` itself, not just `some`/`none` above: `opt*`/`opts*`/`flag*`'s
# `env` param and `EnvSource.delim` are both `Option`-typed, so writing a
# helper that returns one (or spelling `none(EnvSource)` explicitly)
# needs the type nameable.
export options.Option

# `newSpecSettings*`'s defaults, each settable with a `-d:argumint.*`
# define, so readable here too -- see `docs/adr/0053-compile-time-defaults.md`.
export backend.DefaultWidth, backend.DefaultMaxVariantsWidth,
  backend.DefaultMaxWidth, envvar.DefaultEnvDelim, backend.DefaultStrictOptions

# Public API that issue #49 moved out of this file -- `settings =` needs
# `newSpecSettings`, `env = "PORT"` needs `env`/`toEnvSource`, and `subject`
# is reachable by bare name from a generated `parse` method (ADR 0017). The
# plumbing beside them (`beginSpec`/`finishSpec`/`addArgs`, the variant-format
# PEGs) stays out; `tests/test_public_api.nim` holds that line.
export backend.newSpecSettings, envvar.env, envvar.toEnvSource, backend.appName,
  backend.detectWidth, backend.width, backend.`width=`, backend.style,
  backend.`style=`
export specbuild.newSpec

# `parse` lives in `argumint/walk/fsm` rather than here. `parseOrQuit*(Spec)`
# was already reachable (it's defined below), so without it `newSpec` -> `parse`
# was the one broken half of an otherwise-complete pair. Completion's only
# interface is `__complete`'s output, so `resolveCompletion` stays withheld --
# see `docs/adr/0066-completion-falls-back-to-paths.md`.
export fsm.parse
export completion.Shell
export backend.PathCompletion, backend.CompletionContext, backend.Offer,
  backend.CompleterProc, backend.Completer

# The write side of an Arg (#47): `arg.parse(v, seenBy = some(byCli))`
# pre-seeds a value, and `arg.clear()` returns one to its coded default.
# What a Custom Arg overrides is in `argumint/customarg`. See
# `docs/adr/0041-parse-is-the-write-surface.md`.
export backend.parse, backend.clear

# The two Arg types whose machinery issue #51 moved into
# `argumint/values/argtypes`. Only their names travel back here: the private
# fields, the untyped bases, and the `init*`/`raw*` bookends
# the public names below are written against all stay withheld -- see
# `docs/adr/0043-facade-machinery-seam.md`, and `tests/test_public_api.nim`,
# which holds that line.
export argtypes.ValueArg, argtypes.ValuesArg, argtypes.FlagArg, argtypes.FlagOp

# Enough to pick a built-in Help Formatter or declare Long-Form Help Text;
# writing your own formatter needs `import argumint/help` (ADR 0048/0049/0057).
export backend.HelpText, backend.toHelpText
export help.HelpArg, help.HelpFormatter, help.HelpContext, help.formatColumn,
  help.formatParagraph, help.showHelp

# Styling configuration, and enough Styled Text for a custom Arg's
# `validatorHelp`; the span model needs `argumint/help` (ADR 0051).
export style.StyleRole, style.Styler, style.TextStyle, style.Theme,
  style.defaultTheme, style.ansiStyler, style.autoStyler
export style.StyledText, style.styled, style.`&`
export console.wantsColor
export terminal.ForegroundColor, terminal.Style

# ------------------------------------------------------------------------------
# Type write accessors for args.
# ------------------------------------------------------------------------------

proc put*[T: not seq](arg: ValueArg[T] | ValuesArg[T], value: T, seenBy: Option[SeenBy] = none(SeenBy), validate = true) =
  ## Sets (or, in the case of a multi-value arg, adds) `arg`'s value to `value`,
  ## optionally running its validator if `validate` is true; on validation
  ## failure, raises a `ValidationError`. Unlike `parse`, there's no matched
  ## token to name a specific variant with, so the error names `arg`'s own
  ## primary spelling, or the source of a declared `byEnv`/`byConfig` tier
  ## (see `subject`). The arg's value provenance is set to
  ## `seenBy` if `some`; if `none`, keeps the arg's existing provenance.
  putImpl(arg, value, seenBy, validate)

proc put*[T](arg: FlagArg[T], value: T, seenBy: Option[SeenBy] = none(SeenBy)) =
  ## Sets the value of `arg`, always clamping if the arg has a clamp. The
  ## value's provenance is set to `seenBy` if `some`; if `none`, keeps the arg's
  ## existing provenance.
  putImpl(arg, value, seenBy)

proc replace*[T: not seq](arg: ValuesArg[T], values: seq[T], seenBy: Option[SeenBy] = none(SeenBy), validate = true) =
  ## Replaces all values of `arg` with the values in `values`, optionally
  ## running the validator if `validate` is true; on validation failure, raises
  ## a `ValidationError`. The arg's value provenance is set to `seenBy` if
  ## `some`; if `none`, keeps the arg's existing provenance. Unlike `put()`,
  ## this can be used to downgrade an arg's provenance. Both the value
  ## assignment and the provenance update happen after all values are validated.
  ## Similar to calling `clear()` followed by `put()` for each value, except if
  ## `ValidationError` is raised the values and provenance are left untouched.
  replaceImpl(arg, values, seenBy, validate)

# ------------------------------------------------------------------------------
# Convenience functions that allow easy unpacking of values from args.
# ------------------------------------------------------------------------------

template get*[T](arg: ValueArg[T], otherwise: T): T =
  ## Returns `arg`'s parsed value if it holds one, and `otherwise` if it
  ## doesn't -- `arg`'s coded default is ignored, replaced by `otherwise` for
  ## this call site only. Tests the stored value rather than `seen`, so a
  ## tier-less `put`/`parse` (which stores a value but leaves `seenBy`
  ## untouched) is visible here. A `template` so `otherwise` is left
  ## unevaluated on the supplied path; ADR 0040, amended for `put`.
  block:
    let a = arg
    if a.rawValue.isSome: a.rawValue.get else: otherwise

template get*[T](arg: ValuesArg[T], otherwise: seq[T]): seq[T] =
  ## Returns `arg`'s accumulated values if it holds any, even none, and
  ## `otherwise` if it doesn't. See `get*(ValueArg[T], T)`.
  block:
    let a = arg
    if a.rawValue.isSome: a.rawValue.get else: otherwise

proc get*[T](arg: ValueArg[T]): T =
  ## Returns `arg`'s parsed value, substituting its coded default if no Value
  ## Precedence tier supplied one -- the same answer the implicit conversion
  ## gives, spelled explicitly for the places that conversion can't reach
  ## (see `docs/adr/0040-explicit-value-accessor.md`).
  arg.get(otherwise = arg.rawDefault)

proc get*[T](arg: ValuesArg[T]): seq[T] =
  ## Returns `arg`'s accumulated values, substituting its coded default seq if
  ## no Value Precedence tier supplied any. See `get*(ValueArg[T])`.
  arg.get(otherwise = arg.rawDefault)

template get*[T](arg: FlagArg[T], otherwise: T): T =
  ## Returns `arg`'s value if a Value Precedence tier supplied it, and
  ## `otherwise` if none did. See `get*(ValueArg[T], T)`.
  block:
    let a = arg
    if a.seen or arg.rawValue != arg.rawDefault: a.rawValue else: otherwise

proc get*[T](arg: FlagArg[T]): T =
  ## Returns `arg`'s value. See `get*(ValueArg[T])`.
  arg.rawValue

converter toT*[T](arg: ValueArg[T]): T =
  ## Converts a `ValueArg[T]` to a `T`, substituting a default value if
  ## no value was set by the user. Delegates to `get*`, which is the same
  ## read spelled explicitly.
  arg.get

converter toSeqT*[T](arg: ValuesArg[T]): seq[T] =
  ## Converts a `ValuesArg[T]` to a `seq[T]`, substituting a default
  ## value if no value was set by the user. Delegates to `get*`.
  arg.get

converter toT*[T](arg: FlagArg[T]): T =
  ## Converts a `FlagArg[T]` to a `T`. Delegates to `get*`.
  arg.get

# ------------------------------------------------------------------------------
# Completers
# ------------------------------------------------------------------------------

proc offer*(values: openArray[string], paths = PathCompletion.None,
    patterns: openArray[string] = []): Offer =
  ## A Completer's answer: `values` as candidates, with the shell adding
  ## `paths` beside them. With `paths = Files`, `patterns` limits the files
  ## to those whose name matches one, as `files` does. See
  ## `docs/adr/0071-runtime-completers.md`.
  var described: seq[tuple[value, help: string]]
  for v in values:
    described.add (v, "")
  initOffer(described, paths, @patterns)

proc offer*(values: openArray[(string, string)], paths = PathCompletion.None,
    patterns: openArray[string] = []): Offer =
  ## A Completer's answer: each `(value, help)` pair as a candidate whose
  ## help shells that show descriptions (fish, zsh) put beside it, with the
  ## shell adding `paths`, filtered by `patterns`, beside them.
  initOffer(@values, paths, @patterns)

proc files*(patterns: varargs[string]): Completer =
  ## A Completer offering directories, and the files whose name matches one
  ## of `patterns`, such as `files("*.toml", "*.ini")`; with none, every
  ## file, as `Files` does. A pattern may use `*`, `?`, `[...]` and
  ## `[!...]`, and is case-sensitive. A tab or newline in one is a Defect.
  ## See `docs/adr/0072-file-completion-patterns.md`.
  initCompleter(offer(newSeq[string](), PathCompletion.Files, patterns))

converter toCompleter*(paths: PathCompletion): Completer =
  ## A Completer offering just `paths`, so `complete = Dirs` reads as a
  ## `PathCompletion`.
  initCompleter(offer(newSeq[string](), paths))

converter toCompleter*[P: proc](fn: P): Completer =
  ## A Completer running `fn`, with earlier values filled first. Generic
  ## because a proc literal capturing nothing is `{.nimcall.}`, and a
  ## converter won't chain a second implicit conversion -- see
  ## `docs/gotchas.md`.
  when not compiles(CompleterProc(fn)):
    {.error: "a completer is a proc (ctx: CompletionContext): Offer".}
  initCompleter(CompleterProc(fn))

proc `$`*(c: Completer): string =
  ## Names `c`'s kind. Without it, `$` on a field of a Completer turns the
  ## proc in it back into a Completer and recurses -- see `docs/gotchas.md`.
  if c.isDefault: "Completer(default)"
  elif c.fills: "Completer(proc)"
  else: "Completer(fixed)"

# ------------------------------------------------------------------------------
# Arg constructors
# ------------------------------------------------------------------------------

proc arg*[T: not seq](variants: string, default: T = zeroValue[T](),
    help: HelpText = "", group = "", hidden = false,
    validator: Validator[T] = noValidator[T](),
    complete = default(Completer)): ValueArg[T] =
  ## Creates a positional argument with a value of type `T`. If given, `default`
  ## can be used to infer `T`; otherwise, `T` defaults to `string` (see the
  ## bare-call overload below) unless set explicitly -- e.g. `arg[int]("<n>")`.
  ## - `variants` is a comma-separated list of names by which the argument is
  ##   presented to the user. These must take the form `<arg>`.
  ## - `default` is the default value of the argument if not given by the
  ##   user; defaults to `T`'s zero value (`default(T)`, e.g. `""`, `0`, or
  ##   `false`), a range type's lowest value if that excludes zero, or an
  ##   enum's lowest member. Help shows it unless it equals that fallback;
  ##   an enum's always shows, since its fallback is a real choice.
  ## - `help` is the argument's Help Text, shown in help messages: a string,
  ##   or a `(short, long)` pair whose `long` Paragraph Style prefers -- see
  ##   `docs/adr/0049-help-text-short-long-pair.md`.
  ## - `group` determines how arguments are grouped in help messages; empty
  ##   means `Arguments`.
  ## - `hidden`, if `true`, keeps the arg out of help messages and shell
  ##   completion; it still parses.
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
  ## - `complete` is how shell completion offers the value: a
  ##   `CompleterProc` run at each Tab, a `PathCompletion` (`Files`, with
  ##   directories to descend into, `Dirs`, or `None`), or `files` with
  ##   patterns. By default it offers `validator`'s values if it lists any,
  ##   otherwise files -- see `docs/adr/0071-runtime-completers.md`.
  initValueArg[T](kind = Positional, variants = variants, default = default,
    help = help, group = group, hidden = hidden, validator = validator,
    complete = complete)

proc arg*(variants: string, default: string = "", help: HelpText = "",
    group = "", hidden = false,
    validator: Validator[string] = noValidator[string](),
    complete = default(Completer)): ValueArg[string] =
  ## Bare-call convenience for `arg[string]` -- lets `T` default to `string`
  ## without an explicit bracket (e.g. `arg("<name>")`). See `arg[T]` above
  ## for full parameter docs.
  arg[string](variants, default, help, group, hidden, validator, complete)

proc args*[T: not seq](variants: string, default: seq[T] = @[],
    help: HelpText = "", group = "", hidden = false,
    validator: Validator[T] = noValidator[T](),
    complete = default(Completer)): ValuesArg[T] =
  ## Creates a positional argument which takes multiple values of type `T`.
  ## If given, `default` can be used to infer `T`; otherwise, `T` defaults to
  ## `string` (see the bare-call overload below) unless set explicitly.
  ## - `variants` is a comma-separated list of names by which the argument is
  ##   presented to the user. These must take the form `<arg>`.
  ## - `default` is the default value(s) of the argument if not given by the
  ##   user; defaults to an empty seq.
  ## - `group` determines how arguments are grouped in help messages; empty
  ##   means `Arguments`.
  ##
  ## `help`, `hidden`, `validator` (run on each value) and `complete` are as
  ## on `arg[T]`.
  initValuesArg[T](kind = Positional, variants = variants, default = default,
    help = help, group = group, hidden = hidden, validator = validator,
    complete = complete)

proc args*(variants: string, default: seq[string] = @[], help: HelpText = "",
    group = "", hidden = false,
    validator: Validator[string] = noValidator[string](),
    complete = default(Completer)): ValuesArg[string] =
  ## Bare-call convenience for `args[string]` -- lets `T` default to `string`
  ## without an explicit bracket (e.g. `args("<src>")`). See `args[T]` above
  ## for full parameter docs.
  args[string](variants, default, help, group, hidden, validator, complete)

proc opt*[T: not seq](variants: string, default: T = zeroValue[T](),
    help: HelpText = "", group = "", hidden = false,
    validator: Validator[T] = noValidator[T](),
    env: Option[EnvSource] = none(EnvSource),
    configKey: ConfigKey = noConfigKey(),
    complete = default(Completer)): ValueArg[T] =
  ## Creates an optional argument with a value of type `T`. If given, `default`
  ## can be used to infer `T`; otherwise, `T` defaults to `string` (see the
  ## bare-call overload below) unless set explicitly -- e.g. `opt[int]("-n")`.
  ## - `variants` is a comma-separated list of names by which the option is
  ##   presented to the user. These must take the form `-o` or `--option` and
  ##   may optionally include a help var (e.g., `--option=<value>`).
  ## - `default` is the default value of the option if not given by the
  ##   user; defaults to `T`'s zero value (`default(T)`, e.g. `""`, `0`, or
  ##   `false`), a range type's lowest value if that excludes zero, or an
  ##   enum's lowest member. Help shows it unless it equals that fallback;
  ##   an enum's always shows, since its fallback is a real choice.
  ## - `group` determines how options are grouped in help messages; empty
  ##   means `Options`.
  ## - `env` optionally names an environment variable supplying this
  ##   option's value when none is given on the command line (a CLI value
  ##   always wins), converted/validated the same way. Applies whether the
  ##   option is required or optional. An option matched more than once
  ##   can take multiple env values, split on `Spec.settings.envDelim` -- see
  ##   `docs/adr/0004-required-options-env-fallback.md` and
  ##   `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`. A
  ##   plain string names the env var alone; `env("NAME", delim)` also
  ##   overrides the delimiter for this option only (`delim = ""` disables
  ##   splitting entirely) -- see
  ##   `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  ## - `configKey` optionally names a structured path (e.g.
  ##   `configKey("Package", "name")`, or a bare string for a 1-segment path)
  ##   supplying this option's value from a registered Config Source when
  ##   neither a CLI nor an env value is given -- consulted below env in Value
  ##   Precedence, above the coded default. See
  ##   `docs/adr/0018-config-source.md`.
  ##
  ## `help`, `hidden`, `validator` and `complete` are as on `arg[T]`.
  initValueArg[T](kind = Optional, variants = variants, default = default,
    help = help, group = group, hidden = hidden, validator = validator,
    env = env, cfgKey = configKey, complete = complete)

proc opt*(variants: string, default: string = "", help: HelpText = "",
    group = "", hidden = false,
    validator: Validator[string] = noValidator[string](),
    env: Option[EnvSource] = none(EnvSource),
    configKey: ConfigKey = noConfigKey(),
    complete = default(Completer)): ValueArg[string] =
  ## Bare-call convenience for `opt[string]` -- lets `T` default to `string`
  ## without an explicit bracket (e.g. `opt("--name")`). See `opt[T]` above
  ## for full parameter docs.
  opt[string](variants, default, help, group, hidden, validator, env, configKey, complete)

proc opts*[T: not seq](variants: string, default: seq[T] = @[],
    help: HelpText = "", group = "", hidden = false,
    validator: Validator[T] = noValidator[T](),
    env: Option[EnvSource] = none(EnvSource),
    configKey: ConfigKey = noConfigKey(),
    complete = default(Completer)): ValuesArg[T] =
  ## Creates an optional argument which takes multiple values of type `T`.
  ## If given, `default` can be used to infer `T`; otherwise, `T` defaults to
  ## `string` (see the bare-call overload below) unless set explicitly.
  ## - `variants` is a comma-separated list of names by which the option is
  ##   presented to the user. These must take the form `-o` or `--option` and
  ##   may optionally include a help var (e.g., `--option=<value>`).
  ## - `default` is the default value(s) of the option if not given by the
  ##   user; defaults to an empty seq.
  ## - `group` determines how options are grouped in help messages; empty
  ##   means `Options`.
  ##
  ## `env` and `configKey` are as on `opt[T]`: an env value splits on
  ## `Spec.settings.envDelim` into as many values as this option's
  ## position(s) can consume -- see
  ## `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`. `help`,
  ## `hidden`, `validator` (run on each value) and `complete` are as on
  ## `arg[T]`.
  initValuesArg[T](kind = Optional, variants = variants, default = default,
    help = help, group = group, hidden = hidden, validator = validator,
    env = env, cfgKey = configKey, complete = complete)

proc opts*(variants: string, default: seq[string] = @[], help: HelpText = "",
    group = "", hidden = false, validator: Validator[string] = noValidator[string](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey(),
    complete = default(Completer)): ValuesArg[string] =
  ## Bare-call convenience for `opts[string]` -- lets `T` default to `string`
  ## without an explicit bracket (e.g. `opts("--src")`). See `opts[T]` above
  ## for full parameter docs.
  opts[string](variants, default, help, group, hidden, validator, env, configKey, complete)

proc flagOp*[T](variants: string, op: static string, value: T, help = ""): FlagOp[T] =
  ## Declares a named Flag Operation for `flag*`'s `ops` param. Every
  ## spelling in `variants` runs it, and each is a FlagOp Alias of the
  ## others.
  ## - `variants` is a comma-separated list of bare spellings (`-f`/
  ##   `--flag`).
  ## - `op` is `"="` (set to `value`), `"+="`, `"-="` or `"*="`. `x += value`
  ##   uses `T`'s own `+=` if it has one, and otherwise `x = x + value`; so
  ##   for a set, `+=`, `-=` and `*=` are union, difference and
  ##   intersection. An op `T` can't do is a compile error.
  ## - `value` is the value the operation applies.
  ## - `help` replaces the generated description shown in help text (e.g.
  ##   "Increase by 5").
  ##
  ## On a number, `+=`, `-=` and `*=` stop at `T`'s bounds rather than
  ## overflowing; a range type stops at its own.
  const error = opError[T](op)
  when error.len > 0: {.error: error.}
  initFlagOp(variants, op, value, help)

proc flagOp*[T](variants: string, apply: proc (value: var T), help = ""): FlagOp[T] =
  ## Declares a Flag Operation that runs `apply` on the flag's value, for
  ## `flag*`'s `ops` param. `help` is its description in help text; with
  ## none, it shows none. See `flagOp` above for `variants`, and
  ## `flagOpIt` for the short form.
  initFlagOp(variants, apply, help)

template flagOpIt*[T](variants: string, expr: untyped, help = ""): FlagOp[T] =
  ## Declares a Flag Operation that sets the flag's value to `expr`, in
  ## which `it` is the value it had: `flagOpIt[int]("--double", it * 2)`.
  ## See `flagOp` above.
  flagOp[T](variants, proc (value: var T) =
    let it {.inject.} = value
    value = expr, help)

proc flag*[T](variants: string = "", ops: varargs[FlagOp[T]] = @[],
    default: T = zeroValue[T](), help: HelpText = "", group = "",
    hidden = false, clamp: FlagClamp[T] = noClamp[T](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): FlagArg[T] =
  ## Constructs a new flag, an optional argument that does not take a value and
  ## instead changes value based on the seen variant. If given, `default` can
  ## be used to infer `T`; otherwise, `T` defaults to `bool` (see the bare-call
  ## overload below) unless set explicitly -- e.g. `flag[int]("--boost")`.
  ## - `variants` is a comma-separated list of bare spellings (`-f`/
  ##   `--flag`) that run `T`'s Implicit Operation: a `bool` is set to the
  ##   opposite of `default`, an integer increases by 1, and an enum moves
  ##   to its next declared value, each stopping at its type's last value.
  ##   Every spelling here is a FlagOp Alias of every other. Any other type
  ##   takes no spellings here: spec construction raises `SpecDefect`.
  ## - `ops` optionally declares more Flag Operations, each with its own
  ##   spellings, built with `flagOp*` or `flagOpIt*`, e.g. `ops =
  ##   [flagOp("-b, --boost", "+=", 5, "Boost by 5")]`. Two different
  ##   `flagOp`s are always independently reachable, even if they do the
  ##   same thing -- see `docs/adr/0027-flag-op-declarations.md`.
  ## - `default` is the default value of the flag if not given by the user;
  ##   defaults to `T`'s zero value (`default(T)`, e.g. `false` or `0`), or a
  ##   range type's lowest value if that excludes zero.
  ## - `group` determines how flags are grouped in help messages; empty
  ##   means `Options`.
  ## - `clamp` optionally attaches a `FlagClamp` (`argumint/values/flagclamp`),
  ##   silently adjusting this flag's value after every Flag Operation, or
  ##   after a `validator` accepts a value (see the overload below) --
  ##   never raises, unlike a `Validator`. `default` must already satisfy
  ##   `clamp`, or spec
  ##   construction raises `SpecDefect` -- see
  ##   `docs/adr/0016-flag-clamp.md`.
  ## - `env` is as on `opt[T]`, except that each env value names a Flag
  ##   Operation, which applies: one of the flag's own declared Variants
  ##   (e.g. `--verbose`), or else a value an `=` op sets (`2` for
  ##   `flagOp("--level2", "=", 2)`) or, for a `bool`, `true` or `false`
  ##   (`default` resets it). Anything else raises `ConversionError`,
  ##   unless the overload below's `validator` allows it. See
  ##   `docs/adr/0085-flag-env-and-config-values.md`.
  ## - `configKey` optionally names a structured path supplying this
  ##   flag's value from a registered Config Source when none is given on
  ##   the command line or via env -- each value names a Flag Operation,
  ##   same as `env`. Consulted below env in Value Precedence, above the
  ##   coded default. See `docs/adr/0018-config-source.md`.
  ##
  ## `help` and `hidden` are as on `arg[T]`.
  initFlagArg[T](variants = variants, ops = ops, default = default,
    help = help, group = group, hidden = hidden, clamp = clamp,
    env = env, cfgKey = configKey)

proc flag*[T](variants: string = "", ops: string, default: T = zeroValue[T](),
    help: HelpText = "", group = "", hidden = false,
    clamp: FlagClamp[T] = noClamp[T](), env: Option[EnvSource] = none(EnvSource),
    configKey: ConfigKey = noConfigKey()): FlagArg[T] =
  ## Convenience overload: `ops` as a comma-separated string of
  ## `<flag><op><value>` entries (e.g. `"--quiet=0, --boost+=5,
  ## --dampen-=2"`), each the same as a `flagOp*` call with one spelling.
  ## `<op>` is `=`, `+=`, `-=` or `*=`; one `T` can't do raises `SpecDefect`.
  ## `<value>` is read as an `arg[T]`'s would be, or for a `set[E]` as one
  ## `E`. Several spellings, a proc, or a type with no converter from
  ## string need the array form. See `flag[T]`
  ## above for full parameter docs, and
  ## `docs/adr/0028-flag-ops-string-convenience.md` for why this is a
  ## separate overload rather than folded into `variants` itself.
  flag[T](variants, parseFlagOpsString[T](ops), default, help, group, hidden, clamp, env, configKey)

proc flag*[T](variants: string = "", ops: varargs[FlagOp[T]] = @[],
    default: T = zeroValue[T](), help: HelpText = "", group = "",
    hidden = false, clamp: FlagClamp[T] = noClamp[T](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey(),
    validator: Validator[T]): FlagArg[T] =
  ## `flag[T]` above, plus a `validator` that lets an env or config value
  ## be any value it allows, not only a Variant or what an `=` op sets, e.g.
  ## `flag[int]("--level", ops = [...], env = "LEVEL", validator =
  ## range(0..5))`. A value no Flag Operation names is converted as an
  ## `opt[T]`'s would be, checked by `validator`, then assigned as by `=`,
  ## and `clamp` applies after. A value that doesn't convert raises
  ## `ConversionError`, and one `validator` rejects `ValidationError`. A
  ## command-line Variant is unchanged, and `default` isn't checked.
  ##
  ## Spec construction raises `SpecDefect` if an `=` op sets a value
  ## `validator` rejects, if `validator` is or contains a `checkSeen`,
  ## `checkSeenIt` or `unique` (a flag holds one value), or if there's
  ## neither `env` nor `configKey` for it to check. `T` can't be `string`,
  ## since any text would convert, or `bool`, which already takes `true` and
  ## `false`. A `distinct` string, or a type whose converter accepts any
  ## text, compiles, but stores a mistyped Variant as its value. See
  ## `docs/adr/0086-flag-validator.md`.
  requireValidatedFlagType(T)
  initFlagArg[T](variants = variants, ops = ops, default = default,
    help = help, group = group, hidden = hidden, clamp = clamp,
    env = env, cfgKey = configKey, validator = validator)

proc flag*[T](variants: string = "", ops: string, default: T = zeroValue[T](),
    help: HelpText = "", group = "", hidden = false,
    clamp: FlagClamp[T] = noClamp[T](), env: Option[EnvSource] = none(EnvSource),
    configKey: ConfigKey = noConfigKey(), validator: Validator[T]): FlagArg[T] =
  ## `flag[T]`'s `ops: string` overload, plus a `validator` as on the
  ## overload above.
  requireValidatedFlagType(T)
  flag[T](variants, parseFlagOpsString[T](ops), default, help, group, hidden, clamp, env,
    configKey, validator)

proc flag*(variants: string = "", ops: varargs[FlagOp[bool]] = @[],
    default: bool = false, help: HelpText = "", group = "",
    hidden = false, clamp: FlagClamp[bool] = noClamp[bool](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): FlagArg[bool] =
  ## Bare-call convenience for `flag[bool]` -- lets `T` default to `bool`
  ## without an explicit bracket (e.g. `flag("--verbose")`). See `flag[T]`
  ## above for full parameter docs.
  flag[bool](variants, ops, default, help, group, hidden, clamp, env, configKey)

proc flag*(variants: string = "", ops: string, default: bool = false,
    help: HelpText = "", group = "", hidden = false,
    clamp: FlagClamp[bool] = noClamp[bool](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): FlagArg[bool] =
  ## Bare-call convenience for `flag[bool]`'s `ops: string` overload --
  ## lets `T` default to `bool` without an explicit bracket. See `flag[T]`
  ## above for full parameter docs.
  flag[bool](variants, ops, default, help, group, hidden, clamp, env, configKey)

proc command*[S](variants: string, spec: S, help: HelpText = "",
    prolog = "", epilog = "", usage = "", group = "", hidden = false,
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil): CommandArg =
  ## - `variants` is a comma-separated list of names by which the command can be
  ##   called by the user.
  ## - `spec` is a spec tuple representing all possible args this command takes.
  ## - `help` is the command's Help Text, as on `arg[T]`.
  ## - `prolog` is the front matter for help messages generated for this
  ##   command. Use this to provide a detailed description of the command's
  ##   purpose.
  ## - `epilog` is the end matter for help messages generated for this command.
  ## - `usage` is the usage string that controls how the command's args can be
  ##   invoked.
  ## - `group` determines how this command is grouped in help messages;
  ##   empty means `Commands`.
  ## - `hidden` is as on `arg[T]`.
  ## - `before` fires once this command's own `spec`'s values are parsed
  ## - `action` fires after `before`, but only if this command is the dynamic
  ##   leaf (no nested command was also matched)
  ## - `after` fires after this command's own `before`/`action`/nested dispatch.
  ## - Each hook receives `info: HookInfo`, a view of every Arg matched
  ##   during this whole invocation (not just this command's own level) --
  ##   e.g. `info.showsMessage` to skip expensive hook work for a
  ##   `--help`/`--version`/message request. See
  ##   `docs/adr/0021-hook-info-matched-args.md`.
  ##
  ## For more information on how before/action/after hooks are used, see
  ## `docs/adr/0009-command-before-action-after-hooks.md`.
  ##
  ## Note: `settings` is deliberately not a parameter here: it cascades down
  ## by reference from whatever the top-level `newSpec`/`parse*` call is
  ## given, so it only needs to be specified once regardless of how deeply
  ## nested this command is.
  result = CommandArg(help: help, group: group.groupOr(ArgKind.Command),
    hidden: hidden)
  result.initBase(ArgKind.Command, splitVariants(variants))
  result.setSpec(newSpec(spec, usage, prolog, epilog))
  if not before.isNil:
    result.spec.before = (info: HookInfo) => before(spec, info)
  if not action.isNil:
    result.spec.action = (info: HookInfo) => action(spec, info)
  if not after.isNil:
    result.spec.after = (info: HookInfo) => after(spec, info)

proc command*[S, O](variants: string, spec: S, options: O, help: HelpText = "",
    prolog = "", epilog = "", usage = "", group = "", hidden = false,
    before: proc(spec: S, opts: O, info: HookInfo) = nil,
    action: proc(spec: S, opts: O, info: HookInfo) = nil,
    after: proc(spec: S, opts: O, info: HookInfo) = nil): CommandArg =
  ## - `options` is a generic extra-context passthrough, not necessarily
  ##   CLI-options-shaped data -- typically the caller's enclosing/parent spec
  ##   tuple (or any other context object), so a nested command's hooks can
  ##   read outer/global state that `spec: S` alone -- scoped to just this
  ##   command's own tuple -- wouldn't otherwise expose. Each hook receives
  ##   it as `opts`, between `spec` and `info`.
  ##
  ## Every other parameter is as on `command[S]`.
  command(variants, spec, help, prolog, epilog, usage, group, hidden,
    before = if before.isNil: nil else: (proc(cmdSpec: S, info: HookInfo) = before(spec, options, info)),
    action = if action.isNil: nil else: (proc(cmdSpec: S, info: HookInfo) = action(spec, options, info)),
    after = if after.isNil: nil else: (proc(cmdSpec: S, info: HookInfo) = after(spec, options, info)))

proc help*(variants = "-h, --help", help: HelpText = "Display this help message",
    group = "", hidden = false, formatter: HelpFormatter = formatColumn): HelpArg =
  ## Creates a flag which, when matched, displays an auto-generated help message
  ## for the spec in whose context it was called.
  ## - `variants` is a comma-separated list of names by which the flag is
  ##   presented to the user. These must take the form `-o` or `--option`.
  ## - `group` determines how the flag is grouped in help messages; empty
  ##   means `Options`.
  ##
  ## `help` and `hidden` are as on `arg[T]`.
  result = HelpArg(help: help, group: group.groupOr(Flag), hidden: hidden,
    formatter: formatter)
  result.initBase(Flag, splitVariants(variants))

proc message*(variants: string, text: string, help: HelpText = "",
    group = "", hidden = false): MessageArg =
  ## Creates a flag which, when matched, displays `text` and exits
  ## successfully instead of parsing further arguments.
  ## - `variants` is a comma-separated list of names by which the flag is
  ##   presented to the user. These must take the form `-o` or `--option`.
  ## - `text` is the message to display when the flag is matched.
  ## - `group` determines how the flag is grouped in help messages; empty
  ##   means `Options`.
  ##
  ## `help` and `hidden` are as on `arg[T]`.
  result = MessageArg(message: text, help: help, group: group.groupOr(Flag),
    hidden: hidden)
  result.initBase(Flag, splitVariants(variants))

proc version*(variants: string, version: string,
    help: HelpText = "Display version information",
    group = "", hidden = false): MessageArg =
  ## Thin wrapper around `message` for the common case of a version flag.
  ## - `variants` is a comma-separated list of names by which the flag is
  ##   presented to the user. These must take the form `-v` or `--version`.
  ## - `version` is the message to display when the flag is matched.
  ## - `group` determines how the flag is grouped in help messages; empty
  ##   means `Options`.
  ##
  ## `help` and `hidden` are as on `arg[T]`.
  message(variants, version, help, group, hidden)

type
  ShellArg = ref object of ValueArg[Shell]
    ## `completion`'s `<shell>`: a Message Argument printing the root Spec's
    ## completion script for the shell typed. See
    ## `docs/adr/0074-built-in-completion-command.md`.

method isMessage(self: ShellArg): bool = true

method action(self: ShellArg, info: HookInfo, variant = "") =
  raise newException(MessageError,
    genCompletionScript(self.get, info.root.command))

const CompletionProlog = """
Print a shell completion script for this program. Load it with one of:

  source <(prog completion bash)
  source <(prog completion zsh)
  prog completion fish | source

where `prog` is this program's name."""

proc completion*(variants = "completion",
    help: HelpText = "Print a shell completion script",
    prolog = CompletionProlog, epilog = "", group = "",
    hidden = false): CommandArg =
  ## Creates a command which, given a shell, prints the completion script
  ## for the whole program and exits successfully, like `help`. Add it to
  ## the program's own spec as `completion: completion()`; the user then
  ## runs `prog completion fish | source`. The script completes the
  ## `command` given to `parse*`/`parseOrQuit*`. See
  ## `docs/adr/0074-built-in-completion-command.md`.
  ## - `variants` is a comma-separated list of names by which the command can
  ##   be called by the user.
  ## - `prolog` and `epilog` head and end the command's own help message.
  ## - `group` determines how the command is grouped in help messages; empty
  ##   means `Commands`.
  ##
  ## `help` and `hidden` are as on `arg[T]`. To write the script at build or
  ## install time instead, see `completionScript`.
  # `<shell>` is required, so `default` is never used.
  let shell = initValueArg(ShellArg, kind = Positional, variants = "<shell>",
    default = Shell.bash, help = "The shell to complete in")
  command(variants, (shell: shell, help: help()), help, prolog, epilog,
    group = group, hidden = hidden)

# ------------------------------------------------------------------------------
# Building a Spec Tuple
# ------------------------------------------------------------------------------

type SpecField = tuple[name, node: NimNode]
  ## A `specTuple` field: its name, and its expression or its type.

proc indexOf(fields: seq[SpecField], name: NimNode): int =
  ## The index of the field named `name` in `fields`, or -1.
  result = -1
  for i, field in fields:
    if field.name.eqIdent(name): return i

proc specFields(body: NimNode): seq[SpecField] =
  ## The fields of a `specTuple` body, each with its expression.
  for line in body:
    if line.kind == nnkCommentStmt: continue
    if line.kind != nnkCall or line.len != 2 or
        line[0].kind notin {nnkIdent, nnkAccQuoted} or
        line[1].kind != nnkStmtList or line[1].len != 1:
      error("specTuple: each line must be `name: expr`",
        if line.kind == nnkCall: line[0] else: line)
    if result.indexOf(line[0]) >= 0:
      error("specTuple: field `" & $line[0] & "` is named twice", line[0])
    result.add (name: line[0], node: line[1][0])

proc tupleFields(t: NimNode): seq[SpecField] =
  ## The fields of the named tuple `t` is typed as, each with its type, or
  ## `@[]` for anything else.
  let impl = t.getTypeImpl
  if impl.kind == nnkTupleTy:
    for defs in impl:
      for name in defs[0 ..^ 3]:
        result.add (name: name, node: defs[^2])

proc copiedField(source, name: NimNode): NimNode =
  ## The tuple-constructor field `name: source.name`.
  newColonExpr(ident($name), newDotExpr(source, ident($name)))

macro mergeSpecTuple(base, body: typed): untyped =
  ## `specTuple(base)`'s flat tuple, from `base` and the tuple its body
  ## describes. The field order is ADR 0084's.
  let
    baseFields = tupleFields(base)
    bodyFields = tupleFields(body)
  if baseFields.len == 0:
    error("specTuple: the base must be a tuple with named fields", base)
  proc keepsSlot(field: SpecField): bool =
    let i = baseFields.indexOf(field.name)
    i >= 0 and sameType(baseFields[i].node, field.node)
  result = newNimNode(nnkTupleConstr, body)
  for field in bodyFields:
    if not field.keepsSlot: result.add copiedField(body, field.name)
  for field in baseFields:
    let i = bodyFields.indexOf(field.name)
    if i < 0: result.add copiedField(base, field.name)
    elif bodyFields[i].keepsSlot: result.add copiedField(body, field.name)

# One `varargs` macro, not an overload per form: see docs/gotchas.md.
macro specTuple*(args: varargs[untyped]): untyped =
  ## Builds a spec from a list of `name: expr` fields, one per line, with no
  ## commas between them:
  ##
  ## ```nim
  ## let
  ##   global = specTuple:
  ##     verbose: flag("-v, --verbose", help = "Talk more")
  ##     help: help()
  ##   convert = specTuple(global):
  ##     branch: opt("--branch=<branch>")
  ##   config = specTuple(global):
  ##     help: help(formatter = formatParagraph)
  ## ```
  ##
  ## With no base, `specTuple` gives the tuple its fields describe, the same
  ## as writing `(verbose: ..., help: ...)`. It works inline too:
  ## `command("test", specTuple do: ...)`.
  ##
  ## Given a base tuple, `specTuple(base)` gives a flat tuple of every field
  ## of `base` plus the body's fields, so `convert.verbose` works. The
  ## copied fields are the base's own Args, so after parsing,
  ## `convert.verbose` and `global.verbose` read the same value. A body
  ## field named like a base field replaces it. Only the top level is
  ## copied: a field of `base` that is itself a tuple stays nested. `base`
  ## is evaluated once.
  ##
  ## The fields' order sets the order of their Args and groups in help:
  ## - The body's fields come first, in body order, along with any
  ##   replacement whose type differs from the base field's.
  ## - The base's fields come next, in base order. A replacement of the
  ##   same type takes the base field's place, so `config`'s `--help`
  ##   above sits where `global`'s did.
  ##
  ## See `docs/adr/0084-spec-tuple-macro-flattens-a-base.md`.
  if args.len == 0 or args[^1].kind != nnkStmtList:
    error("specTuple: expected a body of `name: expr` lines", args)
  if args.len > 2:
    error("specTuple: expected at most one base before the body", args[1])
  let body = args[^1]
  result = newNimNode(nnkTupleConstr, body)
  for field in specFields(body):
    result.add newColonExpr(field.name, field.node)
  if args.len == 2:
    let
      base = genSym(nskLet, "base")
      fields = genSym(nskLet, "fields")
      merged = newCall(bindSym"mergeSpecTuple", base, fields)
    base.copyLineInfo(args[0])
    result = newStmtList(newLetStmt(base, args[0]), newLetStmt(fields, result),
      merged)

# ------------------------------------------------------------------------------
# Visiting a Spec Tuple's Args
# ------------------------------------------------------------------------------

# A wrapper, not an `export`, so it shows on this module's doc page.
template eachArg*(spec: tuple, name, arg, body: untyped) =
  ## Runs `body` once for each Arg `newSpec(spec)` registers, with `name`
  ## bound to its field name and `arg` to the field, with its own type:
  ##
  ## ```nim
  ## spec.eachArg(name, arg):
  ##   when arg is ValueArg:
  ##     if arg.seen: echo name, " = ", arg.get
  ## ```
  ##
  ## - It goes into nested tuples, in field order. An unnamed tuple's
  ##   fields are named `Field0`, `Field1`, ...
  ## - An Arg reached more than once is visited once, under the field name
  ##   where it's first reached.
  ## - A Command is visited, but its own spec's Args are not.
  ## - Message Arguments (`help()`, `version()`, ...) are visited.
  ## - `break` ends the walk and `continue` skips to the next Arg. Inside a
  ##   loop, block or nested `eachArg` that `body` opens, they keep their
  ##   usual meaning.
  ##
  ## A member of `spec` that is neither an Arg nor a tuple is a compile
  ## error. See the guide's
  ## [Visiting Every Arg](guide/specs.html#visiting-every-arg) and
  ## `docs/adr/0087-each-arg-mirrors-registration.md`.
  specbuild.eachArg(spec, name, arg, body)

# ------------------------------------------------------------------------------
# These are the functions that handle shell completion and initiate parsing.
# ------------------------------------------------------------------------------

proc isCompletionRequest*(args: seq[string] = commandLineParams()): bool =
  ## Returns whether `args` is a shell-completion request (see
  ## `docs/adr/0012-fsm-driven-shell-completion.md`) -- i.e. whether calling
  ## `parse*`/`parseOrQuit*` with these same `args` would short-circuit into
  ## completion handling rather than a real run.
  ##
  ## Each completion request re-invokes the binary as a fresh process, so
  ## setup code run *before* `parse*`/`parseOrQuit*` (config loading, a DB
  ## connection) reruns on every keystroke, not just real invocations --
  ## unlike `before`/`action`/`after` hooks, which are already skipped
  ## during completion. Guard expensive pre-parse setup with this:
  ## ```nim
  ## when isMainModule:
  ##   if isCompletionRequest():
  ##     spec.parse(...)          # skip straight past expensive setup
  ##   else:
  ##     setupDatabaseConnection()
  ##     spec.parse(...)
  ## ```
  args.hasCompletionMarker

proc quitWith(e: ref Exception, styler: Styler) {.noreturn.} =
  ## Prints `e`'s `outcome` and quits with its code.
  let o = outcome(e, styler)
  (if o.toStderr: stderr else: stdout).writeLine(o.text)
  quit(o.code)

proc parseOrQuit*(spec: Spec, args: seq[string] = commandLineParams(), command = appName()) =
  ## Like `parse*(Spec)`, but prints a message and `quit()`s instead of
  ## raising on failure -- intended for a bare CLI `main()`, not for
  ## embedding in a larger program. Help, `message()`/`version()` text, and
  ## completion candidates go to stdout with `QuitSuccess`; parse and
  ## validation errors go to stderr with `QuitFailure`.
  ##
  ## `spec` is **single-use**, same as `parse*(Spec)` -- and, being a built
  ## `Spec` rather than a spec tuple, it has no `parsed*` counterpart. Build
  ## a fresh one per parse. See
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  try:
    spec.parse(args, command)
  except ParseError, MessageError:
    quitWith(getCurrentException(), spec.settings.style)

proc buildAndBind[S: tuple](spec: S, usage, prolog, epilog: string, settings: SpecSettings,
    before, action, after: proc(spec: S, info: HookInfo)): Spec =
  ## Builds `spec` and binds whichever hooks were given, each closing over
  ## `spec` itself. Shared by all four tuple entry points so a hook can
  ## never be bound to a different tuple than the one its caller returns --
  ## see docs/adr/0031-parsed-fresh-spec-per-parse.md.
  result = newSpec(spec, usage, prolog, epilog, settings)
  if not before.isNil: result.before = (info: HookInfo) => before(spec, info)
  if not action.isNil: result.action = (info: HookInfo) => action(spec, info)
  if not after.isNil: result.after = (info: HookInfo) => after(spec, info)

proc parseOrQuit*[S: tuple](spec: S, usage = "", prolog = "", epilog = "",
    settings = newSpecSettings(),
    args: seq[string] = commandLineParams(), command = appName(),
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil) =
  ## Like `parse*(tuple)`, but prints a message and `quit()`s instead of
  ## raising on failure -- intended for a bare CLI `main()`, not for
  ## embedding in a larger program.
  ##
  ## Every parameter is as on `parse*(tuple)`.
  ##
  ## `spec` is **single-use**: parsing more than once accumulates into the
  ## same Args rather than starting fresh. Use `parsedOrQuit*` to parse a
  ## fresh spec per call -- see
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  try:
    spec.buildAndBind(usage, prolog, epilog, settings, before, action, after)
      .parseOrQuit(args, command)
  except SpecDefect as e:
    quitWith(e, settings.style)

proc parse*[S: tuple](spec: S, usage = "", prolog = "", epilog = "",
    settings = newSpecSettings(),
    args: seq[string] = commandLineParams(), command = appName(),
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil) =
  ## Builds `spec` into a `Spec` via `newSpec` and parses `args` against it in
  ## one step. Raises `SpecDefect` (malformed spec), `ParseError` or a
  ## subtype (parse failure), or `MessageError` or a subtype (help, a
  ## message, or completion) -- use `parseOrQuit*` if you want those to
  ## print a message and `quit()` instead.
  ## - `usage` is the usage string used to build the FSM. See
  ##   `docs/architecture.md`'s "Auto-filled usage" section for how gaps in
  ##   `usage` are auto-filled.
  ## - `prolog` is the front matter for help messages generated from this spec.
  ## - `epilog` is the end matter for help messages generated from this spec.
  ## - `settings` is the `SpecSettings` the whole tree shares -- see
  ##   `newSpecSettings`. Shared by reference with every nested subcommand's
  ##   spec; mutating it later (e.g. from a `before` hook) applies live
  ##   throughout the tree.
  ## - `args` is the command-line arguments to parse using the spec.
  ## - `command` is the name of the binary to use in help messages.
  ## - `before` fires once this `spec`'s own values are parsed
  ## - `action` fires after `before`, but only if this spec is the dynamic leaf
  ##   (no nested command was matched)
  ## - `after` fires after this spec's own `before`/`action`/nested dispatch.
  ## - Each hook receives `info: HookInfo`, a view of every Arg matched
  ##   during this whole invocation -- e.g. `info.showsMessage` to skip
  ##   expensive hook work for a `--help`/`--version`/message request. See
  ##   `docs/adr/0021-hook-info-matched-args.md`.
  ##
  ## `before`/`action`/`after` are app-level hooks around the
  ## whole parse -- see `docs/adr/0009-command-before-action-after-hooks.md`.
  ##
  ## `spec` is **single-use**: parsing more than once accumulates into the
  ## same Args rather than starting fresh -- a repeated `opts` appends, a
  ## `flag` keeps applying its Flag Operation, and an `opt` retains an
  ## earlier value into a later parse that never mentioned it. Use `parsed*`
  ## to parse a fresh spec per call -- see
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  spec.buildAndBind(usage, prolog, epilog, settings, before, action, after)
    .parse(args, command)

# ------------------------------------------------------------------------------
# `parsed*`/`parsedOrQuit*`: parse a *fresh* spec and return it, leaving the
# caller's own untouched -- see docs/adr/0031-parsed-fresh-spec-per-parse.md.
# ------------------------------------------------------------------------------

proc parsed*[S: tuple](build: proc (): S, usage = "", prolog = "", epilog = "",
    settings = newSpecSettings(),
    args: seq[string] = commandLineParams(), command = appName(),
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil): S =
  ## Calls `build` for a brand-new spec tuple, parses `args` into it, and
  ## returns it. Every other parameter behaves exactly as on `parse*(tuple)`,
  ## which this raises like.
  ##
  ## Unlike `parse*`/`parseOrQuit*`, which accumulate into the Args they're
  ## given, this makes a parse a pure function of `args` -- so the same
  ## `build` can be parsed any number of times, each result independent:
  ## ```nim
  ## proc buildCli(): auto =
  ##   (name: arg("<name>"), times: opt("-t=<n>", default = 1), help: help())
  ##
  ## for line in stdin.lines:
  ##   let cli = parsed(buildCli, args = line.splitWhitespace, command = "repl")
  ##   echo cli.name
  ## ```
  ## Values for a Command's own nested spec are reachable only through that
  ## Command's `before`/`action`/`after` hooks, not off the returned tuple:
  ## a spec tuple holds a `CommandArg`, not the nested tuple itself.
  ##
  ## Takes a builder rather than a spec tuple deliberately -- copying an
  ## already-built tuple can't be made correct, see
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  result = build()
  result.buildAndBind(usage, prolog, epilog, settings, before, action, after)
    .parse(args, command)

proc parsedOrQuit*[S: tuple](build: proc (): S, usage = "", prolog = "", epilog = "",
    settings = newSpecSettings(),
    args: seq[string] = commandLineParams(), command = appName(),
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil): S =
  ## Like `parsed*`, but prints a message and `quit()`s instead of raising
  ## on failure -- the `parseOrQuit*`/`parse*` distinction, unchanged.
  try:
    result = build()
    result.buildAndBind(usage, prolog, epilog, settings, before, action, after)
      .parseOrQuit(args, command)
  except SpecDefect as e:
    quitWith(e, settings.style)

proc dot*(spec: Spec): string =
  ## Renders `spec`'s FSM as a Graphviz dot graph, useful for debugging or
  ## visualizing how a usage string is parsed. For a subcommand, use
  ## `cmdArg.spec.dot`.
  spec.fsm.dot

proc dot*(spec: tuple, usage = "", prolog = "", epilog = ""): string =
  ## Compiles `spec` and renders its FSM as a Graphviz dot graph. See
  ## `dot(Spec)` for details.
  try:
    newSpec(spec, usage, prolog, epilog).dot
  except SpecDefect as e:
    quitWith(e, nil)

proc completionScript*(spec: Spec, shell: Shell, binaryName = appName()): string =
  ## Returns a shell-completion script for `shell` that completes
  ## `binaryName` by shelling out to it (`<binaryName> __complete
  ## <words...>`) -- see `docs/adr/0012-fsm-driven-shell-completion.md`.
  ## The script is the same for every `spec`, since the binary resolves
  ## completion itself at request time. Author-driven, like `dot*`: install
  ## the result however your packaging needs (write it to a file, expose a
  ## `completion` subcommand, etc.) -- argumint doesn't wire this up
  ## automatically.
  genCompletionScript(shell, binaryName)
