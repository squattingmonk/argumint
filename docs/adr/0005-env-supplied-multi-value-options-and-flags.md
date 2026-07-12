# An env var can supply more than one value to a repeated Option/Flag

Extends ADR 0004.

ADR 0004 let a required Option/Flag's env var satisfy the requirement, but
capped it at exactly one virtual match per Arg per walk (`envSatisfied`) --
an env var only ever contributed a single value, even to a multi-value
Option or an Option/Flag matched more than once in a Usage Line. We're
removing that cap.

## Decision

Every env-configured Option/Flag's raw env string is unconditionally split
into a list of values: on `\x1e` (ASCII Record Separator) if present --
which is how fish auto-joins a native list variable's elements when
exporting it to a subprocess's environment, for any variable name, not just
`*PATH` -- otherwise on `Spec.envDelim`, a new cascading Spec-level setting
(like `width`/`maxVariantsWidth`) defaulting to `:` (the PATH-style
convention `bash`/`zsh` users already reach for). Empty segments (`"a::b"`,
a stray leading/trailing delimiter) are kept as literal values rather than
dropped, so an env value goes through exactly the same conversion path a
CLI value would -- consistent with the rest of this env feature.

Nothing decides up front whether a given Arg is allowed to consume more
than one of these values. Instead, `ParseContext` tracks a per-Arg cursor
into the split list, consumed one value at a time each time that Arg's
`Option` matcher is consulted for env fallback during the walk. Whether
the matcher gets consulted once or several times falls out entirely from
the FSM graph already built from the Usage String -- a real repeat
(`...`, or reachable only through `[options]`, per ADR 0002) loops back to
the same matcher and so keeps consuming until the list is exhausted; the
same Arg named twice in one Usage Line with no `...` (e.g. `--port=<port>
--port=<port>`) is two separate, sequential matcher instances, and the
cursor is consulted twice either way, uniformly, no special-casing
required. There is deliberately no separate "is this Arg repeatable"
concept computed or stored anywhere (not on `Arg`, not on `Matcher`) --
the Usage String, as compiled into the graph, is the only source of truth
for how many times a position can be used, exactly as it already is for
real command-line tokens.

After a successful walk, an Arg whose matcher was consulted at least once
gets exactly as many values applied as the walk actually consumed, via the
same per-kind Match Accumulation a real repeated CLI match would produce.
If the env var had more values left over than the grammar had slots for
(e.g. three colon-separated values for an Option named only twice), that's
a `ParseError` -- `"unexpected option/flag <name>"`, the same wording
already used for a genuinely excess CLI token -- rather than silently
using only a prefix of the values. This is also what keeps a single-slot
Option whose legitimate value happens to contain the delimiter (a URL, a
timestamp) safe: it fails loudly instead of silently truncating to the
first segment. An Arg whose matcher was never consulted at all during this
walk (reachable only through a different, unmatched Usage Line of the same
Spec -- the scenario ADR 0004's per-Arg-not-per-Usage-Line design already
exists for) has no walk-derived count to bound it by, so every available
value is applied, generalizing the single-value fallback ADR 0004 already
established for that case.

## Flag env values are now Variant names, not raw values

Flag env fallback previously converted the env string straight to `T` and
applied it via a hardcoded `=` -- a workaround forced by env only ever
carrying one value, which meant it could never actually compose the way
repeated Flag matches normally do (Match Accumulation: each match applies
its own Variant's Flag Operation, in sequence). Now that an env var can
supply several values, each one is instead treated as the literal spelling
of one of the Flag's own declared Variants (e.g. `--verbose`, matching
`self.ops`' keys exactly, the same string a CLI match would look up) and
applied via *that* Variant's own Flag Operation -- not forced through `=`.
An env value naming something that isn't a declared Variant is a
`ParseError`, not a `SpecDefect`: the Variant table was already validated
at spec-construction time, so an unrecognized name here is bad input from
the environment, the same category of failure as a bad CLI value or a
failed Validator.

This also removes the construction-time `SpecDefect` requiring `T`'s flag
handler to support `=` -- env no longer needs a string-to-`T` conversion at
all, so it works uniformly for every flag type, including one like
`set[E]` (`defineSetFlag`) that has no natural string spelling and
previously couldn't use `env` at all.

## Consequences

This changes Flag env behavior even in the single-value case: an existing
`flag[int]("--verbose", env = "X")` with `X=5` used to set the value to
`5` directly; it now requires `X` to name a Variant (e.g. `--verbose`) and
applies whatever Operation that Variant declares (for a bare, blank-op
`--verbose`, that's the type's increment-by-1/toggle default, not an
arbitrary value). There is no compatibility shim for this -- it's a
deliberate, one-time behavior change to Flag's env semantics, not an
additive feature.
