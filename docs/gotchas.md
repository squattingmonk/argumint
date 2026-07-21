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
  `backend.nim`'s `terminals`/`collectArgs`/`sortTransitions`) only compile
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
  transitions are spliced onto it later.** `genFsm` (`parser.nim`) builds a
  spec's root by calling `addUsageLines`, which marks the root `terminal =
  true` only when it ends up with no transitions at all (an empty `usage`
  string -- nothing to match). `autoFillUsage` (`argumint.nim`) can later
  discover unreachable args/commands/options for that same spec and call
  `addUsageLines` again on that *same* root object to splice on real
  transitions (rather than re-parsing already-built lines from scratch) --
  if the stale `terminal = true` from the first call weren't cleared, the
  FSM would wrongly accept "no more input" at a root that now requires real
  args. Fixed by having `addUsageLines` itself unconditionally recompute
  `root.terminal = root.transitions.len == 0` as its last step, rather than
  leaving each caller to remember this invariant on its own. Caught by a
  test that actually calls `.parse()` against a spec built from `usage = ""`
  and auto-filled (`tests/test_argumint.nim`'s `"autoFillUsage"` suite) --
  the pre-existing tests there only asserted on the rendered `s.usage`
  string, which stays correct either way, and wouldn't have caught a
  regression here.

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
