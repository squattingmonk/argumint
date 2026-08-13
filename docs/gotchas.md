# Nim implementation gotchas

Compiler/language quirks discovered while building argumint that cost real
debugging time. Read this before touching `defineArg`/`defineFlag`/
`defineFlagArg` (`src/argumint.nim`) or anything else that generates methods
inside a template.

- **`args*`/`opts*` are separate procs from `arg*`/`opt*`, not overloads of
  them.** Prototyping a second same-named overload of `arg*`/`opt*` with its
  own `default: seq[T] = newSeq[T]()` made Nim silently resolve the ordinary
  scalar call `arg("<name>", help = "...")` to the *seq* overload instead (or,
  in one variant, fail to compile at all) — both broke the common
  no-`default`-given scalar case. Distinct names sidestep overload resolution
  entirely; this mirrors the `defineArg`/`defineFlag` naming split below.

- **A generic proc's defaulted parameter can be rescued for a bracket-less
  call by a sibling non-generic overload -- but only if none of its *other*
  defaulted parameters use a bare `nil` literal for a distinct generic
  instantiation type.** `arg*`/`opt*`/`args*`/`opts*`'s `validator:
  Validator[T] = nil` and `flag*`'s `clamp: FlagClamp[T] = nil` each need
  `T` concretized just to build that parameter's *type* -- for a
  bracket-less, no-`default` call, nothing else pins `T` down, so this
  fails with a hard `cannot instantiate: 'T'` that aborts compilation
  before overload resolution ever gets to prefer a matching non-generic
  sibling proc, confirmed via scratch compile regardless of declaration
  order. The fix is narrower than "avoid all `T`-dependent parameters",
  though: `flag*`'s `ops: varargs[FlagOpGroup[T]] = @[]` is never
  poisonous, because its default is a *call* (or literal seq/array
  construction), not a bare `nil`. Swapping
  `nil` for a call-based equivalent -- `noValidator[T](): Validator[T] =
  nil` (`argumint/validators`), `noClamp[T](): FlagClamp[T] = nil`
  (`argumint/flagclamp`) -- removes the poison entirely, and a generic
  proc (`default(T)`) plus a concrete sibling overload (e.g. `arg*`'s
  bare-string form, `flag*`'s bare-bool form) then correctly resolves the
  bracket-less call to the concrete overload. See
  `docs/adr/0024-flag-arg-opt-default-t-and-bare-call.md`.
  One more wrinkle specific to `flag*`: its bare-bool overload's body calls
  `flag[bool](...)` eagerly, which needs `"bool"` already registered in the
  compile-time `flagOps` table by `defineFlag bool, ...` -- so that overload
  has to be declared textually *after* that `defineFlag` call, not next to
  `flag*[T]` up with the other constructors.

- **`defineArg`/`defineFlag`/`defineFlagArg` are three separately-named
  templates, not one template overloaded three ways**, even though
  `defineArg[T](typeName, flagHandler)` and `defineFlag[T](typeName,
  blankDesc, flagHandler)` look like arity-overloads of each other. Two
  generic templates sharing a name, each forwarding an `untyped` param down
  to a nested `{.inject.}` proc, corrupt each other's hygiene in this Nim
  version — `op`/`arg` end up "undeclared identifier" inside `flagHandler`,
  even in whichever overload actually resolves. Distinct names avoid it
  entirely — don't collapse them back into overloads of `defineArg`.
  Relatedly, inside `defineFlagArg` the generated `variantDesc` method
  destructures its local `(op, arg, desc)` as `(vOp, vArg, vDesc)` — reusing
  the plain names collides with the `{.inject.}`ed `op`/`arg` from the
  sibling-generated `parse*` method, since `inject` makes those visible
  across the whole template expansion, not just inside `flagHandler`.

- **`std/strformat`'s `fmt"..."` cannot resolve *any* local identifier** —
  not `self`, not a plain `let`, not a generic type param like `T` — when
  used inside a `method`/`proc` that is itself generated inside a template
  (as every method in `defineArg`/`defineFlag`/`defineFlagArg` is); it fails
  with "undeclared identifier" even for names clearly in scope. Use `%`
  (`strutils`) or `&` concatenation instead — e.g. `setFromEnv`'s
  `ParseError` message is built with `"expected $# for $# but got $#" %
  [$typeOf(T), self.env, envValue.escape]`, not `fmt"..."`.

- **`defineSetFlag`'s body must build the `set[E]` type expression from its
  `elemType: typedesc[E]` *parameter*, not from the bare generic symbol
  `E`**, when passing it into `defineArg(set[...]): ...`. `defineArg`
  forwards that type expression through further templates down to
  `defineFlagOps`, a `macro` with an `untyped` parameter — `untyped`
  parameters carry raw, unresolved AST, and `E` used there resolves to
  *`defineSetFlag`'s own generic-parameter symbol* (`repr` literally `"E"`),
  not the concrete type the caller instantiated; `elemType`, being an
  ordinary parameter bound at the call site (`defineSetFlag(Color)`), carries
  the concrete type through correctly. `defineFlagOps` keys its `flagOps`
  `CacheTable` on `typeName.repr` (e.g. `"set[Color]"`) rather than `$typeName`
  for the same reason — `system.$`/`macros.$` doesn't support compound AST
  node kinds like the `nnkBracketExpr` a generic instantiation produces;
  `repr` does.

- **Nesting `defineArg(set[elemType]): case op ... value = arg ...` inside
  another template's body** (`defineSetFlag`, rather than calling `defineArg`
  directly at top level the way `Priority`/`Level`/`Speed` do) makes the
  injected `value` from `defineFlagArg`'s `handleFlag` proc get shadowed by
  an unrelated same-named symbol already in scope — here, `macrocache.value`,
  since `macrocache` is imported at the top of the file. The compiler warns
  "a new symbol 'value' has been injected... however macrocache.value(...)
  captured at the proc declaration will be used instead" and then fails with
  "'value' cannot be assigned to". Fixed with a module-level
  `{.experimental: "openSym".}` (top of `src/argumint.nim`), which makes Nim
  prefer the later-injected symbol over one merely visible at the enclosing
  template's definition scope. Only needed because of this extra layer of
  template nesting — the directly-called `Priority`/`Level`/`Speed` pattern
  doesn't hit it.

- **Appending to `self.value` (a `ValueArg[T, true]`'s `Option[seq[T]]`) via
  `self.value = some(self.value.get & @[tmp])` silently corrupts earlier
  elements under ORC** — this only manifests once the object type carries an
  extra `static bool` param alongside `T`. `parseImpl` works around it by
  copying `self.value.get` into a local `var` and calling `.add` before
  reassigning; don't revert to the inline `get(...) & @[...]` form.

- **`all`/`any` (`validators.nim`) can't take `desc` as a plain defaulted
  param (`desc = ""`) alongside a `varargs` param.** Nim can't resolve a call
  with more than one `varargs` element against an overload that also has a
  defaulted parameter following the `varargs` (a bare `all(a, b)` fails to
  compile; `all(a, b, desc = "x")` or `all(a)` alone both compile fine, since
  either naming the trailing param or supplying exactly one `varargs`
  element sidesteps the ambiguity). Each is instead two separate overloads —
  one with a required `desc`, one `varargs`-only that delegates to the first
  with `desc = ""` — rather than one proc with a default value.

- **An implicit `converter string -> T` is only found at a generic proc's
  call site, not at its definition site.** `defineFlagArg`'s generated
  `handleFlag` calls our own `toInt`/`toFloat`/etc. converters explicitly for
  the built-in types rather than relying on the implicit `arg = matches[2]`
  conversion, because `flag[T]` is instantiated wherever a caller writes it
  -- an implicit converter only applies if it's visible in *that* scope, not
  just here. Our built-in converters are kept private (a public `converter`
  callable by name could otherwise silently hijack unrelated overload
  resolution, e.g. a plain `"x" in someString`, in a module that doesn't
  import `std/strutils` itself); a user's own `T` still gets the implicit
  conversion, as long as they define `converter toMyType(value: string): T`
  somewhere visible at their own `flag[T](...)` call site.

- **`ValueArg[T, false].defaultStr` requires `T` to support both `default(T)`
  and `==`** (it compares `self.default[0]` against `default(T)` to decide
  whether a default is "meaningfully set"). Nearly every type does, but a
  `{.requiresInit.}` object would fail to compile here if used as an
  `arg`/`opt` value type. Not considered worth guarding against, but worth
  knowing if `defineArg` ever fails to compile for a custom `T` with an
  unhelpful-looking error.

- **`system.quit(errormsg: string, errorcode)`'s doc comment ("a shorthand
  for `echo(errormsg); quit(errorcode)`") is only true under
  `nimscript`/`js`/standalone.** On a normal compiled target it actually
  writes via `cstderr.rawWrite` — stderr, not stdout. `parseOrQuit*`'s
  `HelpError`/`ValidationError`/etc. branches don't care (both streams reach
  a terminal the same way), but `CompletionError` (`docs/adr/
  0012-fsm-driven-shell-completion.md`) does: a shell completion adapter
  reads candidates via `$(...)` command substitution, which only captures
  stdout, so reusing the shared `quit(e.msg, QuitSuccess)` branch silently
  swallows every candidate. Caught only by actually sourcing a generated
  completion script and driving it in a live shell — the unit tests, which
  only asserted on the raised exception's `msg` field, couldn't have caught
  it, since `quit()` never actually runs inside a test process. Needs its
  own `except CompletionError as e: echo e.msg; quit(QuitSuccess)` branch,
  ordered before the general `except MessageError` catch the same way
  `HelpError`'s already is.

- **`hash(x: ref T)` requires `-d:nimPreviewHashRef`.** `HashSet[State]`/
  `Table[State, ...]` (used by `collectFrontier`, and pre-existing in
  `fsmgraph.nim`'s `terminals`/`collectArgs`/`sortTransitions`) only compile
  because `config.nims` sets this flag project-wide (see CLAUDE.md). A
  scratch file compiled *outside* this project's directory tree (e.g. in
  `/tmp`) won't pick up `config.nims` automatically and fails with a
  confusing "type mismatch: expected ... Expression: hash(key)" error with
  no obvious mention of `ref`/`State` — pass `-d:nimPreviewHashRef` by hand
  when compiling a throwaway repro outside the repo.

- **`sequence`'s local `add` helper (`parser.nim`) copies each child atom's
  `Transition`s onto its own growing state rather than reusing them** — `for
  tr in x.transitions: b.add(tr.next, tr.matcher)` constructs a brand new
  `Transition` per copy. This only became a problem once something needed to
  mutate a matcher *after* `atom` returned it (the `[options]` catch-all's
  exclusion set isn't final until the whole Usage Line is parsed, per
  `docs/architecture.md`'s "Usage-string compilation" section): a
  `Transition` reference captured inside `atom` goes stale the instant
  `sequence` copies it, silently discarding any later patch applied to it.
  Fixed by making `Matcher` (`backend.nim`) a `ref object` instead of a
  value `object` — copying a `Transition` (or anything else holding a
  `Matcher`) now copies the reference, not the data, so a stashed `Matcher`
  ref stays patchable no matter how many times `sequence` copies it this
  way (`choice` doesn't hit this -- it wires children together with fresh
  `newShortcut()` transitions instead of copying an existing child's
  transitions). Caught only by an actual failing test
  (`[options] --verbose` no longer excluding the explicit `--verbose`) —
  the bug was invisible from the code itself, since the patch loop *looked*
  correct and even visibly mutated the (wrong, orphaned) object when traced.

- **A `State`'s `terminal` flag, once set, doesn't un-set itself when more
  transitions are spliced onto it later -- but recomputing it from scratch
  on every splice is *also* wrong, because "scratch" means different things
  depending on whether `root` is fresh or already simplified.** `genFsm`
  (`parser.nim`) builds a spec's root by calling `addUsageLines`, which
  marks the root `terminal = true` only when it ends up with no transitions
  at all (an empty `usage` string -- nothing to match). `autoFillUsage`
  (`argumint.nim`) can later discover unreachable args/commands/options for
  that same spec and call `addUsageLines` again on that *same* root object
  to splice on real transitions (rather than re-parsing already-built lines
  from scratch) -- if a stale `terminal = true` left over from an earlier
  *empty-`lines`* call weren't cleared, the FSM would wrongly accept "no
  more input" at a root that now requires real args.

  The first fix for that (recomputing `root.terminal = root.transitions.len
  == 0` unconditionally as `addUsageLines`'s last step) introduced a second
  bug (issue #6): by the time `autoFillUsage` runs, `root` is usually
  `spec.fsm` *after* `genFsm`'s own `prepare()`/`simplify()` pass has
  already folded a fully-skippable usage line (e.g. `[-- <arg>...]`) down
  into `root.terminal = true` with its Shortcut "skip" edge removed
  entirely (`simplifySelf`, `fsmgraph.nim`) -- at that point `root.terminal`
  is no longer stale bookkeeping, it's an earned fact with no other trace of
  it left in the graph to rediscover. Unconditionally recomputing from
  `transitions.len` alone clobbers that fact back to `false` the moment any
  new line (e.g. an auto-filled `(-h | --help)`) is spliced on, since real
  transitions already exist. Fixed by snapshotting `hadTransitions =
  root.transitions.len > 0` and `wasTerminal = root.terminal` *before* the
  splice loop runs, then computing `root.terminal = root.transitions.len ==
  0 or (hadTransitions and wasTerminal)`: the `hadTransitions` guard is what
  distinguishes "stale flag on a root that started genuinely empty" (must
  clear) from "earned flag on a root that already carried real, simplified
  content" (must survive).

  Caught by tests that actually call `.parse()` with zero args, not just
  ones asserting on the rendered `s.usage` string (which stays correct
  either way and wouldn't catch a regression here): `tests/test_argumint.nim`'s
  `"autoFillUsage"` suite has one covering an empty-`usage`-then-filled
  spec, and a second (`"splicing onto an already-skippable line preserves
  skippability (#6)"`) covering all four `autoFillUsage` splice categories
  (MessageArgs, commands, positionals, `[options]`) against a pre-existing
  skippable line.

- **`simplifySelf`'s old shortcut-collapsing check only ever compared against
  the immediate `s`/`next` pair, so it couldn't detect a foreign multi-state
  shortcut cycle merely *reached* from `s`, and looped forever.** A
  bracketed-and-repeated atom (`[X]...`) compiles to its own self-contained
  2-state mutual-shortcut pair (`S1 <-> S3`); two adjacent such atoms in one
  usage line splice a live shortcut edge from the first pair's end state
  into the second pair (`T1 <-> T3`). Expanding that edge from an unrelated
  state correctly excluded a *direct* back-reference (`tr.next in [s,
  next]`), but `T1`/`T3` alternate as `next` across iterations and neither
  ever equals `s` itself — so the state kept absorbing `T1`'s shortcut, then
  `T3`'s, forever, with `transitions.len` pinned constant the whole time
  (confirmed via instrumentation: >2,000,000 calls on the same state). Fixed
  by replacing the iterative delete-and-copy loop with a proper
  epsilon-closure (`shortcutClosure`, same technique as epsilon-NFA→DFA
  construction): every state reachable from `s` via shortcuts, computed once
  with its own bounded visited-set, so it terminates regardless of chain
  depth or cycle shape. See `docs/architecture.md` §2 and GitHub issue #4.

- **A nested `proc` that captures an outer `var seq[T]` named `result` (a
  closure inside a proc, referencing `result` from its enclosing scope)
  fails under ORC** with "'result' is of type <seq[T]> which cannot be
  captured as it would violate memory safety" — happened inside
  `pendingOptionalArgs` (`fsm.nim`) when a nested `proc consider(arg: Arg)`
  tried to `result.add arg`. Inline the logic into the loop instead of
  factoring it into a nested closure that captures `result`.

- **`import std/options` (even aliased, `import std/options as opt`) breaks
  every `case ... of Option:` branch matching `MatcherKind.Option`** (and
  `.Options`) in `backend.nim`/`fsm.nim`, with a confusing "type mismatch:
  got 'typedesc[Option]' for 'Option' but expected 'MatcherKind = enum'".
  `std/options.Option` is a same-named *type*, not just a same-named enum
  value, and it wins the bare-identifier lookup in a case-branch position
  regardless of import aliasing -- an `as` alias only adds the qualified
  form, it doesn't remove the unqualified one from scope. Fixed by
  `from std/options import some, none, isSome, get` (the non-colliding
  procs, usable unqualified) and referencing the type itself as
  `options.Option[T]` everywhere -- `from ... import` still allows this
  qualified form for `Option` even though it wasn't named in the import
  list, so no separate `import std/options` is needed at all. See
  `docs/adr/0015-per-arg-env-delimiter-overrides.md`.

- **A `##` doc comment as the first statement inside a `{.pure.}` enum's
  body broke expected-type-based disambiguation for a same-named value in
  a *different* enum**, discovered adding `OptsEnd` to `MatcherKind`
  (`docs/adr/0020-usage-string-end-of-options-marker.md`). `MatcherKind`
  and `ArgKind` both declare a `Command` value; `CommandArg(kind: Command,
  ...)` (`argumint.nim`) relies on the field's known type (`ArgKind`) to
  pick the right one, since neither enum's values are otherwise in scope
  unqualified (both are `{.pure.}`). Writing:
  ```nim
  MatcherKind* {.pure.} = enum
    ## Declaration order doubles as match priority ...
    Option, Options, Command, Argument, OptsEnd, Shortcut
  ```
  made that same call resolve to `MatcherKind.Command` instead, failing
  with "type mismatch: got 'MatcherKind' for 'Command' but expected
  'ArgKind = enum'" — a different value silently winning, not an
  ambiguity error. Moving the identical prose to a plain `#` comment
  *above* the `enum` line (outside its body) fixed it with no other
  change. Root cause not fully diagnosed (plausibly the doc comment
  changes how the enum's node is represented during `sem`, shifting
  which candidate a same-named lookup with a known expected type prefers)
  — treat any `##` comment as the first statement inside a `{.pure.}`
  enum sharing a value name with another enum in scope as suspect, and
  verify with a scratch compile rather than assuming comment placement
  inside an enum body is inert.

- **A generated method's unqualified calls resolve against whatever module
  *instantiates* the generic/template, not against `argumint.nim`'s own
  imports.** Under this project's module-level `{.experimental: "openSym".}`
  (see the `macrocache.value` entry above), any `defineArg`/`defineFlag`/
  `defineFlagArg`/`defineSetFlag` instantiation -- for *any* custom type,
  single-layer or nested inside another template -- generates methods
  calling `self.validator.help()`/`self.validator.completions()`
  (`validators.nim`), `self.name(...)` (`backend.nim`), and `value.escape`
  (`strutils.escape`, inside `parseImpl`'s `ValueError` handler), and each
  of those resolves against the *calling file's* imports at instantiation
  time. `argumint.nim` defends against this today by re-exporting exactly
  what's needed (`export validators`, `export flagclamp`, `export
  backend.name`, `export strutils.escape` -- see
  `docs/adr/0017-argumint-reexports-for-custom-arg-types.md`), so
  `import argumint` alone is enough for a caller registering a custom type.
  Adding a *new* generated method that calls some other unqualified symbol
  from a module not yet re-exported will reintroduce this exact failure
  mode (a confusing "type mismatch"/"undeclared field" error, not an
  obviously import-related one) for that new symbol -- the fix is another
  narrow or wholesale `export` in `argumint.nim`, matching whichever pattern
  that ADR uses, not a per-caller workaround.

- **This same `openSym` mechanism also bit a non-generated, ordinary
  generic proc**: `command*[S]`'s body has always written the object
  constructor field bare, `CommandArg(kind: Command, ...)` -- relying on
  the field's known type (`ArgKind`) to disambiguate `Command` from
  `MatcherKind`'s own same-named value (see the `##`-doc-comment entry
  above; both enums are declared in `backend.nim`). This resolved fine as
  long as `command*` was only ever instantiated from within
  `argumint.nim` itself. Adding `OptsEnd` to `MatcherKind` (unrelated to
  `Command` itself) was enough to make a *test file* instantiation --
  `tests/test_argumint.nim`, which does `import argumint/backend`
  directly, alongside `import argumint` -- resolve the same bare
  `Command` to `MatcherKind.Command` instead, failing with the same "type
  mismatch: got 'MatcherKind' for 'Command' but expected 'ArgKind =
  enum'". Per the manual's [openSym
  page](https://nim-lang.org/docs/manual_experimental.html#injected-symbols-in-generic-procs-and-templates),
  this is exactly what `openSym` does: an unqualified symbol inside a
  generic body is "open," re-resolved against *the instantiating scope*
  each time, not "closed" to whatever it captured when `argumint.nim`
  itself was sem-checked.
  **`bind Command` at the top of the proc body, tried as a fix, did
  *not* work** -- confirmed by scratch-reverting the real fix and
  swapping it in: the error persisted verbatim. `bind` only forces a
  symbol to close over whatever it resolves to via ordinary *lexical*
  scope lookup at the point of the `bind` statement itself; it doesn't
  carry forward the expected-type context (the `CommandArg.kind: ArgKind`
  field type) that normally disambiguates two same-named enum values in
  an object-constructor position. Since `Command` is ambiguous by *name*
  alone at that point (no expected type attached to a bare `bind
  Command` statement), `bind` just closes over whichever candidate
  ordinary ambiguous-lookup rules hand it -- which is not guaranteed to
  be the one an expected-type-directed lookup would have picked, and
  here handed back the wrong enum. The actual fix is to remove the
  ambiguity outright: qualify the constructor call itself, `kind:
  ArgKind.Command`. `bind` is the right tool when the *symbol itself* is
  unambiguous and the goal is only to stop it being re-resolved at
  instantiation time (e.g. locking a helper proc name); it's the wrong
  tool when the symbol is ambiguous *by name* regardless of timing, since
  there's no unambiguous single thing to bind to without type context.

- **A generic macro's own bound `[T]` doesn't resolve inside its body --
  it reads as an unresolved `"GenericParam"` regardless of how `T` was
  bound at the call site** (bracket, or inferred from an argument).
  Confirmed via scratch compile while investigating a macro-based
  rewrite for `flag*`/`flagOp*` (`docs/adr/0027-flag-op-declarations.md`)
  -- `T.repr`/`getType(T)`/`getTypeInst(T)` all print/return `"T"` or
  `"GenericParam"` inside `macro foo[T](...)`, never the concrete
  instantiated type. The only thing that does resolve is calling
  `.getTypeInst` on an argument *node* the caller actually passed for a
  non-`untyped` parameter (e.g. `default: T`) -- and only when the caller
  wrote that argument explicitly, not when it's supplied by the
  parameter's own default-value expression (see the next entry). This
  ruled out a macro-based fix for `flag*` entirely; `flag*`/`flagOp*`
  ended up as plain generic `proc`s instead, which don't have this
  problem (an ordinary generic proc's `T` behaves normally inside its own
  body).

- **A macro parameter's own default-value expression is never
  pre-resolved before the macro body runs, even for a "typed" (non-
  `untyped`) parameter.** `macro flag[T](default: T = default(T))` called
  as `flag[int]()` (bracket given, `default` omitted) hands the macro
  body the literal unevaluated expression `default(T)` for its `default`
  argument -- `default.getTypeInst` on that gives back `"default(T)"`
  (the expression's own repr), not `"int"`. This only fails when the
  argument is *omitted*; the exact same parameter resolves correctly to
  `"int"` when the caller writes `flag[int](default = 0)` explicitly.
  Five different workarounds (an explicit `typedesc[T]` parameter,
  defaulted several different ways) were scratch-compiled while
  investigating this for `flag*`'s `ops` rewrite and all failed the same
  way -- there is no default-value shape that sidesteps it. See
  `docs/adr/0027-flag-op-declarations.md`.

- **`varargs[T]` needs an explicit call-based default (`= @[]`), not none
  at all, or a bracket-less call to a sibling non-generic overload hits
  `docs/adr/0024`'s "cannot instantiate T" gotcha again.** `flag*[T](...,
  ops: varargs[FlagOpGroup[T]], ...)` with no default on `ops` broke
  `flag("--verbose")` (meant to resolve to the non-generic bare-bool
  overload) the same way a bare `nil` default on a `T`-dependent parameter
  did in that ADR -- a parameter whose *type* depends on an
  otherwise-unconstrained `T`, with nothing telling the compiler what to
  do about it, poisons overload resolution before it gets a chance to
  prefer the matching sibling overload. `ops: varargs[FlagOpGroup[T]] =
  @[]` (a call-based default, same shape as that ADR's proven-safe
  `noClamp[T]()`/`initTable[string, T]()` pattern) fixes it -- confirmed
  via scratch compile. Note `varargs`, not `seq`: a plain array literal
  (`[flagOp(...), ...]`) converts implicitly to `varargs[T]`/
  `openArray[T]` but not to `seq[T]`, which would otherwise force every
  caller to write `@[flagOp(...), ...]` instead.

- **`{.borrow.}` on a `distinct seq[T]` handles `len`/`==`/`$` but not
  `[]`, and never an `iterator`.** Adding operations to `ConfigKey`
  (`distinct seq[string]`, `docs/adr/0029-config-key-distinct.md`),
  `proc `[]`*(k: ConfigKey, i: int): string {.borrow.}` fails with
  `borrow from proc return type mismatch: 'T'` -- `seq`'s own `[]` returns
  a generic `T`, which the borrow machinery won't unify with a concrete
  `string` return, even though every instantiation would. Iterators can't
  carry `{.borrow.}` at all, so `items` (what makes `for segment in key`
  work) has to be written out too. Both are one-liners over
  `seq[string](k)`; the distinct-to-base conversion itself is free.

- **`std/importutils.privateAccess` does not survive template or generic
  instantiation in another module.** Making `Spec`'s bookkeeping fields
  private (`docs/adr/0030-core-types-exported-spec-opaque.md`) meant the
  library's own modules needed `privateAccess(Spec)` to keep reaching them.
  That works for ordinary procs, and for object construction -- but a
  generic proc or a template *declared* in a module holding
  `privateAccess` still fails with `undeclared field` when it's
  instantiated in a module that doesn't, because the field is resolved at
  the instantiation site. Verified both cases with scratch compiles. So
  `newSpec*(spec: tuple, ...)`, generic over the spec tuple and therefore
  instantiated in the caller's file, cannot touch `spec.fsm` directly --
  hence `beginSpec`/`finishSpec` (`argumint.nim`), two non-generic
  bookends the generic body delegates to. Any *new* generic or template
  that needs a private `Spec` field has to be split the same way.

  A template or generic declared in the same module as the type has no
  such problem: it reaches the private field wherever it's expanded, which
  is why `defineArg`/`defineFlag` can keep touching `ValueArg`/`FlagArg`'s
  private fields from a caller's file.

- **`system.deepCopy` rewrites closure environments: it preserves object
  identity across them, and it copies whatever they captured.** Both halves
  matter, and together they are why argumint has no `parsed*` overload
  taking an already-built spec tuple -- see
  `docs/adr/0031-parsed-fresh-spec-per-parse.md`.

  First: given a value holding both a `ref` and a closure that captured that
  same `ref`, `deepCopy` produces **one** new object reachable by both paths,
  not two unrelated copies -- verified standalone (`copied.box ==
  copied.get()` is `true`). This is what makes copying a spec tuple viable at
  all: `command*` binds its hooks as closures over the nested tuple at
  construction time, so any clone that mints new `Arg`s *without* rewriting
  that captured environment leaves every subcommand hook reading args nothing
  parses into. A hand-written `clone` `{.base.}` method on `Arg` would hit
  exactly that. Nim's documentation says nothing about closures here, so
  treat it as verified-but-undocumented.

  The flip side sinks the idea: the same rewrite copies state the hook
  *captured*, so a `command*` hook closing over a local variable reads
  correctly but its **writes land in the copy** and are silently lost. A
  captureless hook writing a global is unaffected (a global isn't in the
  environment), which is what makes the trap narrow and quiet rather than
  obvious.

  Separately: under `--mm:arc`/`--mm:orc` (the default), `deepCopy` is a
  compile-time error unless the *program being compiled* passes
  `--deepcopy:on`. A library can't set it for its consumers. It is, though,
  only needed by code that actually calls `deepCopy` -- defining a generic
  that uses it costs an uncalled consumer nothing, verified both ways.

- **Nim won't overload on return type alone.** Two procs with identical
  parameters and different return types are an `Error: ambiguous call` at
  every call site, not a redefinition error at declaration -- so the failure
  surfaces in the caller's code, not yours. Hit while designing `parsed*`
  (ADR 0031); differing parameter types are what make an overload legal, not
  differing return types.
