# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`argumint` is a Nim command-line argument parsing library (Nim >= 2.2.4). Its
distinguishing feature is that a spec is declared as a tuple of `arg`/`opt`/
`flag`/`command`/`help` values, and a **docopt-style usage string** is
compiled into a finite state machine (FSM) that drives actual parsing. This
lets usage patterns express things like optional/repeated/mutually-exclusive
args (`[-r] <src>... <dest>`) declaratively instead of via imperative flag
registration.

## Commands

- Compile/run the Naval Fate demo in `src/argumint.nim` (has a
  `when isMainModule` block with a working example spec):
  ```
  nim c -r src/argumint.nim -- ship move Titanic 1 2
  ```
  Note: `nim c -r file -- args` may pass a spurious leading `--` through to
  the compiled binary depending on Nim version -- if a run fails with
  unexpected "missing option"/"unexpected arg" errors, compile first (`nim c
  file`) then run the binary directly with the same args to rule this out.
- Run the full test suite with `nimble test`, which compiles and runs
  `src/argumint/validators.nim`'s embedded `std/unittest` block plus every
  `tests/test_*.nim` file (each is its own standalone `std/unittest` suite;
  `tests/config.nims` adds `src` to the path for anything placed there). Add
  new tests as new `tests/test_*.nim` files -- no per-file wiring needed
  beyond that naming convention.
- Dependencies are managed via Atlas (`atlas.workspace`, `deps/atlas.config`),
  not classic nimble/nimble.lock.
- `config.nims` sets `-d:nimPreviewHashRef` globally — required for the code
  to compile under Nim 2.2's ref-hashing preview.

## Architecture

Parsing happens in two distinct phases, and understanding the split is key to
navigating the code:

1. **Spec construction** (`src/argumint.nim`): user calls `arg`, `opt`,
   `flag`, `command`, `help` to build a tuple of `Arg` objects, then
   `newSpec`/`parse` assembles them into a `Spec` (`backend.nim`). Each arg is
   indexed into `spec.arguments` (positional, keyed by `<name>`),
   `spec.options` (optional/flag, keyed by `-o`/`--option`), or
   `spec.commands` (subcommands, keyed by the command word). If no `usage`
   string is given, one is auto-generated from the declared args.

2. **Usage-string compilation → FSM** (`lexer.nim` → `parser.nim` →
   `backend.nim`): the usage string (e.g. `[-r] <src>... <dest>`) is
   tokenized by `SpecLexer` and recursively-descent parsed
   (`atom`/`sequence`/`choice` in `parser.nim`) into a graph of `State`/
   `Transition` objects. Each token becomes a `Matcher` (`Argument`,
   `Option`, `Options`, `Command`, or `Shortcut` for optional/repeated
   branches). `backend.prepare` (`simplify` + `sortTransitions`) collapses
   shortcut chains and orders transitions by matcher priority
   (`ord(MatcherKind)`) so, e.g., positional args aren't greedily consumed
   ahead of options. `genFsm` calls `result.prepare()` directly after
   building the FSM from the usage string. `dot.nim` renders any FSM to
   Graphviz dot for debugging/visualization but is not called anywhere by
   default — wire up `spec.fsm.dot` (or `cmd.spec.fsm.dot` for a
   subcommand) manually when debugging FSM construction. `scripts/dot2png.sh`
   renders that dot output to a viewable PNG (requires Graphviz's `dot`
   CLI installed separately). `genFsm` also
   scans each line of `spec.usage` individually
   (`parser.collectExplicitOptions`, called once per Usage Line, not once
   for the whole Usage String) for options mentioned by name on that line,
   so the `[options]` catch-all
   (`tkAnyOption`) excludes them from its own `Options` matcher — e.g. in
   `[options] --verbose`, `--verbose` can only be matched once (via its own
   explicit atom), not once via `[options]` and again via the explicit
   mention. An option named explicitly on one Usage Line is unaffected on a
   different Usage Line, where it remains reachable through that line's
   own `[options]`. An explicitly-named option still requires its own
   `...` to be repeated. A catch-all-only option is different: every
   option reachable only through `[options]` is repeatable by default,
   with no `...` needed on the catch-all itself (`fsm.nim`'s `Options`
   matcher re-tries the whole `m.opts` list on each pass with no
   per-option memory) — so any catch-all-only option, flag or
   multi-value opt alike, can be matched more than once, not just "the
   group as a whole." Writing `[options]...` still parses but is a no-op;
   the trailing `...` no longer changes anything. An author who wants one
   specific option to stay single-match while the rest of the spec is
   still reachable via `[options]` mentions that option explicitly instead
   (without its own `...`), which excludes it from `m.opts` via
   `collectExplicitOptions` as above. See
   `docs/adr/0002-catch-all-options-repeatable-by-default.md` for why the
   catch-all's default differs from an explicitly-named Arg's.

