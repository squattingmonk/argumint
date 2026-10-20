## What a Custom Arg needs beyond `import argumint`: `initArg` to set the
## fields a Spec is built from, and the methods and types it overrides to
## store its own values (`accept`, with the `Contribution` and `Arbitration`
## it takes, and `subject` to name the Arg in an error), to take part in
## Value Precedence's fallback tiers (`envSource`, `configKey`, and the
## `envName` derived from the first), or to act as a Message Argument
## (`isMessage`, `action`). See `docs/guide/custom-types.md`.

import ./core/[backend, errors, variant]

export backend.accept, backend.Contribution, backend.Arbitration,
  backend.subject, backend.action, backend.isMessage, backend.envSource,
  backend.envName, backend.configKey

proc initArg*(arg: Arg, kind: ArgKind, variants: string) =
  ## Sets `arg`'s `kind`, and its `variants` from a comma-separated list,
  ## as every built-in constructor does. Call it once, while building
  ## `arg`: a second call raises `SpecDefect`, since a Spec may already be
  ## built from the first. The Variants are checked when the Spec is built,
  ## like any other Arg's.
  if arg.variants.len > 0:
    raise newException(SpecDefect,
      "initArg called twice for " & arg.variants[0])
  arg.initBase(kind, splitVariants(variants))
