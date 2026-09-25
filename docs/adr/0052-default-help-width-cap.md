# The detected help width is capped at 100 columns

`newSpecSettings`'s default `width` is now `min(detectWidth(),
DefaultMaxWidth)`, with `DefaultMaxWidth = 100`. On an 80-column terminal,
or with nothing detected, help wraps exactly as before. On a wider one it
stops at 100 columns instead of spreading prose across the whole screen.
(**Update:** ADR 0058 makes the default `0`, which the `width` getter
detects on first read as the same `min(detectWidth(), DefaultMaxWidth)`.)

(`detectWidth` now falls back to `DefaultWidth` rather than
`terminalWidth()`'s own 80, and both constants can be set with `-d:` -- see
ADR 0053.)

The cap applies to every *detected* width, `COLUMNS` included: `COLUMNS`
is just another way of reporting the terminal's size, not the caller
choosing a width. An explicit `width = n` is never capped.

100 matches clap's default `max_term_width`, the closest prior art. It
leaves 80-column output unchanged while still using some of the extra room
a wide terminal offers. 80 would cap too early: a wide terminal would then
gain nothing over a narrow one, which makes detecting the width mostly
pointless.

## Considered options

- **A `maxWidth` setting on `SpecSettings`.** Rejected: `width`'s default
  is evaluated at the call site, so `newSpecSettings` can't tell a detected
  width from one the caller passed in. It would have to turn `width` into a
  sentinel ("0 = detect") and detect inside the proc, which is a larger
  change for a knob no one has asked for. Instead `detectWidth` is
  exported: `width = detectWidth()` removes the cap, and `width =
  min(detectWidth(), 120)` sets another, without the caller copying its
  `COLUMNS` handling (`docs/gotchas.md`).
- **Leave `COLUMNS` uncapped.** Rejected: it would make `COLUMNS` behave
  differently from the terminal width it stands in for.

## Consequences

- Help on a terminal wider than 100 columns wraps narrower than before.
- `import argumint` gains `DefaultMaxWidth` and `detectWidth`.
