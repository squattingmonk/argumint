# A parse reports every bad value at once

Amends ADRs 0035, 0039 and 0071.

Once the walk succeeds, `parse` stores each value into its Arg: the
command line first, then the env and Config Source tiers. It stopped at
the first value that failed to convert or validate and raised that one
alone, so a user with three bad values fixed them one run at a time. An
env or Config Source tier supplying more values than the grammar had room
for was already collected across the whole sweep and reported together;
bad values weren't. Which bad command-line value came first depended on
the grammar, not on what the user typed: the store step went Arg by Arg in
the order the walk matched them.

## Decision

1. **One message for every failure.** The store step carries on past a
   failure and records it. `parse` raises once, after every tier is
   stored and before any hook fires, with every conversion failure,
   validation failure and oversupply complaint in one complaint list. Each
   keeps its wording, including the tier it came from (`(env: PORT)`).
   Identical lines collapse into one, as every other complaint does.
2. **The exception is the most specific type covering every failure.**
   Today that means `ValidationError` when every complaint is a
   Validator's, and `ParseError` otherwise, so a single failure raises
   exactly what it always has. If the exceptions grow a hierarchy (#285),
   the rule reads the same.
3. **Command-line values are stored in the order typed, across every
   Arg,** then the fallback sweep runs in its existing order. An Arg's own
   values keep the order they had, so Flag Operations compose as before.
4. **Every value that passes is written; one that fails is not.** After a
   failed `parse`, the spec holds exactly the valid values. A spec is
   single-use either way (ADR 0031), and no hook has run.
5. **A history-aware Validator sees what was stored** (ADR 0007). A value
   that failed is not in the history, so with `unique()`, `--tag a --tag b
   --tag a --tag b` reports both repeats and stores `a` and `b`.
6. **A value that fails closes the weaker tiers to its Arg.** If an Arg's
   command-line value fails, the env and Config Source tiers neither write
   to it nor complain about it: the user did supply it, just wrongly. If
   its env value fails, Config Source isn't consulted for it. A runtime
   Completer's fill follows the same rule.
7. **Only `ParseError` and `ValidationError` are recorded.** Anything else
   raised while storing a value, such as an `IOError` from a Custom Arg's
   `accept`, propagates as it is, from `parse` and from a Completer's fill
   alike.

`parse` and a Completer's fill now run the same store step and differ in
one place: `parse` raises the collected failures, and the fill drops them.

## Considered options

- **Write nothing if anything fails.** Simpler to describe, but it needs a
  check-everything pass before any write. History-aware Validators and
  Flag Operations depend on what has already been written, so that pass
  would have to simulate the writes, and a rollback path would follow.
- **Check every value, but keep stopping the writes at the first
  failure.** The same problem: checking needs the history writing builds.
- **Always raise `ParseError` once there's more than one failure.** A
  caller catching `ValidationError` would then miss two validation
  failures reported together, while catching one alone.
- **Let a fallback tier fill an Arg whose command-line value failed.** The
  leftover state would show a value the user overrode, and the message
  could complain about an env var the user never meant to use.

## Consequences

- ADR 0035's store-time message held one complaint; it now holds every
  failure. Its "one message shape" stands.
- ADR 0039's "a bad command-line value surfaces before a bad env one" is
  now an order within one message, not which one is reported.
- ADR 0071 point 4: a command-line value that fails no longer leaves the
  env var to fill its Arg. #260's test pinning that is reversed.
- A caller who catches a store-time failure and inspects the spec finds
  every valid value written, where it used to find whatever came before
  the first failure.
