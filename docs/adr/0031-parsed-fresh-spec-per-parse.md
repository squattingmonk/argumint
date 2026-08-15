# `parsed*`/`parsedOrQuit*`: a fresh spec per parse

Parsing the same spec tuple twice accumulated state instead of starting
fresh, in three different ways, none of them documented:

```nim
let spec = (tags: opts("--tag=<t>"), port: opt("--port=<n>", default = 80),
            count: flag[int](ops = "-c+=1"), help: help())

spec.parse(args = @["--tag", "a", "--port", "81", "-c"], command = "app")
spec.parse(args = @["--tag", "b", "-c"], command = "app")
spec.parse(args = @[], command = "app")
```

| after | `tags` | `port` | `count` |
| --- | --- | --- | --- |
| run 1 | `@["a"]` | 81 | 1 |
| run 2 | `@["a", "b"]` | 81 | 2 |
| run 3 | `@["a", "b"]` | 81 | 2 |

`opts` appends across parses (Match Accumulation is per-Arg lifetime, not
per-parse), `flag` keeps applying its Flag Operation cumulatively, and `opt`
*retains* run 1's value into runs that never mentioned `--port` — the worst
of the three, because it silently reads as a successful default.

Who hits it: anyone testing a CLI with a table of `(argv, expected)` cases
against one spec, and anyone embedding argumint in a process that parses more
than one command line — a REPL, an interactive shell, a server accepting
command strings, a batch runner. `CLAUDE.md` names `parse*` as "the
recommended entry point for embedding argumint in a larger program", which is
exactly that shape.

## Decision

Add `parsed*` and `parsedOrQuit*`, which parse a **fresh** spec and return
it, leaving the caller's own untouched. The naming follows Nim's own
`sort`/`sorted`, `reverse`/`reversed` convention: the past participle is the
non-mutating variant that returns a new value.

Both take a **builder**, not a spec tuple:

```nim
proc parsed*[S: tuple](build: proc (): S, ...): S
proc parsedOrQuit*[S: tuple](build: proc (): S, ...): S
```

`build` is called once per parse for a genuinely new tuple. That produces
fresh Args *and* fresh `command*` hook closures as a side effect of ordinary
construction, needs no compiler switches, and relies on no undocumented
behavior. An overload taking an already-built tuple was designed, built, and
then rejected — see "Copying an already-built spec tuple" below, which is the
substance of this decision.

Everything else — parameters, hook semantics, which exceptions escape — is
`parse*(tuple)`'s contract unchanged, so `parsed`/`parsedOrQuit` differ from
`parse`/`parseOrQuit` in exactly one respect.

All tuple entry points now route hook binding through one private
`buildAndBind`, so a hook is bound to the same tuple its caller returns as a
structural property rather than something each entry point must remember.

## Copying an already-built spec tuple

The obvious ergonomic win — `spec.parsed(args = argv)` on a tuple you already
have — was implemented and dropped. Recording why, because the idea is
appealing enough to be proposed again.

### Why a hand-written clone cannot work, and `deepCopy` can

`command*` binds its hooks at spec-construction time, closing over the nested
tuple:

```nim
result.spec = newSpec(spec, usage, prolog, epilog)
if not action.isNil:
  result.spec.action = (info: HookInfo) => action(spec, info)
```

That closure aliases the *caller's* nested tuple — verified: an ordinary
in-place `parse` of `ship Titanic` writes through to the original
`shipSpec.name`. So a clone that produces new `Arg` objects without also
rewriting that captured environment leaves every subcommand hook reading args
that nothing parses into. That rules out the obvious implementation — a
`clone` `{.base.}` method on `Arg`, rebuilding the tuple field-wise — and it
is why an earlier exploration of this idea concluded it was blocked.

`system.deepCopy` is not blocked, because it copies the closure environment
too *and preserves object identity across it*. Isolated from argumint
entirely: given a tuple holding both a `ref` and a closure capturing that same
`ref`, `deepCopy` yields one new object reachable by both paths
(`copied.box == copied.get()` is `true`), not two unrelated copies. That
property is the entire foundation of the tuple overload.

It is, however, **undocumented** — Nim's `deepCopy` documentation says
nothing about closures, though the compiler's handling is clearly deliberate.

### Why it was rejected anyway: silently discarded hook side effects

