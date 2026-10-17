## `SpecSettings`: the presentation and parsing settings one Spec tree
## shares (`newSpecSettings`), with the compile-time defaults behind them
## (ADR 0053) and the getters that detect the terminal's width and colour on
## first read (ADR 0058). Sits below `argumint/core/backend`, whose `Spec`
## holds one; it's the only part of the data model that depends on
## `argumint/text/console`.

import ./envvar, ../text/[console, style], ../configsource
export console.DefaultWidth, console.DefaultMaxWidth, console.MinWidth,
  console.chooseWidth, console.detectWidth

type
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
  ##   `COLUMNS` unset). An explicit width is used as given, down to
  ##   `MinWidth` (20): `width = detectWidth()` for no cap, or `width =
  ##   min(detectWidth(), 120)` for your own.
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
  ## The column width usage/help text wraps at, never less than `MinWidth`
  ## (20): a narrower width, set or detected, reads back as `MinWidth`. A
  ## `0` is detected here, on first read, and kept: `detectWidth()` capped
  ## at `DefaultMaxWidth`.
  if s.width == 0: s.width = resolvedWidth()
  max(s.width, MinWidth)

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
