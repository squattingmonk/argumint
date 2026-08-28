## `argumint`'s public API: declare a spec as a tuple of `arg`/`args`/`opt`/
## `opts`/`flag`/`command`/`help`/`message`/`version` values, then build and
## parse it with `newSpec`/`parse*`/`parseOrQuit*`. A usage string (given
## explicitly or auto-filled from the declared args) is compiled into an FSM
## (`argumint/specbuild`, `argumint/backend`, `argumint/lexer`,
## `argumint/parser`) that drives actual matching (`argumint/fsm`) --
## docopt-style patterns like `[-r] <src>... <dest>` or mutually exclusive
## options fall out of that FSM's grammar rather than hand-written
## validation code.
##
## See the README for a quickstart and `examples/naval_fate.nim` for a full
## worked example with subcommands. `CONTEXT.md` defines this library's
## vocabulary (Spec, Arg, Variant, Validator, Value Precedence, ...) and
## `docs/architecture.md` traces the spec-construction -> FSM-compilation ->
## runtime-matching -> value-conversion pipeline file by file.

{.experimental: "openSym".}

import std/[importutils, os, options, pegs, sugar, strformat, strutils]

import ./argumint/[argtypes, backend, completion, configsource, dot, errors, flagclamp, fsm, help, specbuild, validators]

privateAccess(Spec) ## Reaches `Spec`'s private fields (ADR 0030) from
  ## non-generic code only -- see `dot*` and docs/gotchas.md.

export completion.Shell

# Re-exported so `import argumint` alone is enough to catch everything
# `parse*`/`parseOrQuit*`/`newSpec` can raise.
export errors

# Ergonomics, and fixes an openSym resolution bug for custom Arg types --
# see docs/gotchas.md and docs/adr/0017-argumint-reexports-for-custom-arg-types.md.
export validators
export flagclamp
export configsource
export backend.name
export strutils.escape

# `clamp`/`adjust`'s `desc: Option[string]` param (argumint/flagclamp, see
# issue #12) makes `Option`-construction part of the public API surface --
# re-exported narrowly (not wholesale `std/options`, which would flood the
# namespace with `isSome`/`get`/`map`/... unrelated to spec construction),
# so `import argumint` alone is enough to write `desc = some("...")`.
export options.some, options.none

# `before`/`action`/`after` hooks' `info: HookInfo` parameter -- see
# docs/adr/0021-hook-info-matched-args.md.
export backend.HookInfo
export backend.showsMessage

# The core vocabulary types, so a spec can cross a proc or module boundary
# (`var built: Spec`, `proc buildCli(): Spec`) and `HookInfo.matched` can
# actually be inspected (`it of MessageArg`, `it.kind == Optional`).
# `State`/`Transition`/`Matcher`/`MatcherKind` are deliberately left out --
# they're FSM plumbing, not API. See
# docs/adr/0030-core-types-exported-spec-opaque.md.
export backend.Spec, backend.SpecSettings
export backend.Arg, backend.ArgKind, backend.CommandArg, backend.MessageArg, backend.HelpArg
export backend.EnvSource

# Per-Arg provenance: `spec.port.seenBy == byCli`, `spec.verbose.seen`. See
# docs/adr/0039-per-arg-provenance.md.
export backend.SeenBy, backend.seen
export fsm.CompletionCandidate

# `Option` itself, not just `some`/`none` above: `opt*`/`opts*`/`flag*`'s
# `env` param and `EnvSource.delim` are both `Option`-typed, so writing a
# helper that returns one (or spelling `none(EnvSource)` explicitly)
# needs the type nameable.
export options.Option

# `newSpecSettings*`'s signature spells these three as its own defaults, so a
# reader of its docs needs to be able to resolve them. `DefaultWidth`
# deliberately isn't here -- it appears in no exported signature, and by
# `docs/adr/0029`'s rule an export with no demonstrated caller stays out
# until one shows up (adding it later is non-breaking).
export backend.DefaultMaxVariantsWidth, backend.DefaultEnvDelim,
  backend.DefaultStrictOptions

# Public API that issue #49 moved out of this file -- `settings =` needs
# `newSpecSettings`, `env = "PORT"` needs `env`/`toEnvSource`, and `subject`
# is reachable by bare name from a generated `parse` method (ADR 0017). The
# plumbing beside them (`beginSpec`/`finishSpec`/`addArgs`, the variant-format
# PEGs) stays out; `tests/test_public_api.nim` holds that line.
export backend.newSpecSettings, backend.env, backend.toEnvSource
export backend.subject
export specbuild.newSpec