Rewriting the closure environment is exactly what makes reads work — and
exactly what makes writes wrong. A `command*` hook that closes over local
state gets that state copied along with everything else, so the hook fires,
reads the right values, and its **writes land in the copy**:

| entry point | `command` hook closing over a local | result |
| --- | --- | --- |
| `parsed(tuple)` | `seen.add name` | **lost** — caller's `seen` is `@[]` |
| `parsed(builder)` | same | works |
| `parse(tuple)` | same | works |

Narrower than it first looks: a captureless top-level hook writing a global
is unaffected (a global isn't in the environment), and so are top-level
`before`/`action`/`after` passed to `parsed` itself, which are bound *after*
the copy. But within that narrow band it is silent, and silent wrongness on a
second parse is the entire defect this ADR exists to fix — *"worse than the
append case, because it is silent and looks like a successful default."*
Shipping a fix for that class of bug with a fresh instance of the same class
inside it isn't a trade worth making for the ergonomics of not writing a
`proc`.

Two lesser marks against it, either survivable alone: it required
`--deepcopy:on` in the *calling program's* build (pay-per-use, and a
compile-time error naming the switch — but still the first compiler flag
argumint would impose on consumers), and it rested on the undocumented
closure behavior above.

### What the returned tuple does not carry

This applies to what shipped, not just the rejected overload: values for a
Command's own nested spec are reachable only through that Command's
`before`/`action`/`after` hooks, never off the returned tuple, because a spec
tuple holds a `CommandArg` rather than the nested tuple. Not a regression —
it's how subcommand values have always been read (see
`examples/naval_fate.nim`) — but the returned value is "the whole answer" only
for a single-level spec.

## Considered options

**A `reset*(spec)`.** The issue's own first suggestion, and it sidesteps the
closure problem entirely, since resetting in place creates no new objects for
a hook to lose track of. Rejected as the primary answer because it leaves a
parse a stateful operation you must remember to precede with a call — the
defect is that the second parse is silently wrong, and a fix you can forget
doesn't remove that. It also adds a `{.base.}` method to the `Arg` contract
that ADR 0017/0030 leave for issues #21/#22 to settle. Still available later;
adding it is additive.

**Reset implicitly at the top of `parse*`.** The cleanest semantics, but it
silently changes behavior for anyone relying on accumulation, and it can only
be considered before 1.0. Rejected in favor of a new name that makes the
choice explicit at each call site, with `parse*`'s existing behavior intact.

**Overload `parse*` itself rather than adding a name.** With the rejected
tuple overload it was impossible — the parameters would have been identical
and Nim rejects overloading on return type alone (`Error: ambiguous call`,
verified). For the builder shape it *would* be legal, since `proc (): S` and
`S` are different parameter types. Kept as its own name anyway: one `parse`
returning nothing and another returning the spec, distinguished only by
whether you passed a proc, reads worse at a call site than the
`sort`/`sorted` pairing does.

**Document the single-use constraint and stop there.** Free, and worth doing
regardless — `parse*`/`parseOrQuit*`/`newSpec*` now say so. But it only warns
about the sharp edge rather than offering anything to use instead.

## Consequences

- Callers must have a builder `proc`. That's the real cost of rejecting the
  tuple overload, and it falls hardest on someone handed a spec tuple they
  didn't construct. The builder-proc idiom is documented in the README's
  "Parsing More Than Once".
- `parse*`/`parseOrQuit*`/`newSpec*`'s doc comments now state that the spec
  they're given is single-use, and point here. So do the `Spec`-taking
  `parse*`/`parseOrQuit*`, which accumulate identically and — since a built
  `Spec` is opaque (ADR 0030) and a copy of one has no way to hand values
  back — get no `parsed` sibling at all. Documentation is their only remedy.
- Two new exported procs, one new concept. `parsedOrQuit*` exists so the
  `parse`/`parseOrQuit` pairing stays complete.
- Hook binding moved into `buildAndBind`, folding the two copies that existed
  in `parse*`/`parseOrQuit*` into one. `parsed*`/`parsedOrQuit*` reuse it
  rather than adding a third and fourth.
- `docs/gotchas.md` keeps both `deepCopy` findings even though nothing ships
  on them: they are the evidence for the rejection above, and the first thing
  a future attempt at a tuple overload would need.
