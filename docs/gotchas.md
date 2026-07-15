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

- **`ValueArg[T, false].defaultStr` requires `T` to support both `default(T)`
  and `==`** (it compares `self.default[0]` against `default(T)` to decide
  whether a default is "meaningfully set"). Nearly every type does, but a
  `{.requiresInit.}` object would fail to compile here if used as an
  `arg`/`opt` value type. Not considered worth guarding against, but worth
  knowing if `defineArg` ever fails to compile for a custom `T` with an
  unhelpful-looking error.