# The two operations on a built `Spec` that live in `argumint/fsm` rather
# than here. `parseOrQuit*(Spec)` was already reachable (it's defined
# below), so without these `newSpec` -> `parse` was the one broken half of
# an otherwise-complete pair. `completeArgs*` is what makes the exported
# `CompletionCandidate` usable.
export fsm.parse, fsm.completeArgs

# The write side of an Arg (#47): `arg.parse(v, seenBy = some(byCli))`
# pre-seeds a value, `arg.clear()` returns one to its coded default, and
# `action` is what a `MessageArg`/`HelpArg` overrides. Exported for the same
# reason as `fsm.parse` above -- reaching them shouldn't need a backend
# import. See `docs/adr/0041-parse-is-the-write-surface.md` and
# `docs/adr/0030-core-types-exported-spec-opaque.md`.
export backend.parse, backend.clear, backend.action, backend.arbitrate

# The two Arg types whose machinery issue #51 moved into
# `argumint/argtypes`. Only their names travel back here: the private
# fields, the `define*` method generators, and the `init*`/`raw*` bookends
# the public names below are written against all stay withheld -- see
# `docs/adr/0043-facade-machinery-seam.md`, and `tests/test_public_api.nim`,
# which holds that line.
export argtypes.ValueArg, argtypes.FlagArg, argtypes.FlagOpGroup

# ------------------------------------------------------------------------------
# Registering a custom type. Each of these is the public, documented name for
# one of `argumint/argtypes`'s method generators -- see
# `docs/adr/0017-argumint-reexports-for-custom-arg-types.md`.
# ------------------------------------------------------------------------------

template defineArg*[T](typeName: typedesc[T]): untyped =
  ## Defines parse methods for arguments with a value of type `T`. Use this
  ## version if you want to write your own converter to parse a string into a
  ## `T`.
  defineValueArg typeName

template defineArg*[T](typeName: typedesc[T], flagHandler: untyped): untyped =
  ## Defines parse methods for arguments with a value of type `T`.
  ## `flagHandler` is a code block that is executed to handle an operation on a
  ## `FlagArg[T]` value. Without this block, a `T` cannot be used for a flag.
  ## Within the scope of the handler, the following variables are defined:
  ## - `value: var T`: the flag's value, which can be modified by the handler
  ## - `op: string`: the operation to be performed on `value` (e.g., `+=`)
  ## - `arg: T`: an argument to the operation
  ## Blank-op (`""`) variants show no auto-generated description in help
  ## text; use `defineFlag` to supply one.
  defineFlagArg(typeName, "", flagHandler)

template defineFlag*[T](typeName: typedesc[T], blankDesc: string, flagHandler: untyped): untyped =
  ## Same as `defineArg` above, but also registers `blankDesc` as the
  ## auto-generated help-text description for blank-op (`""`) variants
  ## (e.g. `"Toggle the value"`), since that behavior is type-specific and
  ## can't be inferred from `(op, value)` alone the way `=`/`+=`/`-=` can.
  defineFlagArg(typeName, blankDesc, flagHandler)

template defineSetFlag*[E: enum](elemType: typedesc[E]): untyped =
  ## Registers flag support for `set[E]`. Call once per concrete enum `E`
  ## before declaring `flag[set[E]](...)`, the same way a custom scalar flag
  ## type opts in via `defineArg`/`defineFlag`. Each variant's value names a
  ## single element of `E`:
  ## - `=` sets the value to a set containing only the given element.
  ## - `+=` includes the given element in the set (union).
  ## - `-=` excludes the given element from the set (difference).
  ## - `*=` keeps the given element only if it's already present, dropping
  ##   everything else (intersection).
  defineSetFlagArg elemType

method action(self: MessageArg, command: string, spec: Spec, variant = "") =
  ## Raises `MessageError` with `self.message`, short-circuiting the rest
  ## of parsing so `parse*`/`parseOrQuit*` can deliver it directly (see
  ## `message*`/`version*`).
  raise newException(MessageError, self.message)

method action(self: HelpArg, command: string, spec: Spec, variant = "") =
  ## Raises `HelpError` with `spec`'s generated help text for `command`,
  ## short-circuiting the rest of parsing so `parse*`/`parseOrQuit*` can
  ## deliver it directly (see `help*`).
  raise newException(HelpError, spec.genHelp(command))


