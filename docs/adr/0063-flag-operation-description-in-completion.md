# Completion annotates a Flag Operation Description the way help does

> **Note (#248):** a proc op given no `help` has an empty Flag Operation
> Description (ADR 0070). The rule below is unchanged: an empty one differs
> from any other, so the flag's other ops still show theirs.

A Flag whose Flag Operations do different things has a Flag Operation
Description per Variant: a `flagOp*` call's own `help`, or a generated
"Increase by 5". Help and completion both showed it, but differently.
Take `rank: flag[int](ops = [flagOp("-b, --boost", "+=", 5),
flagOp("-d, --dampen", "-=", 2)], help = "Adjust rank")`:

```
genHelp:
  -b, --boost   Adjust rank [action: Increase by 5]
  -d, --dampen  Adjust rank [action: Decrease by 2]

completion, usage "[options]":             --boost -> Increase by 5
completion, usage "--boost":               --boost -> Adjust rank
completion, usage "(--boost | --dampen)":  --boost -> Adjust rank
                                           --dampen -> Adjust rank
```

Help kept the Help Text and put the description in a bracket. Completion
replaced the Help Text with it, which ADR 0022 chose on purpose. But the
description alone can leave out what the Flag is for: "Increase by 5"
doesn't say what increases.

Completion was also inconsistent with itself. Neither caller could trust
`Arg.variantDesc`, documented as empty "if there's nothing to
disambiguate", because `FlagArg`'s override broke that: a bare bool flag
returned "Toggle the value". So each caller checked for itself whether the
descriptions differed. Help checked across all of the Arg's Variants;
completion only across the Variants one matcher handed it. Under
`(--boost | --dampen)` each matcher holds one Flag Operation's spellings,
so nothing looked different, and both candidates read "Adjust rank" side
by side.

## Decision

**Completion annotates instead of substituting.** A candidate's
description is the first paragraph of the Arg's short Help Text, then
` [action: <Flag Operation Description>]`. With no short Help Text the
description stands alone. Completion reads the same text help does for
each part, so the two agree.

- **The action only.** Help's bracket also carries the validator,
  `default:`, `env:` and `configKey:`. Those are the same on every Variant,
  so they don't help choose between candidates, and they'd make menu lines
  long.
- **Never the long Help Text.** Even when the short Help Text is empty, a
  candidate doesn't fall back to Long-Form Help Text (ADR 0049). It's too
  long for a menu line, so the description stands alone instead.

**`variantDesc` keeps its contract.** `FlagArg.variantDesc` returns `""`
unless the Flag's Flag Operations are described differently, judged across
all of them. Neither help nor completion checks this themselves, so a
Variant reads the same under every Usage Line that offers it.

The `action:` label stays as help has always printed it. In the glossary
and code, though, the text is a Flag Operation Description, since Action
already names the Spec callback.

## Considered options

- **Keep substituting, fix only the scope.** Judging divergence across all
  of an Arg's Variants alone would have fixed the inconsistency, but a
  candidate would still read "Increase by 5" without saying what
  increases.
- **The whole bracket.** Validator, `default:`, `env:` and `configKey:`
  read the same on every Variant, so they lengthen each menu line without
  telling candidates apart.
- **Fall back to the long Help Text.** It is written for help's page, not
  a menu line; `prose.summary` would cut it to its first paragraph, which
  may not stand alone.
- **A shared divergence check called by both help and completion.** It
  works, but `variantDesc` already promised the rule, and a check outside
  it leaves the broken promise for the next caller to trip over.

## Consequences

Completion menus for a Flag with differing Flag Operations change from
`Increase by 5` to `Adjust rank [action: Increase by 5]`. Help output is
unchanged.

This supersedes ADR 0022's "Per-variant vs. whole-arg description"
question.
