# A custom theme keeps automatic colour detection

Amends ADR 0051.

The default `style`, `autoStyler`, colours help and error output only when
stdout and stderr are both terminals, and honours `NO_COLOR`, `TERM=dumb`,
`FORCE_COLOR` and `CLICOLOR_FORCE` (ADR 0051, resolved lazily since ADR
0058). But it always resolved to `ansiStyler(defaultTheme)`. A program that
wanted its own colours had to pass `style = ansiStyler(theme)`, which is
used as given, so its help put escape codes into pipes and logs unless the
program repeated the detection itself. It couldn't reuse argumint's rule,
which was private.

## Decision

`newSpecSettings` takes a `theme` (default `defaultTheme`), stored in a
private `SpecSettings` field. While `style` is `autoStyler`, the `style`
getter resolves it to `ansiStyler(theme)` under the same rule as before. An
explicit `style` ignores `theme`.

The rule itself is public as `wantsColor()`, so a fully custom `Styler`
can follow it: `style = if wantsColor(): myStyler else: nil`. It includes
enabling the Windows console's ANSI handling, which `resolvedStyler` now
gets by calling it.

## Considered options

- **An `autoStyler(theme)` marker that resolves to `ansiStyler(theme)`**:
  rejected. The `style` getter spots `autoStyler` by identity, so a themed
  marker would be a different closure per theme, and the settings would need
  somewhere else to keep the theme anyway.
- **Only export `wantsColor()`**: rejected as the whole answer. It resolves
  when `newSpecSettings` is called rather than on first render (undoing ADR
  0058's laziness for that program), and every program wanting its own
  colours would have to remember to write it. It's kept alongside `theme`
  for the custom-`Styler` case, which `theme` can't cover.

## Consequences

Changing the colours is now `newSpecSettings(theme = theme)`, and the output
stays plain where the default's would.
