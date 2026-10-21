# Help Groups sit with their kind

Amends ADR 0048.

Help listed its groups as `Commands`, `Arguments`, `Options`, then every
user-defined group in declaration order. A custom group of commands or
positional arguments landed after `Options`, away from the other Args of
its kind: a `Maintenance` group of commands showed below the options. A
custom group of options already sat next to `Options` only because that
group happened to come last.

## Decision

1. **Each user-defined group follows the built-in group of its kind.**
   The order is `Commands`, then user-defined groups of commands, then
   `Arguments`, then user-defined groups of positional arguments, then
   `Options`, then user-defined groups of options and flags. Within one
   kind, user-defined groups keep the order of their first use.
2. **A kind's slot doesn't depend on its built-in group.** If every
   command is in `Maintenance`, `Maintenance` still comes before
   `Arguments`.
3. **A group's kind is that of its first shown Arg.** Flags and options
   are one kind, as their shared default group says. Hidden Args don't
   count, since the reader never sees them, and a group with no shown Arg
   isn't listed at all. A group mixing kinds is allowed: a `Help` group of
   a `help` command and the `--help` flag is a reasonable thing to write.
4. **Built-in groups are placed by name.** An Arg whose `group` names one,
   such as a command in `Options`, just joins it.
5. **There's no way to set the order outright.** A Help Formatter wanting
   another order writes the whole message itself from
   `HelpContext.groups` (ADR 0075).

## Considered options

- **Every group in order of first use, built-ins included.** The developer
  would control the order by declaring Args, but `help()` is usually
  declared last and goes in `Options`, so where `Options` lands would be
  an accident of that.
- **Rejecting a mixed group as a `SpecDefect`.** Too strict, given groups
  like the `Help` one above.
- **A separate section at the end for mixed groups.** A fourth rule, and
  it puts the group far from both its kinds, which is the problem this
  fixes.
- **The kind most of a group's Args have.** Harder to predict, and it
  needs a tie-break anyway.
- **An explicit order on `newSpec` or `SpecSettings`.** A new parameter
  with its own edge cases (a name that isn't a group, a group the list
  leaves out, nested Specs), for a need the formatter route already
  covers. It can be added later without breaking anything.

## Consequences

- Help changes for any Spec with a user-defined group of commands or
  positional arguments, or a mixed group led by one. Groups of options and
  flags show as before.
- `HelpContext.groups` yields the new order, so custom formatters get it
  too.
- Declaration order inside a mixed group now also decides where the group
  appears.