# ------------------------------------------------------------------------------
# Type write accessors for args.
# ------------------------------------------------------------------------------

proc put*[T: not seq, multi: static bool](arg: ValueArg[T, multi], value: T, seenBy: Option[SeenBy] = none(SeenBy), validate = true) =
  ## Sets (or, in the case of a multi-value arg, adds) `arg`'s value to `value`,
  ## optionally running its validator if `validate` is true; on validation
  ## failure, raises a `ValidationError`. Unlike `parse`, there's no matched
  ## token to name a specific variant with, so the error names `arg`'s own
  ## primary spelling (`putImpl`'s `variant = ""` falls back to
  ## `arg.variants[0]` via `subject`). The arg's value provenance is set to
  ## `seenBy` if `some`; if `none`, keeps the arg's existing provenance.
  putImpl(arg, value, "", seenBy, validate)

proc put*[T](arg: FlagArg[T], value: T, seenBy: Option[SeenBy] = none(SeenBy)) =
  ## Sets the value of `arg`, always clamping if the arg has a clamp. The
  ## value's provenance is set to `seenBy` if `some`; if `none`, keeps the arg's
  ## existing provenance.
  putImpl(arg, value, seenBy)

proc replace*[T: not seq](arg: ValueArg[T, true], values: seq[T], seenBy: Option[SeenBy] = none(SeenBy), validate = true) =
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

template get*[T](arg: ValueArg[T, false], otherwise: T): T =
  ## Returns `arg`'s parsed value if it holds one, and `otherwise` if it
  ## doesn't -- `arg`'s coded default is ignored, replaced by `otherwise` for
  ## this call site only. Tests the stored value rather than `seen`, so a
  ## tier-less `put`/`parse` (which stores a value but leaves `seenBy`
  ## untouched) is visible here. A `template` so `otherwise` is left
  ## unevaluated on the supplied path; ADR 0040, amended for `put`.
  block:
    let a = arg
    if a.rawValue.len > 0: a.rawValue[0] else: otherwise

template get*[T](arg: ValueArg[T, true], otherwise: seq[T]): seq[T] =
  ## Returns `arg`'s accumulated values if it holds any, and `otherwise` if
  ## it doesn't. See `get*(ValueArg[T, false], T)`.
  block:
    let a = arg
    if a.seen or a.rawValue.len > 0: a.rawValue else: otherwise

proc get*[T](arg: ValueArg[T, false]): T =
  ## Returns `arg`'s parsed value, substituting its coded default if no Value
  ## Precedence tier supplied one -- the same answer the implicit conversion
  ## gives, spelled explicitly for the places that conversion can't reach
  ## (see `docs/adr/0040-explicit-value-accessor.md`).
  arg.get(otherwise = arg.rawDefault[0])

proc get*[T](arg: ValueArg[T, true]): seq[T] =
  ## Returns `arg`'s accumulated values, substituting its coded default seq if
  ## no Value Precedence tier supplied any. See `get*(ValueArg[T, false])`.
  arg.get(otherwise = arg.rawDefault)

template get*[T](arg: FlagArg[T], otherwise: T): T =
  ## Returns `arg`'s value if a Value Precedence tier supplied it, and
  ## `otherwise` if none did. See `get*(ValueArg[T, false], T)`.
  block:
    let a = arg
    if a.seen or arg.rawValue != arg.rawDefault: a.rawValue else: otherwise

proc get*[T](arg: FlagArg[T]): T =
  ## Returns `arg`'s value. See `get*(ValueArg[T, false])`.
  arg.rawValue

converter toT*[T](arg: ValueArg[T, false]): T =
  ## Converts a `ValueArg[T, false]` to a `T`, substituting a default value if
  ## no value was set by the user. Delegates to `get*`, which is the same
  ## read spelled explicitly.
  arg.get

converter toSeqT*[T](arg: ValueArg[T, true]): seq[T] =
  ## Converts a `ValueArg[T, true]` to a `seq[T]`, substituting a default
  ## value if no value was set by the user. Delegates to `get*`.
  arg.get

converter toT*[T](arg: FlagArg[T]): T =
  ## Converts a `FlagArg[T]` to a `T`. Delegates to `get*`.
  arg.get

# ------------------------------------------------------------------------------
# Arg constructors
# ------------------------------------------------------------------------------

