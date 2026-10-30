# 2.0 surface review, 2026-10-29

The fifth review, and the first aimed at 2.0. ADR 0080 freezes four things
for 1.x: the names the public modules export, the extension points, the
usage-string grammar and the minimum Nim version. Everything else can
already change in a minor release, so a refactor of the internals doesn't
need 2.0, and holding one for it only delays it. This review looks only at
what's frozen, for changes that can't ship before 2.0, and it revisits
[F](2026-08-28-deepening-map.md#f--backendnim-holds-two-unrelated-data-models)
now that Nim 2.4 has cyclic imports. It continues the
[nasher port review](2026-10-22-nasher-port-review.md)'s lettering at AC.

Each candidate says which part needs 2.0. Where part of it could ship in
1.x, such as a new name beside an old one marked `{.deprecated.}`, that part
should go to `main` first, so 1.x users see a warning before 2.0 breaks
anything.

Reviewed at `00d0667` (`main`); `next` was at `d127d96`, the Nim 2.2.14
floor. Vocabulary: domain terms per [`GLOSSARY.md`](../../GLOSSARY.md).
Line numbers are as of the review date.

## Status

| | Candidate | Strength | Status |
|---|---|---|---|
| [AC](#ac--a-validators-desc-does-two-jobs) | A Validator's `desc` does two jobs | Strong | Revised: #357, all 1.x ([ADR 0089](../adr/0089-annotation-text-overrides-a-help-annotation.md)) |
| [AD](#ad--dottuple-quits) | `dot(tuple)` quits | Strong | Open |
| [AE](#ae--a-commands-values-cant-be-read-off-the-parsed-tuple) | A command's values can't be read off the parsed tuple | Worth exploring | Open |
| [AF](#af--the-custom-arg-contract-is-wider-than-customarg-says) | The Custom Arg contract is wider than `customarg` says | Worth exploring | Open |
| [AG](#ag--the-facade-exports-whole-modules) | The facade exports whole modules | Worth exploring | Open |
| [AH](#ah--a-message-is-named-an-error) | A message is named an error | Speculative | Open |
| [F](#f-revisited--the-graph-types-move-to-fsmgraph) | F, revisited: the graph types move to `fsmgraph` | Strong | Open; 2.0 requires Nim 2.4 |

**Recommendation:** AC and AD first. Both are small, both plainly need a
major release, and AC's additive half can ship in 1.x now (AC was since
revised: it needs no major release). AE is the one
worth a grilling session: it changes the most user code, and it would give
users the most, since `parsed` would return every command's values, not
just the root's. AF and AG both come down to listing the frozen surface by
name, so they could share an ADR. F is cheap now that 2.0 requires Nim 2.4:
raise the floor on `next` first, then move the types.

## Candidates

### AC — A Validator's `desc` does two jobs

**Strong.** Files: `src/argumint/values/validators.nim`,
`src/argumint/values/flagclamp.nim`, `src/argumint/help.nim`.

**Problem.** `choice`, `range`, `check`, `checkSeen`, `unique`, `all` and
`any` take `desc = ""` (`validators.nim:47–141`). It replaces both the
Validator's Help Annotation and its Validator Failure Message. One string
can't serve both. The generated texts show the difference: `choice`'s help
reads `choices: "fast", "slow"`, and its failure reads `got "x" but
expected one of "fast", "slow"`. An author who
writes good failure text gets odd help, or the other way round. ADR 0088
turned down letting an Arg hide its own Help Annotation for this reason:
`desc` "is also the Validator Failure Message, so its type can't change in
1.x".

A Flag Clamp spells the same idea differently. `clamp` and `adjust` take
`desc = none(string)` (`flagclamp.nim:32`, `:50`), where `some("")` hides
the annotation. A Validator's `desc` is a bare `string`, so `""` means "no
override" and an annotation can't be hidden.

**Solution.** Give each job its own parameter, with one convention for
both kinds:

- `help: Option[string]`, the Help Annotation, where `some("")` hides it.
- `failure: string` (or another name), the Validator Failure Message, where
  `""` keeps the generated text.

The same `help` goes on `clamp` and `adjust`, replacing their `desc`.

**1.x part.** Adding `help` beside `desc` is additive and can ship now; as
long as it's `none`, `desc` keeps doing both jobs.

**2.0 part.** `desc` becomes the failure message only and is renamed, and
the Flag Clamp's `desc` gives way to `help`. Every call that passes `desc`
changes, so a 1.x release should mark it `{.deprecated.}` once `help`
exists.

**Wins.** Help and failure text can each be written well. An author can
hide one Validator's annotation, which ADR 0088's filter can only do from a
formatter. Validators and Flag Clamps say "hide this" the same way.

**Revised (#357).** The premise above is wrong: one text can do both
jobs. A good `desc` names what's accepted (`a positive even number`). It
reads well in help, and reads badly in a failure only because a custom
`desc` goes after `<value> did not meet condition: `, a frame written for
a predicate like `must be even`. `choice` and `range` already generate
`got … but expected …` around a noun phrase. So the problems are that
frame and a Validator's annotation that can't be hidden, and the fix keeps
one text:

- `desc` becomes `AnnotationText`, a distinct `Option[string]` on every
  Validator constructor and on `clamp`/`adjust`. Its converters keep every
  call compiling: `""` is generated, and `some("")` hides, as a Flag
  Clamp's already does.
- A custom failure reads `got <value> but expected <desc>`.

All of it ships in 1.x, so AC has no 2.0 part. The Solution's separate
`help` and `failure` fall with the premise. Chained `withHelp`/`withFailure`
modifiers were prototyped and work, but are turned down for now: they'd be
argumint's only chained API and need 2.0 to drop `desc`. Whether 2.0 adopts
chaining is a separate question. See ADR 0089.

### AD — `dot(tuple)` quits

**Strong.** Files: `src/argumint.nim:1067`.

**Problem.** `dot(spec: tuple, ...)` builds a Spec and, on a `SpecDefect`,
prints it and calls `quit`. Every other proc that quits ends in `OrQuit`
(`parseOrQuit`, `parsedOrQuit`), and `dot(Spec)` beside it never quits. The
[simplification review](2026-10-14-simplification-review.md#smaller-findings)
and the [pre-1.0 review](2026-09-24-pre-1-0-review.md#smaller-findings) both
listed it but didn't fix it. A test or tool that calls `dot` to inspect a
spec it expects to be malformed exits instead of catching the defect.

**Solution.** Let the `SpecDefect` propagate, as `newSpec` does. Nothing
needs a `dotOrQuit`: `dot` is a debugging aid, and a defect's own trace is
the useful output.

**2.0 part.** All of it: a program that relied on the quit gets an
uncaught `Defect` instead. There's no 1.x half, since a raising overload
can't share the name.

### AE — A command's values can't be read off the parsed tuple

**Worth exploring.** Files: `src/argumint.nim:593` (`command`),
`src/argumint/core/backend.nim:97` (`CommandArg`), ADR 0031.

**Problem.** `command[S]` returns a plain `CommandArg`, which holds an
untyped `Spec`. The tuple `S` it was given isn't reachable from it, so a
command's own values can be read only in its hooks, or from Args the
program declared outside any tuple. ADR 0031 calls this out: the tuple
`parsed` returns is "the whole answer" only for a single-level spec. The
guide works around it in two places: the tutorial declares `file` and
`verbose` outside the tuple so hooks can see them, and `command[S, O]`
passes an extra context object into each hook.

**Solution.** Make the command a typed leaf over an untyped base, the way
`ValueArg[T]` sits over `ValueArgBase` (ADR 0068). `command[S]` returns, for
example, `CommandArg[S]`, which keeps its tuple, so `cli.ship.values.move.x`
reads a nested value after `parse` or from `parsed`'s result. The base
keeps what the walk and dispatch need. The name of the accessor is open:
`spec` is taken, since it returns the `Spec`.

**2.0 part.** A scratch compile showed that a subtype breaks code that
compiles today. A program that passes an inferred spec tuple to a proc
whose parameter names `CommandArg` (`proc f(x: tuple[ship: CommandArg])`),
or writes `@[command(...)]` where a `seq[CommandArg]` is wanted, stops
compiling. Returning a tuple with a `CommandArg` field from a proc still
works. Renaming the base would break more, so the typed leaf can only take
the `CommandArg` name in 2.0.

**Wins.** `parsed` returns every command's values. A program can dispatch
on which command was seen and read its values afterwards, without hooks,
which is how most parsers are used. The tutorial's workaround and much of
the reason for `command[S, O]` go away.

**Open questions.** Whether `HookInfo` should give hooks the typed parent
(likely not, since a command can be grafted under two parents). Whether
`command[S, O]` stays. How this reads beside ADR 0031's fresh spec per
parse: a fresh `build()` already makes fresh nested tuples, so it should
hold, but check with a scratch compile.

### AF — The Custom Arg contract is wider than `customarg` says

**Worth exploring.** Files: `src/argumint/customarg.nim`,
`src/argumint/core/backend.nim:341–551`, `docs/guide/custom-types.md`
("Optional Methods"), `README.md` ("Stability").

**Problem.** The README freezes "the signatures of the methods a Custom Arg
or Config Source overrides" but doesn't list them. `customarg` exports
five methods a Custom Arg overrides (`accept`, `action`, `isMessage`,
`envSource` and `configKey`) and two procs it calls (`subject` and
`envName`). The guide also tells a Custom Arg to override `clear`,
`defaultStr`, `completions` and `validatorHelp`, and none of those four is
exported from a public module (`clear` comes through the facade). Nim
matches a method override by name and signature, not by what's in scope,
so an override dispatches anyway: a scratch Custom Arg overriding
`defaultStr` and `validatorHelp`, importing only `argumint` and
`argumint/customarg`, showed both in its help.

The same rule means `accumulates`, `clampHelp`, `variantDesc` and `aliases`
can be overridden from user code too, though no doc mentions them. Only
`argtypes.nim` overrides them. As written, the README arguably freezes
them.

**Solution.** Name the contract in one place. `customarg` exports every
method a Custom Arg may override, beside the procs it calls, and the README
says those methods are the contract. The four internal methods stop being
overridable: each becomes a proc, or a hook stored on `ValueArgBase` and
`FlagArgBase`, the way `write` and `describe` already are
(`architecture.md`, "Two classes per kind").

**1.x part.** Exporting `clear`, `defaultStr`, `completions` and
`validatorHelp` from `customarg` is additive, and it lets an override call
`procCall` on its base.

**2.0 part.** Sealing the four internal methods, and changing the README's
wording to the list.

### AG — The facade exports whole modules

**Worth exploring.** Files: `src/argumint.nim:27–33`,
`tests/test_public_api.nim`.

**Problem.** `argumint.nim` re-exports `errors`, `validators`, `flagclamp`
and `configsource` whole, minus a few names. Every exported name in those
modules is frozen, including machinery no program calls:
`Validator.validate`, `Validator.completions`, `FlagClamp.apply` and
`lookupConfigSources`. Every name added to them later becomes public, and
frozen, without anyone deciding it. The facade also re-exports
`std/terminal`'s `ForegroundColor` and `Style` and six names from
`std/options` (`Option`, `some`, `none`, `isSome`, `isNone` and `get`), so
their shape is part of argumint's.

The rest of the facade names each export with a comment saying why, and
`test_public_api.nim` pins what it withholds. These four lines are the
exception.

**Solution.** Export the user-facing names one by one, and withhold the
machinery, with a `not compiles` test for each. Decide each `std`
re-export: keep `Option` and its constructors, which `env` and `clamp`'s
parameters need, and check whether anything needs `terminal.Style`
directly.

**2.0 part.** Withholding a name that's exported now. Listing the rest by
name changes nothing for users, so it can happen on `main` first, and then
each withheld name is a small `next` change.

### AH — A message is named an error

**Speculative.** Files: `src/argumint/core/errors.nim:51–68`,
`docs/guide/errors.md`.

**Problem.** `MessageError`, `HelpError` and `CompletionError` are raised
when the user asked for help, a message or completions. The doc comment on
`MessageError` says it's "not a failure", and `parseOrQuit` exits `0` for
it. ADR 0059 kept it apart from `ParseError` for that reason, but the
names still say "error". A program that calls `parse` must catch an
"error" to show help.

**Solution.** Rename them to say what happened, such as `MessageRequest`,
`HelpRequest` and `CompletionRequest`.

**1.x part.** The new names can be added as aliases now, and the old ones
marked `{.deprecated.}`.

**2.0 part.** Removing the old names.

**Why only speculative.** Most programs call `parseOrQuit` and never name
these types. The guide teaches `except MessageError` and `except
HelpError`, so the rename costs exactly the programs that already read the
guide closely, for a naming gain only.

### F, revisited — The graph types move to `fsmgraph`

**Strong.** Files: `src/argumint/core/backend.nim:172–209` and `:336`
(`hash(State)`), `src/argumint/grammar/fsmgraph.nim`.

F was parked because the move was "mechanical rather than clarifying".
Moving the types isn't mechanical, though: `Spec.fsm` is a `State`, and
`Matcher` holds an `Arg`, so `backend` and `fsmgraph` would import each
other. Nim 2.2 can't compile that. Nim 2.4 can, with `import x {.cyclic.}`
on both sides: the manual's "Cyclic imports" section checks the modules'
types and leading routines together, phase by phase. A scratch compile
confirmed that the pragma works on 2.4.0 and is an `invalid pragma` error
on 2.2.14.

**Prototype.** A scratch worktree moved `State`, `Transition`,
`MatcherKind`, `Matcher` and `hash(State)` into `fsmgraph`, with
`{.cyclic.}` imports in both modules. It took 48 added lines and 43
deleted across five files: the two modules, an `fsmgraph` import in
`completion.nim` and `fsm.nim`, and one in `tests/test_argumint.nim`.
`nimble test` passed on Nim 2.4.0, with 1,820 tests OK and none failing.
Nothing needed `privateAccess` or `openSym` changes. The prototype wasn't
kept.

**2.0 part.** Only the Nim floor. The graph types aren't exported (ADR
0030), so the move itself is internal. But a minimum of Nim 2.4 is a major
release under ADR 0080, and if 2.0 ships on 2.2.14, 2.4 waits for 3.0.

**Decided:** 2.0 requires Nim 2.4, so F goes ahead on `next`. Raising the
floor from 2.2.14 to 2.4 is its own breaking change and lands first; F
follows it. F is the only thing this review found that needs 2.4.
`nimPreviewHashRef`, which would retire `hash(State)`, is still opt-in on
2.4.0, so `hash(State)` stays. The floor bump needs an ADR of its own,
written with it: ADR 0080 records that the floor is frozen for a major
version, not what 2.0 raises it to.

## Considered and dropped

These don't need 2.0, or were already decided:

- **The Help Formatter interface.** `HelpFormatter` is a
  `proc (ctx: HelpContext): string`, and `HelpContext` keeps its fields
  private behind accessors, so a new accessor or field is additive. `Row`
  is an object for the same reason. Nothing found that needs 2.0.
- **The `ini` and `json` Config Sources.** Each is one constructor taking a
  path. A new option would be a defaulted parameter, which a minor release
  can add. Nothing found that needs 2.0.
- **Fewer `flag` overloads.** The overloads that take `validator` exist so
  `string` and `bool` fail at compile time (ADR 0086). A breaking release
  doesn't change that.
- **One options object for the `parse` family.** `parse`, `parseOrQuit`,
  `parsed`, `parsedOrQuit`, `newSpec`, `dot` and `command` repeat `usage`,
  `prolog`, `epilog` and the hooks. Named arguments already read well, and
  merging them would break every program for little gain.
- **A Config Source naming its file in an error.** It needs a new method
  with a default, which ADR 0080 allows in a minor release.
- **Optional option values, such as `--color[=<when>]`.** New syntax that
  an existing usage string can't contain, so existing command lines parse
  the same way. It can ship in 1.x if it's wanted (#102).
- **The `toT` converters.** ADR 0040 kept them deliberately.
- **Help, errors and completion as exceptions.** ADRs 0059 and 0078 settled
  it, and AH covers the only part worth revisiting.
- **The usage grammar.** Nothing found that should reject a command line it
  accepts now.
- **`cfgKey` and the env fields duplicated across `ValueArgBase` and
  `FlagArgBase`.** None is exported, so the
  [simplification review's](2026-10-14-simplification-review.md#smaller-findings)
  cleanup can happen in 1.x.
