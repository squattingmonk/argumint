# `missing command` is only reported where the grammar actually required one

Extends [ADR 0037](0037-missing-argument-only-where-required.md) from
positionals to Commands. Its test is the same: a matcher reached from a
terminal State was never owed anything. What differs is how the complaint
is suppressed.

ADR 0037 left Commands alone, so with usage `[options]` / `set` a failed
parse still blamed the `set` Usage Line the user was not on (issue #310,
diagnosed in #308):

```console
$ app --prot=1
Parsing error:
  - missing command: set
  - unrecognized option: --prot=1
```

The `[options]` branch and the failed Command matcher both stall at Reach
`(0, 0)`, so their Reports merge. ADR 0035's rule 2 drops `missing command`
only beside an `unrecognized command` or `unexpected command`, so it
survived beside an option complaint. But the `[options]` line makes the root
terminal: the grammar could have stopped without `set`, so no Command was
required.

## Decision

**A `Command` matcher reached from a terminal State still records `missing
command`, but marks it not owed. `finalComplaints` drops every complaint
that is not owed, once something names a token.** A required Command is
reported exactly as before.

### Recorded, then dropped, not never recorded

ADR 0037's `Argument` matcher simply records nothing at a terminal State.
A `Command` matcher can't do the same. `handleLeftovers` reads a `missing
command` to learn that a Command was expected at the leftover's position,
which is how a typo is worded as one:

```console
$ app sett
Parsing error:
  - unrecognized command: sett; did you mean set?
```

Without the complaint, `sett` would be worded `unexpected argument: sett`
and lose its Did-You-Mean Suggestion. So the complaint is recorded, carries
`owed = false`, and is filtered out only after the leftovers are worded.

It never reaches the user. The matcher records a leftover beside it, and a
terminal State with no tokens left would have parsed, so a Report holding an
unowed `missing command` always has something to name.

### What changes and what does not

Every row was reproduced against the tree before and after the change.

| usage | input | before | after |
| --- | --- | --- | --- |
| `[options]` / `set` | `--port` | starved + `set` | starved only |
| `[options]` / `set` | `--prot=1` | `set` + unrecognized | unrecognized only |
| `[options]` / `set` | `sett` | unrecognized command + suggestion | unchanged |
| `[options] add` | `--port 9090` | `add` | unchanged |
| `[options] add` | `--prot=1` | `add` + unrecognized | unchanged |
| `[options] add` | `--port` | starved + `add` | unchanged |

## Considered options

- **Record nothing at a terminal State, as ADR 0037 does.** Rejected: it
  costs `sett` its wording and its suggestion, as above.

- **Widen ADR 0035's rule 2 to drop `missing command` beside any Naming
  Complaint.** Rejected for the reason ADR 0037 gave for `missing argument`:
  where `add` is required, `missing command: add` is the line the user can
  act on, whatever else went wrong. Requiredness, not the presence of a
  Naming Complaint, separates the cases.

- **Have `handleLeftovers` learn a Command was expected some other way,** so
  the complaint need not be recorded. Rejected: the `missing command` is
  already the record of exactly that, made by the one matcher that knows it
  (ADR 0035). A second channel would duplicate it.

## Consequences

`Complaint` gains an `owed` field. Only `missing command` sets it false
today; every other complaint is owed.

As with ADR 0037, the suppression belongs to the position a matcher is
reached from, so the same `Command` matcher can be owed at one State and not
at another. So it reaches no further than ADR 0037 does. With usage `-v` /
`-v set`, input `-v --prot=1` still reports `missing command: set`: the
grammar could have stopped after `-v`, but on the other Usage Line, not at
the State the `set` matcher is reached from.

When Reach-tied branches merge an owed and an unowed copy of the same
complaint, the merged one is owed, whichever arrived first. ADR 0037's
`missing argument` behaves this way already, since its unowed copy is never
recorded. Without this rule, `-v [set]` / `-v set` and `-v set` /
`-v [set]` would report differently.