3. **Runtime matching** (`fsm.nim`): actual `os.commandLineParams()` (or
   passed-in `args`) are first tokenized into `CmdLineToken`s
   (`tokenizeArgs`, order-independent w.r.t. options vs. positionals, with
   `--` ending option parsing and short-option clusters like `-abc` expanded).
   `walk` then recursively tries the FSM's transitions against the token
   stream, backtracking via a copied `ParseContext` (`fresh = pc`) on each
   branch attempt, accumulating the best-effort error `messages` from the
   deepest failed path so error messages point at the most specific match
   attempt, not just "invalid arguments". A successful walk populates
   `pc.matches: OrderedTable[Arg, seq[Match]]`, which is then fed back into
   each `Arg`'s `parse` method (see below) to actually convert/store values.
   After a successful walk, `Spec.parse` (`fsm.nim`, not to be confused with
   `Arg.parse` above) does one more pass entirely outside
   the FSM/backtracking machinery: for every `Arg` in `spec.args` with a
   non-empty `envName` (see below) that *wasn't* explicitly matched
   (`arg notin pc.matches`) and whose env var `existsEnv`, it calls
   `arg.setFromEnv(getEnv(name))` to apply the env value through the same
   conversion/validation path a CLI value would take. Doing this after
   `walk` rather than folding it into the FSM means an option only
   reachable via `[options]` (never explicitly attempted during matching)
   still picks up its env var, and `arg notin pc.matches` gives an explicit
   CLI value precedence for free with no extra bookkeeping.