proc arg*[T: not seq](variants: string, default: T = default(T), help = "", group = "Arguments", hidden = false, validator: Validator[T] = noValidator[T]()): ValueArg[T, false] =
  ## Creates a positional argument with a value of type `T`. If given, `default`
  ## can be used to infer `T`; otherwise, `T` defaults to `string` (see the
  ## bare-call overload below) unless set explicitly -- e.g. `arg[int]("<n>")`.
  ## - `variants` is a comma-separated list of names by which the argument is
  ##   presented to the user. These must take the form `<arg>`.
  ## - `default` is the default value of the argument if not given by the
  ##   user; defaults to `T`'s zero value (`default(T)`, e.g. `""`, `0`, or
  ##   `false`).
  ## - `help` is a short description of the argument used in help messages.
  ## - `group` determines how arguments are grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
  initValueArg[T, false](kind = Positional, variants = variants, default = @[default],
    help = help, group = group, hidden = hidden, validator = validator)

proc arg*(variants: string, default: string = "", help = "", group = "Arguments", hidden = false, validator: Validator[string] = noValidator[string]()): ValueArg[string, false] =
  ## Bare-call convenience for `arg[string]` -- lets `T` default to `string`
  ## without an explicit bracket (e.g. `arg("<name>")`). See `arg[T]` above
  ## for full parameter docs.
  arg[string](variants, default, help, group, hidden, validator)

proc args*[T: not seq](variants: string, default: seq[T] = newSeq[T](), help = "", group = "Arguments", hidden = false, validator: Validator[T] = noValidator[T]()): ValueArg[T, true] =
  ## Creates a positional argument which takes multiple values of type `T`.
  ## If given, `default` can be used to infer `T`; otherwise, `T` defaults to
  ## `string` (see the bare-call overload below) unless set explicitly.
  ## - `variants` is a comma-separated list of names by which the argument is
  ##   presented to the user. These must take the form `<arg>`.
  ## - `default` is the default value(s) of the argument if not given by the
  ##   user; defaults to an empty seq.
  ## - `help` is a short description of the argument used in help messages.
  ## - `group` determines how arguments are grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
  initValueArg[T, true](kind = Positional, variants = variants, default = default,
    help = help, group = group, hidden = hidden, validator = validator)

proc args*(variants: string, default: seq[string] = @[], help = "", group = "Arguments", hidden = false, validator: Validator[string] = noValidator[string]()): ValueArg[string, true] =
  ## Bare-call convenience for `args[string]` -- lets `T` default to `string`
  ## without an explicit bracket (e.g. `args("<src>")`). See `args[T]` above
  ## for full parameter docs.
  args[string](variants, default, help, group, hidden, validator)

proc opt*[T: not seq](variants: string, default: T = default(T), help = "", group = "Options", hidden = false, validator: Validator[T] = noValidator[T](), env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): ValueArg[T, false] =
  ## Creates an optional argument with a value of type `T`. If given, `default`
  ## can be used to infer `T`; otherwise, `T` defaults to `string` (see the
  ## bare-call overload below) unless set explicitly -- e.g. `opt[int]("-n")`.
  ## - `variants` is a comma-separated list of names by which the option is
  ##   presented to the user. These must take the form `-o` or `--option` and
  ##   may optionally include a help var (e.g., `--option=<value>`).
  ## - `default` is the default value of the option if not given by the
  ##   user; defaults to `T`'s zero value (`default(T)`, e.g. `""`, `0`, or
  ##   `false`).
  ## - `help` is a short description of the option used in help messages.
  ## - `group` determines how options are grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
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
  ## - `configKey` optionally names a structured path (e.g. `configKey("Package",
  ##   "name")`, or a bare string for a 1-segment path) supplying this
  ##   option's value from a registered Config Source when neither a CLI
  ##   nor an env value is given -- consulted below env in Value Precedence,
  ##   above the coded default. See `docs/adr/0018-config-source.md`.
  initValueArg[T, false](kind = Optional, variants = variants, default = @[default],
    help = help, group = group, hidden = hidden, validator = validator,
    env = env, cfgKey = configKey)

proc opt*(variants: string, default: string = "", help = "", group = "Options", hidden = false, validator: Validator[string] = noValidator[string](), env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): ValueArg[string, false] =
  ## Bare-call convenience for `opt[string]` -- lets `T` default to `string`
  ## without an explicit bracket (e.g. `opt("--name")`). See `opt[T]` above
  ## for full parameter docs.
  opt[string](variants, default, help, group, hidden, validator, env, configKey)

