# Validators don't run against coded defaults

A Validator only ever runs against a value that came from the command line
or an env var (`parseImpl`/`Spec.parse`'s env sweep) -- never against an
Arg's own coded `default`, which is substituted later at read time
(`toT`/`toSeqT`), entirely outside `parseImpl`/`validate`. We considered
also validating defaults, and decided against it: an author should be free
to declare a default that deliberately falls outside their own Validator's
rules -- e.g. a sentinel/fallback value used precisely because it's
distinguishable from anything a real, validated value could be. Forcing
every default to satisfy its own Validator would take that away, for no
compensating benefit (a coded default is author-controlled, not
user-supplied input that needs guarding).

This decision leaves a related question genuinely open, not resolved by
it: `checkSeen`/`unique` (`docs/adr/0007-history-aware-validators.md`)
draws Seen Values from `self.value`, which a default never populates (it
lives in the separate `self.default` field, merged in only at read time,
never written to `self.value`) -- so a CLI-supplied value equal to the
default won't be caught as a duplicate by `unique()`, regardless of this
decision. That's a separate question about whether a default should
participate in Match Accumulation at all (a bigger change than running
`validate` once), not about whether it should be validated -- easy to
conflate the two if this ever comes up again, worth remembering they're
distinct.

## Considered options

- **Validate defaults too** (run the Arg's Validator against `default` at
  spec-construction or read time): rejected -- see above. Also would have
  needed its own decision about *when* to run it (construction time, so a
  bad default is caught early as something closer to a `SpecDefect`, vs.
  read time, so it's a `ValidationError` like any other) and about how a
  multi-value Arg's several defaults would each be checked.
