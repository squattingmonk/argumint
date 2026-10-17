## Value Precedence's env tier -- a value read from an environment variable,
## consulted for an Option/Flag between the command line and the Config
## Source tier. See `CONTEXT.md`'s **Env Source**/**Env Delimiter** entries,
## `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`, and
## `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
##
## A leaf, like `argumint/configsource`: only `std`, no dependency on
## `backend`, so `backend` can name `EnvSource` in its `envSource` method and
## `DefaultEnvDelim` in `newSpecSettings`.

import std/[options, os, strutils]

type
  EnvSource* = object
    ## Names the environment variable configured to supply an Arg's value,
    ## with an optional per-Arg override of the delimiter its raw value is
    ## split on -- see `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
    ## `name` is required (not `Option[string]`): an override with no name
    ## to apply it to is a meaningless state, so "is there an env source at
    ## all" is instead answered by wrapping this whole object in `Option`
    ## wherever it's used (e.g. `ValueArg.env`/`FlagArg.env`).
    name*: string
    delim*: Option[string]
      ## `none` inherits `Spec.settings.envDelim`; `some("")` means never split
      ## this Arg's value at all

# Overridable at compile time -- see `docs/adr/0053-compile-time-defaults.md`.
const
  DefaultEnvDelim* {.strdefine: "argumint.envDelim".} = ":"
    ## `newSpecSettings`'s default `envDelim`, the `PATH`-style convention.
    ## Set with `-d:argumint.envDelim`; empty means env values aren't split.

converter toEnvSource*(name: string): Option[EnvSource] =
  ## Lets `opt*`/`opts*`/`flag*`'s `env` param be given a plain env var
  ## name (`env = "PORT"`), same as before -- see `env*` for the two-arg
  ## form that also overrides the delimiter.
  some(EnvSource(name: name))

proc env*(name: string, delim: string): Option[EnvSource] =
  ## Names an environment variable to supply an arg's value, overriding
  ## the delimiter its raw value is split on for this arg only, instead of
  ## inheriting `Spec.settings.envDelim`. `delim = ""` means never split this
  ## arg's env value at all -- see
  ## `docs/adr/0015-per-arg-env-delimiter-overrides.md`.
  some(EnvSource(name: name, delim: some(delim)))

proc splitEnvValue*(value: string, delimOverride: Option[string], envDelim: string): seq[string] =
  ## Splits a raw env var's value into the (possibly several) values it
  ## supplies to Value Precedence's environment-variable tier: on
  ## `delimOverride` (the matched Arg's own `EnvSource.delim`) if set,
  ## otherwise on `envDelim` (`Spec.settings.envDelim`, the `PATH`-style `:`
  ## convention by default). An empty delimiter never splits; `value` is the
  ## only element. See `docs/adr/0015-per-arg-env-delimiter-overrides.md`
  ## and `docs/adr/0064-no-record-separator-env-split.md`.
  ##
  ## Empty segments (a stray leading/trailing/doubled delimiter) are kept
  ## as literal values, not dropped, so an env value is never treated
  ## differently from one typed on the command line -- see
  ## `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`.
  # `split("")` returns `@[value]`, so an empty delimiter needs no case.
  value.split(delimOverride.get(envDelim))

proc lookupEnv*(source: EnvSource, envDelim: string): Option[seq[string]] =
  ## The values `source`'s variable supplies, split per `splitEnvValue`, or
  ## `none` if it isn't set. The env tier's counterpart to
  ## `lookupConfigSources`.
  if existsEnv(source.name):
    some(splitEnvValue(getEnv(source.name), source.delim, envDelim))
  else:
    none(seq[string])

when isMainModule:
  import std/unittest

  suite "splitEnvValue":
    test "splits on envDelim when nothing more specific applies":
      check splitEnvValue("a:b", none(string), ":") == @["a", "b"]

    test "a per-Arg delim overrides envDelim":
      check splitEnvValue("a,b:c", some(","), ":") == @["a", "b:c"]

    test "an empty per-Arg delim never splits":
      check splitEnvValue("a:b", some(""), ":") == @["a:b"]

    test "an empty envDelim never splits":
      check splitEnvValue("a:b", none(string), "") == @["a:b"]

    test "empty segments are kept":
      check splitEnvValue(":a::", none(string), ":") == @["", "a", "", ""]

  suite "lookupEnv":
    const name = "ARGUMINT_ENVVAR_TEST"

    test "an unset variable yields none":
      delEnv(name)
      check lookupEnv(EnvSource(name: name), ":").isNone

    test "a set variable is split":
      putEnv(name, "a:b")
      defer: delEnv(name)
      check lookupEnv(EnvSource(name: name), ":") == some(@["a", "b"])

    test "the per-Arg delim is honoured":
      putEnv(name, "a:b")
      defer: delEnv(name)
      check lookupEnv(EnvSource(name: name, delim: some("")), ":") == some(@["a:b"])