proc opts*[T: not seq](variants: string, default: seq[T] = newSeq[T](), help = "", group = "Options", hidden = false, validator: Validator[T] = noValidator[T](), env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): ValueArg[T, true] =
  ## Creates an optional argument which takes multiple values of type `T`.
  ## If given, `default` can be used to infer `T`; otherwise, `T` defaults to
  ## `string` (see the bare-call overload below) unless set explicitly.
  ## - `variants` is a comma-separated list of names by which the option is
  ##   presented to the user. These must take the form `-o` or `--option` and
  ##   may optionally include a help var (e.g., `--option=<value>`).
  ## - `default` is the default value(s) of the option if not given by the
  ##   user; defaults to an empty seq.
  ## - `help` is a short description of the option used in help messages.
  ## - `group` determines how options are grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  ## - `validator` is a `Validator` object of type `T` used to validate parsed
  ##   values. For example, `choice(["foo", "bar"])` would limit possible string
  ##   values to `foo` and `bar`, while `range(0..4)` would limit int values to
  ##   0-4. If `nil`, no validation will be performed and any valid `T` can be
  ##   given.
  ## - `env` optionally names an environment variable supplying this
  ##   option's value(s) when none are given on the command line (a CLI
  ##   value always wins), converted/validated the same way. The raw value
  ##   is split on `Spec.settings.envDelim` into as many values as this option's
  ##   position(s) can consume -- see
  ##   `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`. A
  ##   plain string names the env var alone; `env("NAME", delim)` also
  ##   overrides the delimiter for this option only (`delim = ""` disables
  ##   splitting entirely) -- see
  ##   `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  ## - `configKey` optionally names a structured path supplying this
  ##   option's value(s) from a registered Config Source when none are
  ##   given on the command line or via env -- consulted below env in
  ##   Value Precedence, above the coded default. See
  ##   `docs/adr/0018-config-source.md`.
  initValueArg[T, true](kind = Optional, variants = variants, default = default,
    help = help, group = group, hidden = hidden, validator = validator,
    env = env, cfgKey = configKey)

proc opts*(variants: string, default: seq[string] = @[], help = "", group = "Options", hidden = false, validator: Validator[string] = noValidator[string](), env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): ValueArg[string, true] =
  ## Bare-call convenience for `opts[string]` -- lets `T` default to `string`
  ## without an explicit bracket (e.g. `opts("--src")`). See `opts[T]` above
  ## for full parameter docs.
  opts[string](variants, default, help, group, hidden, validator, env, configKey)

proc flagOp*[T](variants: string, op: string, value: T, help = ""): FlagOpGroup[T] =
  ## Declares one explicit FlagOp Alias group for `flag*`'s `ops` param --
  ## every spelling in `variants` shares this exact Flag Operation
  ## (`op`/`value`) and `help` override. Unlike `flag*`'s own bare
  ## `variants` string (always the type's implicit/blank-op behavior --
  ## see `flag*`), `op` and `value` are mandatory here: a `flagOp` can
  ## never represent a blank operation.
  ## - `variants` is a comma-separated list of bare spellings (`-f`/
  ##   `--flag`).
  ## - `op` is one of the operations registered for `T` via `defineFlag`/
  ##   `defineArg` (e.g. `"="`, `"+="`, `"-="` for the built-in numeric
  ##   types) -- an unsupported op raises `SpecDefect`.
  ## - `value` is the value the operation applies.
  ## - `help` optionally overrides the auto-generated description shown in
  ##   help text (e.g. "Increase by 5") for every spelling in this group.
  checkFlagOp[T](op)
  result = (variants: splitFlagSpellings(variants), op: op, value: value, help: help)

