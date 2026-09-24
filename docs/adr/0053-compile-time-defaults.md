# `newSpecSettings`'s defaults can be set with `-d:` defines

The five constants `newSpecSettings` takes its defaults from can now be
overridden when a program is built, through define pragmas with
argumint-namespaced names:

| Constant | Define |
|---|---|
| `DefaultWidth` (80) | `-d:argumint.width=N` |
| `DefaultMaxWidth` (100) | `-d:argumint.maxWidth=N` |
| `DefaultMaxVariantsWidth` (30) | `-d:argumint.maxVariantsWidth=N` |
| `DefaultEnvDelim` (`:`) | `-d:argumint.envDelim=S` |
| `DefaultStrictOptions` (`true`) | `-d:argumint.strictOptions=B` |

Before this, changing a default meant passing `newSpecSettings(...)` at
every `parse`/`parseOrQuit` call site, or patching argumint. That's
awkward for an author who wants one project-wide default, and impossible
without a patch for someone building another author's program, such as a
distro packager. A define can go on the command line or in the program's
`config.nims`. Settings passed to `newSpecSettings` explicitly still win.

The names are namespaced (`argumint.width`, not `DefaultWidth`) because
defines share one global namespace across every library in a build.

## Validation

A `static: doAssert` fails the build, naming the define, when either width
is below 20 (the floor the help renderers already clamp to) or
`maxVariantsWidth` is negative (`0` stays "unlimited"). Whoever sets a
define is at a compiler, so a compile error reaches exactly the right
person; the alternative, accepting anything, would have `maxWidth=0` quietly
wrap all help at 20 columns.

An empty `envDelim` is allowed. Splitting on `""` leaves a value whole, so
it means "don't split env values by default", the build-wide version of
the per-Arg `env("X", "")` opt-out (ADR 0015).

## `DefaultWidth` is now the real fallback

`detectWidth` used to fall back to `std/terminal.terminalWidth()`, whose
last resort is its own hard-coded 80. `DefaultWidth` was never read, so
`-d:argumint.width` would have done nothing. `detectWidth` now tries a
positive `COLUMNS`, then `terminalWidthIoctl` on the standard streams, then
`DefaultWidth`, with the rule factored into a pure `chooseWidth` for tests.

This drops `terminalWidth()`'s POSIX-only last step, asking the
controlling terminal via `ctermid`. That step only matters when stdin,
stdout, and stderr are all redirected, which usually means there's no
terminal to ask (cron, CI), and `DefaultWidth` is the right answer there.
Keeping it would have meant a local `importc` of `ctermid` for that edge
case.

## `DefaultWidth` is exported

ADR 0029/0030 kept `DefaultWidth` out of `import argumint` because no
exported signature used it. Now it's a documented, settable default, so
it's exported with the other four: a caller can read what a define set,
or write their own detection around it.

## Considered options

- **Bare define names** (`-d:DefaultMaxWidth=80`). Rejected: they can
  collide with another library's defines in the same build.
- **Only the width constants.** Rejected in favour of one rule: every
  `newSpecSettings` default can be set with a define. `strictOptions`
  changes what a program's grammar accepts, so the README says it's meant
  for the program's author, not for packagers.
- **Environment variables read at run time.** Out of scope: they would
  hand the person running the program settings meant for its author.

## Consequences

- `import argumint` gains `DefaultWidth`.
- Where nothing can be detected, the width is still 80 unless
  `argumint.width` is set. The only behaviour change is the dropped
  controlling-terminal step, when all three standard streams are
  redirected.
- Tests that pin a default compare against its constant, and the stock
  values are pinned only when their define isn't set, so the suite passes
  under any valid define. `tests/test_compile_defines.nim` is built with all
  five set via its own `.nims`.
