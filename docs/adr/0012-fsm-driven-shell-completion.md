# Shell completion is resolved dynamically by re-walking the FSM

TODO.md listed "Shell completion generation (bash/zsh/fish) from a Spec" as
future work with no further detail. This records the design settled before
implementation.

## Decision: dynamic, FSM-driven completion via a `__complete` magic arg

The compiled binary resolves completion candidates at request time by
re-walking its own already-built FSM against the partial command line typed
so far, rather than generating a full completion script ahead of time that
reimplements grammar logic in bash/zsh/fish. A shell asks for candidates by
invoking the real binary with a reserved leading argument, Cobra-style:
`mycli __complete <partial words...>`. Per-shell adapter scripts are thin
and mechanical -- they only forward `COMP_WORDS` to `__complete` and feed the
newline-separated stdout back into the shell's own completion machinery
(`COMPREPLY`, `compadd`, fish's native command-substitution completion).

This follows directly from argumint's own foundational premise: the FSM
compiled from a Usage String is already the single source of truth for
"what's valid here." Completion candidates that come from walking that same
FSM can never drift out of sync with what real parsing would actually
accept; a hand-maintained shell-script reimplementation of the grammar could.

## Rejected alternative: static per-shell script generation

Walking the `Spec`/FSM once, ahead of time, to emit one complete bash/zsh/
fish script per shell (listing every command/option outright, with shell-
native case/switch logic choosing what's valid at each position) was
considered and rejected. It would need the grammar's matching rules --
mutually-exclusive Usage Lines, non-repeatable options that stop being
offered once consumed, subcommand-scoped options, env-var fallback -- to be
re-expressed three times over, once per shell's own scripting language, and
kept in sync by hand every time a `Spec` changes. That's a permanent,
tripled maintenance burden for logic the FSM already implements correctly
once. Dynamic completion needs none of this: the shell scripts stay thin
forever, and the FSM only needs to be walked one way, one time, in Nim.

## The `__complete` trigger: magic leading arg over an env var

An env var trigger (Click-style: `_MYCLI_COMPLETE=1 mycli <words...>`) was
considered and explicitly revisited mid-design. Rejected in favor of the
magic leading arg because:

- Every argumint parse entry point already threads `args: seq[string]`
  explicitly (`fsm.parse*(spec: Spec, args: seq[string] = commandLineParams(),
  ...)`). Detecting `args[0] == "__complete"` needs no new input to that
  signature; an env-var trigger would need `parse*` to also consult
  `os.getEnv`, a second, hidden input channel none of its callers expect.
- It's trivially unit-testable: `spec.parse(args = @["__complete", "--lo"])`
  in plain `std/unittest`, no environment mocking or cleanup required --
  consistent with how every other test in this codebase already drives
  `parse*` via an explicit `args` value.
- It keeps "env var" meaning one thing in this library: Value Precedence's
  value-fallback tier for an Option/Flag (see CONTEXT.md). Reusing env vars
  for a second, unrelated purpose -- triggering a wholly different execution
  mode -- would make that term do double duty in the same codebase.
- Generated shell adapters stay simpler: plain argv forwarding, no env-var
  plumbing to construct per shell.
- This is Cobra's own convention, shipped widely with no reported real-world
  collision problems.

**Trade-off accepted**: `__complete` becomes a reserved Command name --
nothing in the PEG variant-format validation stops an author from declaring
a Command literally named `__complete` today, but `fsm.parse*`'s
interception unconditionally shadows it before FSM dispatch ever runs. This
is documented as a reserved word rather than defended against in code.

## Resolved implementation questions

- **Interception point**: a single check at the top of `fsm.parse*(spec:
  Spec, ...)` -- the one runtime funnel all four public entry points
  (`fsm.parse*`, `argumint.parseOrQuit*` for both `Spec` and tuple overloads)
  eventually call through. `dispatch()` -- the only place `before`/`action`/
  `after` fire -- is never reached during a completion request.
- **Error/output plumbing**: a new `CompletionError* = object of MessageError`
  (`backend.nim`, a peer of `HelpError`) carries the candidates as its `msg`.
  `parseOrQuit*` gets its own `except CompletionError as e: echo e.msg;
  quit(QuitSuccess)` branch (ordered before the general `except MessageError`
  catch, same as `HelpError`'s) rather than reusing that catch-all as
  originally assumed: `quit(msg, code)`'s doc comment claims it's a shorthand
  for `echo(msg); quit(code)`, but the actual non-nimscript/js implementation
  (`system.nim`) writes to **stderr** (`cstderr.rawWrite`), not stdout. Since
  a shell adapter reads candidates via `$(...)` command substitution (stdout
  only), reusing the shared `MessageError` branch would have silently
  swallowed every candidate -- caught by manually sourcing a generated
  completion script in a live shell rather than by the unit tests (which
  only asserted on the exception's `msg` field, never on real process
  stdout).
- **The matching primitive**: `walk` (`fsm.nim`) is a single-winner
  backtracker -- it returns as soon as one branch succeeds, never trying
  sibling transitions afterward. Completion needs the opposite: every state
  simultaneously still reachable after consuming the tokens typed so far,
  since multiple Usage Lines or `choice` alternatives can all still be live
  at once. A new `collectFrontier` primitive generalizes `walk`'s shape
  (reusing `Matcher.match`/`ParseContext` unmodified) to accumulate every
  live state instead of stopping at the first.
- **Env-var fallback is honored during completion**: reusing `match`
  unmodified means an option satisfiable via its configured `env` is treated
  as already-satisfiable during completion too, exactly as real parsing
  would -- completion should never suggest a user must type something real
  parsing wouldn't have required.
- **Choice-validator value completion is in scope**: e.g. `--level=<TAB>`
  suggesting `debug info warn error`. This needed a new, narrowly-scoped
  public accessor, `Validator[T].completions(): seq[string]`, since the
  existing `help()` only returns a formatted description string
  (`"choices: debug, info, warn, error"`), not the underlying values.
  `vkChoice` returns its choices directly; `vkRange`/`vkCheck`/`vkCheckSeen`
  aren't enumerable and return `@[]`; `vkAny` (OR) returns the union of
  every child's own candidates; `vkAll` (AND) intersects candidates from
  whichever children are enumerable, then re-validates survivors against
  every child including non-enumerable ones (e.g. `all(choice(["a","bb",
  "ccc"]), checkIt(it.len <= 2))` -> `@["a", "bb"]`), returning `@[]` only
  if no child is enumerable at all.
- **`collectFrontier` ships uncapped**: unlike `walk`, it can't stop at the
  first success, so its worst case is the full backtracking tree rather than
  `walk`'s cheaper "stop at first winner." Realistic CLI grammars (a handful
  of options/subcommands) make this a non-issue in practice; a hard branch/
  depth cap was considered and deferred, to be revisited only if a real slow
  case surfaces.
- **Known, accepted tradeoff -- pre-parse setup reruns on every completion
  request**: because `__complete` works by the shell re-invoking the real
  compiled binary as a subprocess, every TAB press is a fresh process
  invocation. `Before`/`Action`/`After` hooks are unaffected (interception
  happens before `dispatch()`), but anything an author's own `main()` does
  *before* calling `parse*`/`parseOrQuit*` at all -- config loading, opening
  a DB connection -- reruns on every single completion request, since
  argumint has no way to intercept code that runs before it's ever called
  into. Every other dynamic-completion framework (Cobra, Click, clap,
  carapace) accepts this same limitation for the same reason. Mitigation: an
  exported `isCompletionRequest*(args: seq[string] = commandLineParams()):
  bool` helper lets an author guard expensive pre-parse work themselves.
- **Script generation stays explicit and author-driven**: `spec.
  completionScript(shell, binaryName)` (mirroring the existing `spec.dot`)
  returns a script string; wiring it up (writing it to a file, exposing a
  `mycli completion bash` subcommand, etc.) is left entirely to the author,
  matching the library's existing philosophy of explicit composition rather
  than implicit magic injected into every `Spec`.