proc flag*[T](variants: string = "", ops: varargs[FlagOpGroup[T]] = @[], default: T = default(T), help = "", group = "Options",
    hidden = false, clamp: FlagClamp[T] = noClamp[T](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): FlagArg[T] =
  ## Constructs a new flag, an optional argument that does not take a value and
  ## instead changes value based on the seen variant. If given, `default` can
  ## be used to infer `T`; otherwise, `T` defaults to `bool` (see the bare-call
  ## overload below) unless set explicitly -- e.g. `flag[int]("--boost")`.
  ## - `variants` is a comma-separated list of bare spellings (`-f`/
  ##   `--flag`) that all share the type's implicit/blank-op behavior:
  ##   flipping `default` for bool flags, or incrementing the existing
  ##   value by 1 for int flags. Every spelling here is automatically a
  ##   FlagOp Alias of every other, since they can only ever share one
  ##   `(op, value)` pair.
  ## - `ops` optionally declares one or more explicit FlagOp Alias groups,
  ##   built with `flagOp*` -- each names its own spellings, `op`, `value`,
  ##   and `help`, e.g. `ops = [flagOp("-b, --boost", "+=", 5, "Boost by
  ##   5")]`. Two different `flagOp` groups are always independently
  ##   reachable, even if their `(op, value)` coincidentally match -- see
  ##   `docs/adr/0027-flag-op-declarations.md`.
  ## - `default` is the default value of the flag if not given by the user;
  ##   defaults to `T`'s zero value (`default(T)`, e.g. `false` or `0`).
  ## - `group` determines how flags are grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  ## - `clamp` optionally attaches a `FlagClamp` (`argumint/flagclamp`),
  ##   silently adjusting this flag's value after every Flag Operation --
  ##   never raises, unlike a `Validator` (which never applies to a Flag in
  ##   the first place). `default` must already satisfy `clamp`, or spec
  ##   construction raises `SpecDefect` -- see
  ##   `docs/adr/0016-flag-clamp.md`.
  ## - `env` optionally names an environment variable supplying this
  ##   flag's value when none is given on the command line (a CLI flag
  ##   always wins). Each env value must name one of the flag's own
  ##   declared Variants (e.g. `--verbose`); an unrecognized name raises
  ##   `ParseError`. A flag matched more than once can take multiple env
  ##   values, split on `Spec.settings.envDelim` -- see
  ##   `docs/adr/0004-required-options-env-fallback.md` and
  ##   `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`. A
  ##   plain string names the env var alone; `env("NAME", delim)` also
  ##   overrides the delimiter for this flag only (`delim = ""` disables
  ##   splitting entirely) -- see
  ##   `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  ## - `configKey` optionally names a structured path supplying this
  ##   flag's value from a registered Config Source when none is given on
  ##   the command line or via env -- each value must name one of the
  ##   flag's own declared Variants, same as `env`. Consulted below env in
  ##   Value Precedence, above the coded default. See
  ##   `docs/adr/0018-config-source.md`.
  initFlagArg[T](variants = variants, ops = ops, default = default,
    help = help, group = group, hidden = hidden, clamp = clamp,
    env = env, cfgKey = configKey)

proc flag*[T](variants: string = "", ops: string, default: T = default(T), help = "", group = "Options",
    hidden = false, clamp: FlagClamp[T] = noClamp[T](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): FlagArg[T] =
  ## Convenience overload: `ops` as a comma-separated string of
  ## `<flag><op><value>` entries (e.g. `"--quiet=0, --boost+=5,
  ## --dampen-=2"`), each becoming its own single-spelling explicit FlagOp
  ## Alias group -- sugar for, and parsed into, the equivalent array of
  ## `flagOp*` calls. A multi-spelling explicit group, or a value with no
  ## string spelling, still needs the array form directly. See `flag[T]`
  ## above for full parameter docs, and
  ## `docs/adr/0028-flag-ops-string-convenience.md` for why this is a
  ## separate overload rather than folded into `variants` itself.
  flag[T](variants, parseFlagOpsString[T](ops), default, help, group, hidden, clamp, env, configKey)

proc flag*(variants: string = "", ops: varargs[FlagOpGroup[bool]] = @[], default: bool = false, help = "", group = "Options",
    hidden = false, clamp: FlagClamp[bool] = noClamp[bool](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): FlagArg[bool] =
  ## Bare-call convenience for `flag[bool]` -- lets `T` default to `bool`
  ## without an explicit bracket (e.g. `flag("--verbose")`). See `flag[T]`
  ## above for full parameter docs.
  flag[bool](variants, ops, default, help, group, hidden, clamp, env, configKey)

proc flag*(variants: string = "", ops: string, default: bool = false, help = "", group = "Options",
    hidden = false, clamp: FlagClamp[bool] = noClamp[bool](),
    env: Option[EnvSource] = none(EnvSource), configKey: ConfigKey = noConfigKey()): FlagArg[bool] =
  ## Bare-call convenience for `flag[bool]`'s `ops: string` overload --
  ## lets `T` default to `bool` without an explicit bracket. See `flag[T]`
  ## above for full parameter docs.
  flag[bool](variants, ops, default, help, group, hidden, clamp, env, configKey)

proc command*[S](variants: string, spec: S, help = "", prolog = "", epilog = "", usage = "", group = "Commands", hidden = false,
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil): CommandArg =
  ## - `variants` is a comma-separated list of names by which the command can be
  ##   called by the user.
  ## - `spec` is a spec tuple representing all possible args this command takes.
  ## - `help` is a short description of the command used in help messages.
  ## - `prolog` is the front matter for help messages generated for this
  ##   command. Use this to provide a detailed description of the command's
  ##   purpose.
  ## - `epilog` is the end matter for help messages generated for this command.
  ## - `usage` is the usage string that controls how the command's args can be
  ##   invoked.
  ## - `group` determines how this command is grouped in help messages.
  ## - `hidden`, if `true`, prevents the command from appearing in help messages
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
  ## Note: `config` is deliberately not a parameter here: it cascades down
  ## by reference from whatever the top-level `newSpec`/`parse*` call is
  ## given, so it only needs to be specified once regardless of how deeply
  ## nested this command is.
  result = CommandArg(kind: ArgKind.Command, variants: variants.split(Comma), help: help, group: group, hidden: hidden)
  result.spec = newSpec(spec, usage, prolog, epilog)
  if not before.isNil:
    result.spec.before = (info: HookInfo) => before(spec, info)
  if not action.isNil:
    result.spec.action = (info: HookInfo) => action(spec, info)
  if not after.isNil:
    result.spec.after = (info: HookInfo) => after(spec, info)

proc command*[S, O](variants: string, spec: S, options: O, help = "", prolog = "", epilog = "", usage = "", group = "Commands", hidden = false,
    before: proc(spec: S, opts: O, info: HookInfo) = nil,
    action: proc(spec: S, opts: O, info: HookInfo) = nil,
    after: proc(spec: S, opts: O, info: HookInfo) = nil): CommandArg =
  ## - `variants` is a comma-separated list of names by which the command can be
  ##   called by the user.
  ## - `spec` is a spec tuple representing all possible args this command takes.
  ## - `options` is a generic extra-context passthrough, not necessarily
  ##   CLI-options-shaped data -- typically the caller's enclosing/parent spec
  ##   tuple (or any other context object), so a nested command's hooks can
  ##   read outer/global state that `spec: S` alone -- scoped to just this
  ##   command's own tuple -- wouldn't otherwise expose.
  ## - `help` is a short description of the command used in help messages.
  ## - `prolog` is the front matter for help messages generated for this
  ##   command. Use this to provide a detailed description of the command's
  ##   purpose.
  ## - `epilog` is the end matter for help messages generated for this command.
  ## - `usage` is the usage string that controls how the command's args can be
  ##   invoked.
  ## - `group` determines how this command is grouped in help messages.
  ## - `hidden`, if `true`, prevents the command from appearing in help messages
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
  ## Note: `config` is deliberately not a parameter here: it cascades down
  ## by reference from whatever the top-level `newSpec`/`parse*` call is
  ## given, so it only needs to be specified once regardless of how deeply
  ## nested this command is.
  command(variants, spec, help, prolog, epilog, usage, group, hidden,
    before = if before.isNil: nil else: (proc(cmdSpec: S, info: HookInfo) = before(spec, options, info)),
    action = if action.isNil: nil else: (proc(cmdSpec: S, info: HookInfo) = action(spec, options, info)),
    after = if after.isNil: nil else: (proc(cmdSpec: S, info: HookInfo) = after(spec, options, info)))

proc help*(variants = "-h, --help", help = "Display this help message", group = "Options", hidden = false): HelpArg =
  ## Creates a flag which, when matched, displays an auto-generated help message
  ## for the spec in whose context it was called.
  ## - `variants` is a comma-separated list of names by which the flag is
  ##   presented to the user. These must take the form `-o` or `--option`.
  ## - `help` is a short description of the flag used in help messages.
  ## - `group` determines how the flag is grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  HelpArg(kind: Flag, variants: variants.split(Comma), help: help, group: group, hidden: hidden)

proc message*(variants: string, text: string, help = "", group = "Options", hidden = false): MessageArg =
  ## Creates a flag which, when matched, displays `text` and exits
  ## successfully instead of parsing further arguments.
  ## - `variants` is a comma-separated list of names by which the flag is
  ##   presented to the user. These must take the form `-o` or `--option`.
  ## - `text` is the message to display when the flag is matched.
  ## - `help` is a short description of the flag used in help messages.
  ## - `group` determines how the flag is grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  MessageArg(kind: Flag, variants: variants.split(Comma), message: text, help: help, group: group, hidden: hidden)

proc version*(variants: string, version: string, help = "Display version information", group = "Options", hidden = false): MessageArg =
  ## Thin wrapper around `message` for the common case of a version flag.
  ## - `variants` is a comma-separated list of names by which the flag is
  ##   presented to the user. These must take the form `-v` or `--version`.
  ## - `version` is the message to display when the flag is matched.
  ## - `help` is a short description of the flag used in help messages.
  ## - `group` determines how the flag is grouped in help messages.
  ## - `hidden`, if `true`, prevents the arg from appearing in help messages
  message(variants, version, help, group, hidden)

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
  args.len > 0 and args[0] == "__complete"

proc parseOrQuit*(spec: Spec, args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename())) =
  ## Like `parse*(Spec)`, but prints a message and `quit()`s instead of
  ## raising on failure -- intended for a bare CLI `main()`, not for
  ## embedding in a larger program.
  ##
  ## `spec` is **single-use**, same as `parse*(Spec)` -- and, being a built
  ## `Spec` rather than a spec tuple, it has no `parsed*` counterpart. Build
  ## a fresh one per parse. See
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  try:
    spec.parse(args, command)
  except ParseError as e:
    quit("Parsing error:\n{e.msg}".fmt)
  except ValidationError as e:
    quit("Validation error:\n{e.msg}".fmt)
  except HelpError as e:
    quit(e.msg, QuitSuccess)
  except CompletionError as e:
    # Must land on stdout, not stderr like quit() -- see docs/gotchas.md.
    echo e.msg
    quit(QuitSuccess)
  except MessageError as e:
    quit(e.msg, QuitSuccess)

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
    args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename()),
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil) =
  ## Like `parse*(tuple)`, but prints a message and `quit()`s instead of
  ## raising on failure -- intended for a bare CLI `main()`, not for
  ## embedding in a larger program.
  ## - `usage` is the usage string used to build the FSM. See
  ##   `docs/architecture.md`'s "autoFillUsage" section for how gaps in
  ##   `usage` are auto-filled.
  ## - `prolog` is the front matter for help messages generated from this spec.
  ## - `epilog` is the end matter for help messages generated from this spec.
  ## - `settings` holds `width`/`maxVariantsWidth`/`envDelim` -- see
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
  ## same Args rather than starting fresh. Use `parsedOrQuit*` to parse a
  ## fresh spec per call -- see
  ## `docs/adr/0031-parsed-fresh-spec-per-parse.md`.
  try:
    spec.buildAndBind(usage, prolog, epilog, settings, before, action, after)
      .parseOrQuit(args, command)
  except SpecDefect as e:
    quit(fmt"Error constructing spec: {e.msg}")