4. **Value conversion** (`src/argumint.nim`, top): `ValueArg[T: not seq,
   multi: static bool]` / `FlagArg[T]` are generic ref objects holding a
   parsed `Option[seq[T]]`/`T`. A single `ValueArg` type backs both scalar
   args (instantiated as `ValueArg[T, false]`, storing its value as a
   1-element seq) and multi-value args (instantiated as `ValueArg[T, true]`,
   appending on each match). `arg*`/`opt*` construct the scalar arity only
   (`default: T = ""`); the multi-value arity is built by the separate
   `args*`/`opts*` procs (`default: seq[T] = newSeq[T]()`), *not* a second
   `arg*`/`opt*` overload — this used to be an overload distinguished by
   the `default` parameter's type (`default: seq[T]`, no fallback, so a
   seq default had to be given explicitly), but a bare `@[]` default gives
   Nim no element type to infer `T` from, forcing an explicit `arg[T](...)`
   instantiation every time. **Gotcha**: `args*`/`opts*` are deliberately
   separate procs, not a second same-named overload of `arg*`/`opt*` with
   its own `= newSeq[T]()` default — prototyping that arrangement (two
   overloads of the same generic proc name, both with defaults) made Nim
   silently resolve the ordinary scalar call `arg("<name>", help = "...")`
   to the *seq* overload instead, or in a variant, fail to compile at all;
   both broke the common no-`default`-given scalar case. Distinct names
   sidestep the overload resolution entirely, mirroring the
   `defineArg`/`defineFlag` naming split used for the same reason (see the
   "Flags are special" note below). Because `multi` is a `static
   bool`, `ValueArg[T, false]` and `ValueArg[T, true]` are distinct
   concrete types to the compiler, so `toT`/`toSeqT` (see below) can be
   overloaded per-arity without ambiguity — you still can't accidentally use
   a scalar arg in a seq context or vice versa.
   `defineArg[T]` is a template that generates a `method parse` for a given
   `T` (both arities) by calling `parseImpl`, which converts the raw string
   via an implicit `converter` (`toInt`, `toFloat`, `toBool`, `toChar`;
   strings pass through) and then runs the arg's `Validator[T]`
   (`validators.nim`) if present — validation always happens against the
   scalar element type, never `seq[T]`, since it runs before the value is
   stored/appended. `defineArg[T]` also generates a `method defaultStr` per
   arity, used by `genHelp` to render `[default: <value>]` in help text
   (stringified via `$`; suppressed when the scalar default equals `T`'s
   zero value, i.e. `default(T)` — `""` for string, `0`/`0.0` for numeric
   types, `false` for bool — since that's the fallback used when no default
   was given (see `arg*`/`opt*`); an empty seq is the equivalent sentinel
   for the multi-value arity). The base `Arg.defaultStr` (commands, flags,
   message args) returns `""`, so flags never show a default. `defineArg[T]`
   likewise generates a per-arity `method validatorHelp`, which calls
   `self.validator.help()` (`validators.nim`) when a validator is present —
   `Validator[T].help` returns a short description per kind (`"choices: a,
   b, c"`, `"range: a..b"`, or a `check`/`checkIt` validator's own `desc`
   verbatim), also requiring `$` on `T`. `genHelp` combines `validatorHelp`
   and `defaultStr` into one bracket, `;`-separated (e.g. `[choices: foo,
   bar; default: foo]`), rather than showing them as two separate brackets.
   Flags are special: they don't take user converters —
   instead `defineArg[T](typeName, flagHandler)` registers per-type flag
   operations (e.g. `=`, `+=`, `-=` for `int`) via the `defineFlagOps` macro,
   stored in the `flagOps` `CacheTable` and looked up by `getFlagOps` at
   spec-construction time to validate that a flag variant's requested op
   (parsed out of the variant string itself, e.g. `--verbose+=2`) is actually
   supported for that type.
   Each variant's `(op, value)` (plus an optional user-supplied override) is
   stored as a `FlagOp[T] = tuple[op, arg, desc]` in `FlagArg[T].ops`, keyed
   by the bare variant name. `defineArg`/`defineFlag` also generate a
   `method variantDesc` per type, used by `genHelp` (via the `variantGroups`
   helper, see below) to auto-describe a flag variant when its behavior
   diverges from its siblings: `desc` (if the user supplied one via
   `flag*`'s `variantHelp: Table[string, string]` param) wins, else it falls
   back to generic wording from `op`/`arg` — `"Set to {arg}"` (`=`),
   `"Increase by {arg}"` (`+=`), `"Decrease by {arg}"` (`-=`), all
   type-generic (just `$arg`). Blank op (`""`) has no generic wording since
   its meaning is type-specific (toggle vs. increment vs. something else
   entirely for a custom type) — `defineArg[T](typeName, flagHandler)`
   leaves it as `""`, while `defineFlag[T](typeName, blankDesc,
   flagHandler)` lets a type's author supply it (`bool`/`int` use this for
   `"Toggle the value"`/`"Increment by 1"`; a custom type can too, the same
   way it already opts into flag support at all).
   **Gotcha**: `defineArg`/`defineFlag`/the private `defineFlagArg` they
   both delegate to are three *separately-named* templates, not one
   template overloaded three ways, even though `defineArg[T](typeName,
   flagHandler)` and `defineFlag[T](typeName, blankDesc, flagHandler)` look
   like they could be arity-overloads of each other. In this Nim version,
   two generic templates that share a name and each forward an `untyped`
   param down to a nested `{.inject.}` proc corrupt each other's hygiene —
   `op`/`arg` end up "undeclared identifier" inside `flagHandler`, even in
   whichever overload actually resolves. Distinct names avoid it entirely;
   don't collapse them back into overloads of `defineArg`. Relatedly,
   inside `defineFlagArg`, the generated `variantDesc` method destructures
   its local `(op, arg, desc)` as `(vOp, vArg, vDesc)` — reusing the plain
   names collides with the `{.inject.}`ed `op`/`arg` from the
   sibling-generated `parse*` method, since `inject` makes those visible
   across the whole template expansion, not just inside `flagHandler`.
   **Gotcha**: `std/strformat`'s `fmt"..."` cannot resolve *any* local
   identifier — not `self`, not a plain `let`, not a generic type param
   like `T` — when used inside a `method`/`proc` that is itself generated
   inside a template (as every method in `defineArg`/`defineFlag`/
   `defineFlagArg` is); it fails with "undeclared identifier" even for
   names that are clearly in scope. Use `%` (`strutils`) or `&`
   concatenation instead — e.g. `setFromEnv`'s `ParseError` message is
   built with `"expected $# for $# but got $#" % [$typeOf(T), self.env,
   envValue.escape]`, not `fmt"..."`. This is why the other
   `defineArg`/`defineFlagArg`-generated methods already avoid `fmt`.
   Converters `toT*[T](arg: ValueArg[T, false]): T` and
   `toSeqT*[T](arg: ValueArg[T, true]): seq[T]` return the field's value
   transparently at use-sites — code reads `spec.dest` rather than
   `spec.dest.value`.
   `defineSetFlag*[E: enum](elemType: typedesc[E])` is a ready-built
   extension on top of this same mechanism, registering flag support for
   `set[E]`: each variant's value names one element of `E`, and `=`/`+=`/
   `-=`/`*=` set/include/exclude/intersect it (`value = value * arg` for
   `*=`) (`FlagOp[T].arg` is already a full `T`, so for `T = set[E]` it's
   naturally a singleton set once parsed — no core `flag*`/`defineFlagArg`
   changes needed; `+=`/`-=` already *are* union/difference at the set
   level via `incl`/`excl`, so `*=` is the only operator that needed adding
   as new — see `variantValues` below for how a variant gets more than one
   element into `arg` in the first place). Call it once per concrete enum
   before declaring `flag[set[E]](...)`, the same opt-in discipline as
   `Priority`/`Level`/`Speed`. Plain `set[int]` isn't supported (Nim's `set`
   needs a bounded ordinal; a raw 64-bit `int` doesn't fit) — enum element
   types only.
   `flag*`'s `variantValues: Table[string, T]` param (keyed by bare flag
   name, same convention as `variantHelp`) is the escape hatch from string
   parsing entirely: a variant's `arg: T` can be supplied directly as typed
   Nim code instead of text in `variants` (e.g. `--priority=high`) — useful
   for a `T` with no natural short string spelling, or to reference an
   existing value (a `const`, a computed expression) rather than
   re-spelling it. This is what makes a multi-element `set[E]` variant
   practical: `variantValues = {"--warm": {red, orange, yellow}}.toTable` is
   just an ordinary Nim set literal, no new grammar needed. A variant may
   get its value from `variants` or `variantValues`, not both (`SpecDefect`
   if both are given); `<op>` always comes from `variants` regardless —
   only `<value>` moves. Nothing else in the flag pipeline changes:
   `variantDesc`'s auto-generated wording (`"Set to " & $vArg`, etc.)
   already stringifies whatever `arg` turned out to be, so a
   `variantValues`-supplied value flows through identically to a
   string-parsed one everywhere downstream.
   **Gotcha**: `defineSetFlag`'s body must build the `set[E]` type expression
   from its `elemType: typedesc[E]` *parameter*, not from the bare generic
   symbol `E`, when passing it into `defineArg(set[...]): ...`. `defineArg`
   forwards that type expression through further templates down to
   `defineFlagOps`, a `macro` with an `untyped` parameter — `untyped`
   parameters carry raw, unresolved AST, and `E` used there resolves to
   *`defineSetFlag`'s own generic-parameter symbol* (its `repr` is literally
   `"E"`), not the concrete type the caller instantiated it with; `elemType`,
   being an ordinary parameter whose bound value at the call site
   (`defineSetFlag(Color)`) is the literal `Color` expression, carries the
   concrete type through correctly (`defineFlagOps` keys its `flagOps`
   `CacheTable` on `typeName.repr`, e.g. `"set[Color]"` — it used to key on
   `$typeName`, but `system.$`/`macros.$` doesn't support compound AST node
   kinds like the `nnkBracketExpr` a generic instantiation produces; `repr`
   does).
   **Gotcha**: nesting `defineArg(set[elemType]): case op ... value = arg
   ...` *inside* another template's body (`defineSetFlag`, rather than
   calling `defineArg` directly at top level the way `Priority`/`Level`/
   `Speed` do) makes the injected `value` from `defineFlagArg`'s
   `handleFlag` proc get shadowed by an unrelated same-named symbol already
   in scope (here, `macrocache.value`, since `macrocache` is imported at the
   top of this file) — the compiler warns "a new symbol 'value' has been
   injected... however macrocache.value(...) captured at the proc
   declaration will be used instead" and then fails with "'value' cannot be
   assigned to". Fixed with a module-level `{.experimental: "openSym".}` (top
   of `src/argumint.nim`), which makes Nim prefer the later-injected symbol
   over one merely visible at the enclosing template's definition scope.
   Only needed because of this extra layer of template nesting — the
   directly-called `Priority`/`Level`/`Speed` pattern doesn't hit it.
   **Gotcha**: appending to `self.value` (a `ValueArg[T, true]`'s
   `Option[seq[T]]`) via `self.value = some(self.value.get & @[tmp])` silently
   corrupts earlier elements under ORC — this only manifests once the object
   type carries an extra `static bool` param alongside `T`. `parseImpl` works
   around it by copying `self.value.get` into a local `var` and calling
   `.add` before reassigning; don't revert to the inline `get(...) & @[...]`
   form.

   `opt*`/`flag*` (not `arg*`/`args*`/`opts*` — env vars map naturally to a
   single named value, which positional/multi-value args don't have) take
   an `env` param naming an environment variable that can supply the
   option's value when omitted from the CLI, at a lower precedence than an
   explicit CLI value but higher than the arg's own coded `default` (see
   the `Spec.parse` env sweep, above, and the required-vs-optional gotcha,
   below). `ValueArg`/`FlagArg` each carry an `env: string` field, and
   `defineArg`/`defineFlagArg` generate per-type `envName`/`setFromEnv`
   overrides of the `Arg` base methods (`backend.nim`) — `envName` just
   returns `self.env`; `setFromEnv` funnels the fetched value through the
   same conversion path a CLI value takes (`parseImpl` for `ValueArg`; for
   `FlagArg`, converts to `T` and applies via the flag's `=` op
   specifically, regardless of what ops its variants declare, since `=` is
   the one op every flag type universally supports — `flag*` raises
   `SpecDefect` at construction time if `env` is given for a type whose
   `flagHandler` doesn't support `=`, rather than failing only when the env
   var happens to be set at runtime). `genHelp` folds a non-empty `envName`
   into the same annotations bracket as `validatorHelp`/`defaultStr`, e.g.
   `[default: 8080; env: SERVE_PORT]`.

   `Spec.width` (default `terminalWidth()`, i.e. `std/terminal`'s
   auto-detected terminal width -- itself falling back to `DefaultWidth = 80`
   when no terminal can be detected, e.g. output is piped and `COLUMNS` isn't
   set) and `Spec.maxVariantsWidth` (default `DefaultMaxVariantsWidth = 30`)
   control `genHelp`'s wrapping: `width` wraps usage lines (`formatUsage`)
   and each row's help/description text, while `maxVariantsWidth` caps the
   "variants" column (e.g. `-v, --verbose, --quiet`) so one arg with many
   aliases can't inflate the shared column width for every other row. `genHelp` doesn't iterate
   `arg.variants` directly for this — it goes through `arg.variantGroups()`
   (`argumint.nim`, near `genHelp`), which groups an arg's variants by their
   `variantDesc` text and returns one group per distinct behavior (almost
   always exactly one group, since most args/flags have no divergent
   variants — see the "Flags are special" note above). `colWidth` is
   computed from the widest single *group's* joined names, not the widest
   whole-`Arg`'s, so a flag that splits into several rows doesn't inflate
   the column by its full alias list. Each group becomes its own row: the
   first group (declaration order) keeps the arg's shared `help` text and
   uses the normal 2-space row margin — plus, only when `variantGroups().len
   > 1` (i.e. there's actually something to contrast it against) and its own
   `variantDesc` is non-empty, that desc is appended as `[action: ...]`,
   reusing the same bracket slot `validatorHelp`/`defaultStr` populate for
   `arg()`/`opt()` (always `""` for flags, so otherwise unused there) —
   deliberately labeled `action:`, not `default:`, so it can't collide with
   a hypothetical future `[default: <value>]` for a flag's own starting
   `default: T` value (currently never surfaced, since `FlagArg` doesn't
   override `defaultStr`); any
   further group (a divergent variant) shows its own `variantDesc` text
   instead and is indented with
   the same 4-space `continuationIndent` used for wrap-continuation lines
   (deliberately reused for both cases — a divergent-variant row and a
   wrapped-variants overflow line both read as "subordinate to the row
   above", not a new top-level row). When a row's variants exceed the cap
   (regardless of which group it is), `genHelp` wraps them into their own
   `wrapWords`-wrapped lines and zips them line-by-line against the
   (independently wrapped) help-text lines, so the help text stays inline
   with the *first* wrapped variants line rather than being pushed below
   all of them. `0` disables the cap (unlimited width, the pre-cap
   behavior). Neither `width` nor `maxVariantsWidth` is a parameter to
   `command*` — both cascade from the top-level `newSpec`/`parse*` call into
   every nested subcommand spec via `setWidth`, so they only need to be set
   once regardless of nesting depth.

5. **Subcommands**: `command*` builds a `CommandArg` wrapping its own nested
   `Spec` (built via `newSpec` from a nested arg tuple), optionally binding a
   `handler` closure. A subcommand's FSM is spliced into the parent's FSM as
   a single `Command`-kind transition (see `atom()`'s `tkCommand` branch in
   `parser.nim`), with all of the subcommand's terminal states wired via
   shortcut back to a single continuation state in the parent graph.

## Key invariants / gotchas

- Only one of positional args, options, or commands is expected per spec
  level in typical usage, but nothing enforces this — the `usage` string
  alone determines what's syntactically valid at each grammar position.
- `arg`/`opt`/`flag`/`command` variant strings are validated with the PEG
  patterns near the top of `src/argumint.nim` (`PositionalVariantFormat`,
  `OptionalVariantFormat`, `FlagVariantFormat`) — errors here raise
  `SpecDefect`, not `ParseError` (spec-construction-time vs. parse-time
  failures are deliberately different exception types).
- `SpecDefect` is a `Defect` (raised on malformed developer-authored specs;
  not meant to be caught), while `ParseError`/`ValidationError`/`MessageError`
  are `CatchableError`s raised at user-input parse time. `parse*`
  (`argumint.nim`, both the `Spec` and `tuple` overloads) lets all of these
  propagate to the caller — it's `parseOrQuit*` (same two overloads) that
  catches them, across two separate `try/except` blocks, one per overload:
  the `tuple`-overload's block only catches `SpecDefect` from `newSpec` (then
  delegates to the `Spec`-overload's `parseOrQuit`), while the
  `Spec`-overload's block catches `ParseError`/`ValidationError`/
  `HelpError`/`MessageError` (each `quit()`s with a formatted message).
  `parse*` is the recommended entry point for embedding argumint in a larger
  program; `parseOrQuit*` is for a bare CLI `main()` that should just print
  an error and exit. `newSpec*`/`Spec.parse` remain public for callers who
  need the `Spec` object itself (inspecting `.usage`/`.dot`/
  `.maxVariantsWidth`, or parsing it repeatedly).
- `Arg.hash` is keyed on `self.variants[0]` (the arg's first declared name,
  via `name()`), but there is no custom `==` for `Arg` — equality falls back
  to Nim's identity-based `EqRef` for ref types. A hash collision between
  two distinct `Arg`s that happen to share a first variant is harmless: the
  `MatchTable`/state dedup logic in `fsm.nim`/`backend.nim` still
  disambiguates them by identity, not by name.
- `newSpec` builds the FSM first, then calls `autoFillUsage` to patch any
  gaps: it uses `backend.referencedArgs` to collect every `Arg` actually
  referenced by a matcher, then appends usage lines for whatever isn't
  reachable and rebuilds the FSM once more if anything changed. This runs
  regardless of whether `usage` was left blank or passed in explicitly, and
  the fill-in rule differs by category:
  - **Commands** that are unreachable are joined into a single `(cmd1 |
    cmd2)` alternation line (all their variants flattened into one `|`-list)
    rather than one line per command, so a shared `[options]` prefix isn't
    repeated for each one. **`MessageArg`s** (e.g. `help()`) are still filled
    in per-arg — each missing one gets its own appended line — since they
    never carry the `[options]` prefix to begin with (see below) and are
    independently optional to mention. Mentioning one variant of a
    multi-variant arg counts as reachable; it won't be duplicated.
  - **Positional args** are all-or-nothing: only auto-appended (as one
    joined `<a> <b>` line, in declaration order) when *none* of them are
    reachable yet. A partially-specified sequence (some mentioned, some
    not) is left alone — there's no safe way to guess where the missing
    one belongs.
  - **Options** (`opt`/`flag`, non-`MessageArg`) aren't their own usage
    line; `[options]` (`tkAnyOption` in `parser.nim`'s `atom()`) — which
    itself never pulls in a `MessageArg`, by design — rides along as a
    prefix on whatever command/positional line gets auto-appended above.
    If nothing else gets appended (e.g. a spec with only options, no
    commands or positional args) but some option is still unreachable, a
    standalone `[options]` line is added as a fallback. Weaving `[options]`
    into an arbitrary hand-written line that's missing it is not attempted.
- `ValueArg[T, false].defaultStr` (used for `[default: <value>]` in help
  text) compares `self.default[0]` against `default(T)` to decide whether
  a default is "meaningfully set" or just T's zero value. This means `T`
  must support both `default(T)` and `==`. Nearly every type does, but a
  `{.requiresInit.}` object (which disallows default-construction) would
  fail to compile here if used as an `arg`/`opt` value type — not
  considered worth guarding against, since a user reaching for such a type
  here is unlikely, but worth knowing if `defineArg` ever fails to compile
  for a custom `T` with an unhelpful-looking error.
- An `opt`/`flag`'s `env` var is only ever consulted when that option is
  already optional in the usage grammar (bracketed, e.g.
  `[--port=<port>]`, or reachable only via `[options]`). A *required*
  (unbracketed) option omitted from the CLI still fails FSM matching
  (`missing option ...`) before `Spec.parse`'s env sweep ever runs, even if
  its env var is set — this mirrors how a coded `default` on a required
  option is already dead code today (`walk()` fails first, so it's never
  reached); `env` occupies the exact same fallback slot. This is
  deliberate: letting env silently satisfy a required option would mean
  `--help`'s Usage: line could show something as mandatory that secretly
  isn't, depending on the runtime environment. The bracket stays the
  single source of truth for requiredness.

## Agent skills

### Issue tracker

Issues live in GitHub Issues for squattingmonk/argumint, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (CONTEXT.md + docs/adr/ at repo root). See `docs/agents/domain.md`.
