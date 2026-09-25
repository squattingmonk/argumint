# Terminal width and colour are detected on first read

`newSpecSettings` used to probe the terminal as soon as it was called: its
`width` default ran `detectWidth()`, and its `style` default ran
`autoStyler()`, which on Windows turns on the console's ANSI handling with
`SetConsoleMode`. `command()` calls `newSpec` without settings, so every
nested command evaluated those defaults too, only for the root to cascade
its own settings over them. A program passing `newSpecSettings(style =
nil)` still changed the Windows console mode once per nested command, and
every Spec probed the terminal whether or not anything was printed.

Now both are detected on first read (#123). `SpecSettings.width` and
`.style` are private fields behind getter and setter procs. Each field starts
as a placeholder, `0` for the width and `autoStyler` for the style. The
getter resolves the placeholder, stores the result, and returns it:
`min(detectWidth(), DefaultMaxWidth)` for the width, and
`ansiStyler(defaultTheme)` or nil for the style. Neither result is the
placeholder, so later reads never probe again. Assigning `0` or
`autoStyler` makes the next read detect again.

`autoStyler` is now a marker, not a call. It has the `Styler` signature and
leaves text plain if used as one, so `style = autoStyler` means "resolve on
first read", `nil` still means plain, and any other styler is used as
given. An explicit `width` is used as given, as before.

Only help rendering (`helpContext`), the parse-error complaint and
`parseOrQuit` read either field. So building settings or a Spec never
touches the terminal, a parse that prints nothing never probes it, and on
Windows the console mode only changes just before styled output is
printed. `command()` is unchanged: its default `newSpecSettings()` now only
allocates.

The detection itself lives in `console.nim` (#122), as `resolvedWidth` and
`resolvedStyler`, withheld from the facade.

This supersedes ADR 0051's "resolved once when the settings are built",
which cited only the `width` precedent, and ADR 0052's description of the
default `width`. ADR 0052 rejected a "0 = detect" sentinel as too large a
change for a `maxWidth` knob; the reason here is different, and the cap
stays a constant.

## Considered options

- **A stand-in settings object in `command()`**, built from the
  compile-time defaults without probing. Rejected: it fixes the nested
  commands but not the root, which still probes at construction.
- **`nil` settings on a nested Spec until the root cascades.** Rejected: it
  saves an allocation, but `CommandArg.spec` is public, and a `command(...)`
  result that was never attached would crash on its first read.
- **A `settings` parameter on `command()`.** Rejected: settings cascade
  from the root, which is why `command()` documents not having one.
- **A new name for the marker** (e.g. `detectStyle`). Rejected: keeping
  `autoStyler` makes the only visible change dropping the `()`.
- **A named `AutoWidth` constant.** Rejected: an explicit `0` was only
  clamped to the 20-column floor before, so `0` meaning "detect" takes
  nothing away.

## Consequences

- `style = autoStyler()` no longer compiles; drop the `()`.
- `SpecSettings(width: ..., style: ...)` no longer compiles; use
  `newSpecSettings`.
- Calling the styler through the settings needs parentheses:
  `(settings.style)(role, text)`, since `settings.style(role, text)` reads
  as a call to the getter.
- `width` and `style` appear in the API docs as procs, not fields.
- Inside `backend.nim`, `s.width` and `s.style` read the raw field, not the
  getter (`docs/gotchas.md`).
