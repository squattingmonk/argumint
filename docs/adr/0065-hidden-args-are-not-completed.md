# A hidden Arg is never offered by completion

`hidden = true` kept an Arg (a Command included) out of help, so an old or
internal name could keep working without being advertised. Completion still
offered it, which advertised it anyway: `__complete ""` listed a hidden
`--secret` beside every visible Option.

## Decision

Hidden means not advertised anywhere. Completion never offers a hidden
Option, Flag, or Command, or a hidden Positional Argument's values, even
when the typed prefix matches it. It still parses, and once the user has
typed it, completion carries on normally past it: a hidden Command's own
Options are offered after its name, and a hidden Option's values after its
name.

`candidateWords` (`completion.nim`) skips the hidden Arg on every matcher
that names one. `pendingOptionalArgs` doesn't, which is what lets a typed
hidden option's values complete.

## Considered options

- **Offer a hidden Arg only when the typed prefix matches it**: rejected.
  It still advertises the name to anyone who types its first letter, and
  the point of `hidden` is that only someone who already knows the name
  uses it.
- **Stop completing past a hidden Arg too**: rejected. The user who typed
  it already knows it, and losing completion for the rest of the line
  only punishes them.

## Consequences

`hidden` now means the same thing in help and completion. A hidden
Positional Argument gets no completion, even when its validator lists its
values.
