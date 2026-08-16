# `missing argument` is only reported where the grammar actually required one

Extends the suppression rules of
[ADR 0035](0035-parse-failure-reporting.md) to positionals. Nothing in
[ADR 0034](0034-strict-option-checking.md) is overturned — its requirement
that a `missing argument` survive alongside a naming complaint still holds
wherever the positional was genuinely owed, and its pinned case is unchanged.

ADR 0035 stopped a `missing option` complaint being raised about an option
the user was never required to supply. The positional half of the same
defect was left in place, because that ADR's brief scoped the suppression to
`missing option` only. So a bracketed positional was still reported missing
(issue #38):

```console
$ demo --recrusive          # spec: opt --port, args <rest>; usage "[options] [<rest>...]"
Parsing error:
  - missing argument: <rest>
  - unrecognized option: --recrusive
```

`<rest>` sits at `[<rest>...]`. There is no input for which supplying it was
required, so that line is FSM bookkeeping rather than something the user can
act on — and it was visible in the README's own Strict Option Checking
examples.

This is not something [ADR 0036](0036-rank-failed-branches-by-reach.md)'s
Reach ranking could have fixed. Reach decides *which branch's* complaints are
reported; here both complaints come from branches tying at Reach `(0, 0)` —
neither consumed `--recrusive` — so the tied-branch merge unions them. The
defect is in what a branch says, not in which branch is chosen.

## Decision

**The `Argument` matcher does not report `missing argument` when the state it
was reached from is terminal.** Everywhere else it reports exactly as before.

A terminal state is one the walk was already entitled to accept at. If a
positional matcher finds nothing there, the grammar was not owed anything —
so there is nothing missing to report.

### The discriminator already exists

The obstacle recorded in issue #38 was whether an `Argument` matcher can
cheaply know it sits at a bracketed position, given that ADR 0035's brief had
rejected a graph-level requiredness bit for pushing work into FSM
construction. It can, and it costs nothing new.

`[X]` compiles to a Shortcut transition bypassing the group. FSM preparation
then collapses every Shortcut through its epsilon-closure, so **no Shortcut
transition survives into the walk**. What survives is `State.terminal`, which
the closure sets true when any state reachable by shortcut was terminal.

The bracket information is therefore already a `bool` on `State` by the time
parsing starts, and the walk holds that state where it invokes each matcher —
it consults the same flag in its own tail for a closely related question.
Nothing in FSM construction changes, which is why ADR 0035's objection does
not transfer.

### Requiredness is positional, not per-Arg

The property being tested belongs to the *position*, not the Arg — the same
Arg may be required at one grammar position and optional at another, so there
is no per-`Arg` "is this required" bit to compute. `State.terminal` is read
fresh at each occurrence.

### What changes and what does not

Every row was reproduced against the tree before and after the change.

| usage | input | before | after |
| --- | --- | --- | --- |
| `[options] [<rest>...]` | `--recrusive` | `<rest>` + unrecognized | unrecognized only |
| `[options] [<rest>...]` | `--port --verbose` | starved + unrecognized + `<rest>` | starved + unrecognized |
| `<x> <y> [--speed=<kn>]` | `1 --speed` | `<y>` + starved | unchanged (ADR 0034) |
| `(<a> \| <b>)` | *(none)* | `(<a> \| <b>)` | unchanged |
| `<x> [<y>]` | *(none)* | `<x>` | unchanged |
| `[<x>] <y>` | *(none)* | `(<x> \| <y>)` | unchanged |
| `<src> <dest>` / `--list` | *(none)* | missing option + `<src>` | unchanged |
| `[<rest>...]` | *(none)* | parses | unchanged |

## Considered options

- **Ask a whole-graph question: is there any accepting path that never
  consumes this Arg?** The tempting reading of the issue's own "there is no
  input for which supplying it was required". It is wrong, and loses a
  genuinely useful message: `(<a> | <b>)` given no input suppresses *both*
  arms, since each is an alternative route to acceptance, emptying the
  complaint list. `State.terminal` asks the narrower and correct question —
  was acceptance reachable *without consuming anything*. Alternation fails
  that test; a bracket passes it. Rejected.

- **Widen ADR 0035's rule 2 to cover `missing argument`** — drop it once any
  Naming Complaint is present. Rejected before this ADR was written: ADR 0034
  deliberately requires `missing argument: <y>` to survive alongside the
  starved-option complaint for `app 1 --speed`, which is a Naming Complaint.
  Requiredness, not the presence of a naming complaint, is what separates the
  two cases.

- **Compute a requiredness bit per `Arg` during FSM construction.** Rejected
  by ADR 0035 for pushing work into construction, and unnecessary here
  regardless: preparation already leaves the answer on `State.terminal`, and
  requiredness is positional rather than per-Arg anyway.

## Consequences

`[<x>] <y>` given no input still reports `missing argument: (<x> | <y>)`.
`<x>` is optional, but the state it is reached from is not terminal — `<y>`
is still owed — so it is not suppressed. This is accepted rather than worked
around: both positionals really are unsupplied, and the grouped rendering
reads correctly. Catching it would require exactly the per-Arg reachability
analysis rejected above, at the cost of the alternation case.

The suppression is a property of the position a matcher is reached from, so
the same `Argument` matcher can report at one state and stay silent at
another. This is deliberate — FSM preparation may hoist one transition onto
several states with different terminality, and each occurrence is judged on
its own.

Completion is unaffected: its frontier walk collects live branches rather
than complaints, and does not pass the flag.
