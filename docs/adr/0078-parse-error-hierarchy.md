# Parse failures are subtypes of ParseError

Amends ADRs 0035 and 0077.

Every failure of the user's input raised one of two unrelated
`CatchableError`s: `ValidationError` when a Validator rejected a value, and
`ParseError` for everything else. A caller couldn't catch "anything the
user got wrong" in one `except`, and couldn't tell an unrecognized option
from a value that won't convert without matching on `msg`.

## Decision

1. **`ParseError` is the parent of every user-input failure.** It has three
   subtypes, one per stage of a parse that can fail:
   - `UsageError`: the input doesn't fit any Usage Line. Every failed walk
     raises one: an unrecognized, unexpected or missing option, argument or
     command, a missing value, a starved option (ADR 0034).
   - `ConversionError`: a value won't convert to its Arg's type, or names
     no Variant of the flag it was supplied to.
   - `ValidationError`: a Validator rejected a converted value.

   `styledMsg` is declared once, on `ParseError`.
2. **Fallback-tier oversupply is a `UsageError`.** An env var or Config
   Source value supplying more values than the walk had room for breaks
   the same arity rule a typed token would, though the user didn't type
   it. Its complaint already names the tier.
3. **A failure is raised as the subtype every complaint shares, or else
   `ParseError`.** This is ADR 0077's "most specific type covering every
   failure", with the hierarchy filled in. A validation failure beside a
   conversion failure raises `ParseError`, as before. A single kind of
   failure always raises its own subtype, never a bare `ParseError`.
4. **A failure from user code is classified by its type.** A Custom Arg's
   `accept` or a custom Validator may raise any `ParseError`. A bare
   `ParseError` counts as itself, so any failure it joins raises
   `ParseError`. Anything outside `ParseError` still propagates (ADR 0077
   point 7).
5. **`parseOrQuit`'s labels don't change.** A `ValidationError` prints
   "Validation error:"; every other `ParseError` prints "Parsing error:".
   The label is for the end user, and "usage error" or "conversion error"
   would be argumint's vocabulary, not theirs.
6. **The exceptions carry no structured data.** `msg` and `styledMsg`
   only.

## Considered options

- **A new common base beside `ParseError`,** with `ParseError` and
  `ValidationError` as siblings under it. Existing `except` order would
  keep working, but it adds a name, and "parse error" would stop meaning
  "anything wrong with the input", which is how the guide uses it.
- **A subtype per complaint kind,** such as `UnrecognizedOptionError` or
  `MissingArgumentError`. A failed walk usually reports several kinds at
  once ("missing command: stop" beside "unrecognized command: stp"), so
  the covering type would almost always be `UsageError` anyway, and a
  program seldom branches on the difference.
- **Oversupply as its own subtype, or a bare `ParseError`.** Where a value
  came from is rarely something a program branches on, and a bare
  `ParseError` would make oversupply alone the one single kind of failure
  without a subtype of its own.
- **Structured fields,** such as the offending Arg or the complaint list.
  A failure can name several Args or none, and publishing the complaints
  would make their wording API. A field can be added later without
  breaking anything.
- **One label per subtype in `parseOrQuit`.** More precise, but it changes
  every transcript and shows the end user argumint's own terms.

## Consequences

- `except ParseError` now also catches `ValidationError`. Code that
  catches `ParseError` before `ValidationError` never reaches the second
  branch, so the more specific `except` goes first.
- A Custom Arg's `accept` should raise `ConversionError` for a value it
  can't take, as the built-in Args do.
- ADR 0035's store-time and walk messages are unchanged; only the type
  raised with them is narrower.
