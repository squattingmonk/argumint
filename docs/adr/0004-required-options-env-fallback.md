# A required Option/Flag's env var satisfies the requirement

Supersedes ADR 0001.

> **Extended by [ADR 0005](0005-env-supplied-multi-value-options-and-flags.md)**:
> `envSatisfied`'s one-shot-per-Arg cap described below is gone -- an env
> var can now supply more than one value. The decision to let env satisfy
> a required Option/Flag at all, and the per-Arg-not-per-Usage-Line
> reasoning, still stand as described here.

ADR 0001 decided that a required (unbracketed) Option/Flag's configured env
var is never consulted -- FSM matching fails outright the moment the Option
is absent from the command line, regardless of whether its env var is set.
That was deliberate: letting env silently satisfy a required Option meant
`--help`'s Usage: line could show something as mandatory that secretly
isn't, depending on the runtime environment.

We're reversing that. `env` is a per-Arg declaration (`opt`/`flag`'s `env`
param), not a per-Usage-Line one, so whether it actually works shouldn't
silently depend on whether the *specific* Usage Line an author happens to
be looking at requires that Arg or leaves it optional -- a user who
configures an env var for an Option expects it to work regardless of
context.

This needed no new "required" concept in the FSM: the `Option` matcher
(`fsm.nim`'s `match`) already fails with "missing option" when no CLI token
matches; it now falls back to the env var there instead, succeeding with
zero token consumption and no `pc.matches` entry, deferring the actual
value-setting to the existing post-walk env sweep (`Spec.parse`) exactly as
it already does for optional Options. This is naturally scoped to whichever
FSM branch is actually being walked, unlike a naive "inject a synthetic CLI
token for every configured env var up front" approach, which would leak a
subcommand-only option's env fallback into unrelated subcommands that never
declared it.

The one new piece of state is `ParseContext.envSatisfied`, capping env
fallback at one virtual match per Arg per walk -- otherwise a repeatable
`[options]...` catch-all (ADR 0002) would retry an env-satisfied Option
forever, and an Option required twice over in one Usage Line could have
both occurrences wrongly satisfied by a single env var. This caps at
exactly one virtual match regardless of how many values the env var might
represent; a future feature letting one env var supply several values (e.g.
a colon-delimited list) would need this guard to become a per-Arg count
instead of a one-shot set.

The Help-honesty concern ADR 0001 raised doesn't go away: a required
Option's Usage: line still renders unbracketed even when its env var could
silently satisfy it. We're accepting that cost rather than mitigating it
further -- the existing `[env: NAME]` annotation in the help text's args
table (shown for any env-configured Option/Flag, required or not) already
gives a reader the same signal argumint provides today for the optional
case.
