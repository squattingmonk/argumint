# Usage-string `--` forces end-of-options at a fixed grammar position

ADR 0019's "Out of scope" section flagged a usage-string-level `--`/`[--]`
marker (mow.cli-style) as a natural follow-up once token classification
became walk-time-aware, but didn't design it. Separately, and already
fully working with zero usage-string support: a literal `--` typed
*anywhere* on the actual command line is unconditionally consumed the
first time any matcher's forward scan crosses it (`consumeOptsEnd`),
flipping `ParseContext.optsEnd`; every token after that, including a
second literal `--`, is treated as plain positional text regardless of
shape. That CLI-typed mechanism is untouched by this decision.

What was missing was a way for a spec author to *write* `--` in a Usage
Line at all — the lexer had no token for it (a bare `--` lexed as
`tkCommand`, then failed spec construction with "Undeclared command: --"
the moment `atom()` looked it up against `spec.commands`) — and, more
specifically, a way to say "this exact grammar position always ends
options, whether or not the user bothers to type the literal `--`,"
purely so `--help`'s generated `Usage:` line (`formatUsage` already
prints the raw usage string verbatim, so display is free) can show the
convention to users.

## Decision

1. **New lexer token, `tkOptsEnd`**, matching bare `--`, and also
   `[--]`/`[ -- ]` (a bracket pair whose *only* content, modulo
   whitespace, is `--`) as the identical token — tried ahead of the
   generic `tkBracketOpen` pattern. This means a bracket wrapped around
   nothing but the marker collapses to the exact same atom as bare `--`,
   with no `Shortcut`/optionality involved at all, sidestepping the need
   for the parser to structurally detect "this bracket's content is
   trivially just the marker." A bracket wrapping the marker *together
   with* something else (e.g. `[-- <arg>...]`) does not match this
   pattern and takes the ordinary bracket-group path (see point 5).

2. **New `MatcherKind`, `OptsEnd`.** Its `match` always returns `true`
   (never fails, same as `Shortcut`) and, when reached during a walk: if
   the next remaining token is literally `--` and `pc.optsEnd` isn't
   already `true`, consumes it (same one-shot-per-path guard
   `consumeOptsEnd` already uses); regardless of whether a literal `--`
   was there to consume, sets `pc.optsEnd = true`. This is what makes it
   a *forcing* marker rather than documentation-only: once the walk
   crosses this position, every later token on that path classifies as
   `Positional` (`classify`'s `if optsEnd: return Positional`
   short-circuit) even if the user never typed `--` at all.

3. **Transition ordering: `OptsEnd` is tried after every other real
   matcher at a shared state, but before `Shortcut`.** This matters
   wherever the marker's own transition ends up sharing a state with an
   existing optional/repeatable construct's `Shortcut` — e.g.
   `[options] --`, where `[options]`'s own repeat-loop-back `Shortcut`
   and the marker's transition land on the same state once the grammar
   is stitched together by `sequence`'s `add`. Trying real matchers
   (letting `[options]` keep consuming genuine options first) ahead of
   `OptsEnd`, and `OptsEnd` ahead of any `Shortcut`, is what makes the
   marker force the split only once nothing else remains to match,
   rather than a `Shortcut` bypassing the position (and the forcing)
   entirely. The exact backtracking interaction should be verified with
   a scratch compile before this ships (see `docs/gotchas.md`'s existing
   precedent for confirming FSM/backtracking mechanics empirically
   rather than by inspection alone).

4. **Only `Positional` Argument atoms may follow `--` in the same Usage
   Line.** `classify`'s short-circuit means an Option, Flag, `[options]`,
   or Command atom placed after the marker could never actually match —
   any token that would satisfy it becomes `Positional` before those
   branches are even considered. This is the same class of mistake ADR
   0010 already raises `SpecDefect` for ("nothing may follow a Command"),
   generalized to a second forbidden-successor case; the parser threads
   a `seenOptsEnd`-style flag the same way it already threads
   `seenCommand`. A second `--` in the same Usage Line is rejected by the
   same check — the marker is not itself a `Positional` Argument, so `<a>
   -- <b> -- <c>` doesn't parse. (On the actual command line, though,
   `foo -- bar -- baz` still parses as four positional values `foo bar --
   baz` — the *second* literal `--` is handled entirely by the
   pre-existing `consumeOptsEnd`/`classify` machinery from point 0, once
   `optsEnd` is already `true`, completely independent of how many `--`
   atoms the grammar itself declared.)

5. **`--...` (repeating the marker) is a `SpecDefect`**, mirroring ADR
   0010's rejection of a repeated Command for the same underlying reason:
   the position can never be meaningfully re-entered.

6. **`[-- <arg>...]` (marker plus something else, in brackets) is
   allowed** and is not redundant with bare `-- <arg>...`: the bare form
   requires `<arg>` to match at least once after the marker (ordinary
   `...`-repetition semantics — the base atom is required, only further
   repeats are optional), so it fails outright if nothing remains on the
   command line at that point. Wrapping the whole group makes the
   marker-plus-positionals unit skippable as a whole. Only a bracket
   whose *sole* content is the marker (point 1) collapses/is redundant;
   a bracket containing the marker plus a following atom is not.

7. **No new public API, no `--help` args-table entry, no
   `autoFillUsage` participation.** The marker isn't an `Arg` — no
   variants, no help string, nothing to auto-derive a Usage Line from —
   so it's exclusively something an author writes explicitly in their own
   `usage` string; auto-generated lines never invent it.

8. **Invisible to shell completion.** `candidateWords`'s `case
   tr.matcher.kind` (an exhaustive case over `MatcherKind`) gains an
   `OptsEnd` branch returning `newSeq[string]()`, the same as `Shortcut`.
   Every other kind offers literal words that disambiguate a real choice
   among alternatives (which flag, which subcommand, which valid value);
   `--` disambiguates nothing, since typing it or not produces the
   identical parse outcome once the position is reached.

New domain term: **End-of-Options Marker** (`CONTEXT.md`).

## Considered options

- **Zero FSM footprint** (a pure lex/parse-time construct with no
  Matcher, purely for legalizing the syntax so it can render in help
  text): rejected once the intended semantics were clarified as
  *forcing* the split even without a literal `--` typed — a genuine
  runtime behavior change, not documentation-only, so it needs a real
  Matcher.
- **Reject `[--]` (marker alone in brackets) as a `SpecDefect`**,
  parallel to the other dead-code rejections: rejected in favor of
  collapsing it at the lexer level instead — cheaper to implement (no
  parser-side "is this bracket's content trivially just the marker"
  check) and it isn't actually broken the way the other rejected
  constructs are, just stylistically redundant.
