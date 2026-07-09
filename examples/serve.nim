# This example demonstrates how validators and defaults combine in
# auto-generated help text. `--port` and `--workers` are restricted to a
# numeric range, `--log-level` to a fixed set of choices, and each shows its
# constraint via `[range: ...]`/`[choices: ...]` in `--help`, combined with
# any non-zero default via `[default: X]` in the same bracket. Passing a
# value outside a constraint (e.g. `--port=99999` or `--log-level=verbose`)
# raises a `ValidationError` before the server ever "starts".
#
# `--host`/`--port` also demonstrate `env`: since both are already optional
# (each has a `default`), `SERVE_HOST`/`SERVE_PORT` can supply a value
# instead of typing the flag, with an explicit `--host`/`--port` still
# winning if given. A value from the env var goes through the same
# validation as a command-line one -- e.g. `SERVE_PORT=99999` raises the
# same `ValidationError` `--port=99999` would.

import std/strformat

import argumint
import argumint/validators

let
  spec = (
    host: opt("--host=<host>", default = "localhost", env = "SERVE_HOST", help = "Host to bind to"),
    port: opt("--port=<port>", default = 8080, validator = range(1..65535), env = "SERVE_PORT", help = "Port to listen on"),
    logLevel: opt(
      "--log-level=<level>", default = "info",
      validator = choice(["debug", "info", "warn", "error"]), help = "Logging verbosity"
    ),
    workers: opt("--workers=<n>", default = 4, validator = range(1..32), help = "Number of worker processes"),
    help: help()
  )

spec.parse(prolog = "Start the server")
echo fmt"Serving on {spec.host}:{spec.port} with {spec.workers} workers (log level: {spec.logLevel})"