proc parse*[S: tuple](spec: S, usage = "", prolog = "", epilog = "",
    settings = newSpecSettings(),
    args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename()),
    before: proc(spec: S, info: HookInfo) = nil,
    action: proc(spec: S, info: HookInfo) = nil,
    after: proc(spec: S, info: HookInfo) = nil) =
  ## Builds `spec` into a `Spec` via `newSpec` and parses `args` against it in
  ## one step. Raises `SpecDefect` (malformed spec), or `ParseError`/
  ## `ValidationError`/`HelpError`/`MessageError` (parse failure) -- use
  ## `parseOrQuit*` if you want those to print a message and `quit()` instead.
  ## - `usage` is the usage string used to build the FSM. See
  ##   `docs/architecture.md`'s "autoFillUsage" section for how gaps in
  ##   `usage` are auto-filled.
  ## - `prolog` is the front matter for help messages generated from this spec.
  ## - `epilog` is the end matter for help messages generated from this spec.
  ## - `settings` holds `width`/`maxVariantsWidth`/`envDelim` -- see
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
    args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename()),
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
    args: seq[string] = commandLineParams(), command = extractFilename(getAppFilename()),
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
    quit(fmt"Error constructing spec: {e.msg}")

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
    quit(fmt"Error constructing spec: {e.msg}")

proc completionScript*(spec: Spec, shell: Shell, binaryName = extractFilename(getAppFilename())): string =
  ## Returns a shell-completion script for `shell` that completes
  ## `binaryName` by shelling out to it (`<binaryName> __complete
  ## <words...>`) -- see `docs/adr/0012-fsm-driven-shell-completion.md`.
  ## Author-driven, like `dot*`: install the result however your packaging
  ## needs (write it to a file, expose a `completion` subcommand, etc.) --
  ## argumint doesn't wire this up automatically.
  spec.genCompletionScript(shell, binaryName)
