# Help Formatters can build on the Help Frame

> **Amended by [ADR 0082](0082-help-context-filter.md)**: `ctx.filter`
> narrows a Help Context to the Args a predicate keeps, and Column Style's
> variants column fits only the Args shown.

Amends ADR 0057.

ADR 0057's Help Context hands a formatter the pieces of the standard
message, but not the message around them. The private `frame` (prolog,
the labeled usage, each Help Group under its heading, epilog) was what
both built-ins wrapped, and each repeated the same group loop around it.
So a custom formatter that only wanted its own rows had to rebuild the
whole message by hand, its own width floor included. The toolkit also
had pass-throughs: `ctx.heading` ignored `ctx`, `usageLines` was
re-exported beside `ctx.usage`, and `help` re-exported `style` names
that `import argumint` already gives, plus a bare `render`, the trap ADR
0057's Consequences warns about. The width floor of 20 was clamped in
several places, with different meanings, and parse errors reached the
usage block unclamped.

## Decision

1. **The Help Frame sits beside the Help Formatter, not in place of
   it.** `HelpFormatter = proc (ctx: HelpContext): string` stays the
   whole-message seam, so ADR 0048 stands. A formatter may build on the
   frame or write the whole message itself.
2. **`ctx.frame(renderRows: RowRenderer, form = HelpTextForm.Short):
   string`** is public in `argumint/help`. It renders the prolog, the
   labeled `Usage:`, each group under its `Name:` heading, and the
   epilog, building each Arg's Rows with `ctx.rows` and rendering every
   line with the context's Styler.
   - **`RowRenderer = proc (rows: seq[Row]): seq[StyledText]`** lays out
     one group's Rows as lines. It's a closure capturing what it needs
     (`ctx.width`, Column Style's `colWidth`), so it isn't also passed
     `ctx`. It returns lines, not a string, so a formatter on the frame
     never calls `render` and can't pair resolved text with the wrong
     Styler.
   - **`HelpTextForm {.pure.} = enum Short, Long`** picks the help text
     the frame passes to `ctx.rows`: `Long` is `arg.help.longOrShort`
     (ADR 0049).
3. **The built-ins are a frame call plus a row renderer.** Column Style
   passes `columnLines`, and Paragraph Style passes `paragraphLines` with
   `HelpTextForm.Long`. Their output is unchanged.
4. **One width clamp, in the `SpecSettings.width` getter.** It returns
   at least `MinWidth` (20, in `console.nim`), so help, parse errors and
   custom formatters all read the same clamped width. `argumint/help`
   re-exports `MinWidth`; the facade doesn't. The two floors kept are on
   how narrow *text* may wrap, not the total width: Column Style's help
   column and `prose.wrap`'s hang, both written as `MinWidth`.
5. **The toolkit loses its pass-throughs.** `ctx.heading`, the
   `usageLines` and `usage` re-exports, and the `style` re-exports
   (`StyleRole`, `Span`, `StyledText`, `Styler`, `styled`, `&`, `render`,
   `plain`, `withoutTicks`) are gone from `argumint/help`, and `groups`
   absorbs the private `helpGroups` it only re-yielded. `rows(arg, help)`
   keeps its string parameter, and `longOrShort` stays public: swapping
   the string for `HelpTextForm` would trade one proc for a less flexible
   enum.

## Considered options

- **The frame as the formatter's interface**, with a formatter rendering
  only the groups: rejected for the reason ADR 0048 gives. A formatter
  that wants other labels or another order would lose the seam.
- **A per-Arg selector proc** in place of `HelpTextForm`: deferred.
  Nothing needs it yet, and it can arrive later as a defaulted parameter.
- **Rows carrying both help texts**: rejected. Every renderer would
  choose between them, which is the frame's job.
- **A bool for the help form**: rejected. A third form would break
  callers; an enum takes it.
- **Clamping in the Help Context, or in `usageLines`**: rejected. Parse
  errors don't go through the context, and `usageLines` is one reader of
  several.
- **Rejecting a narrow width with `SpecDefect`**: rejected. It's too
  harsh for a `width=` set from a `before` hook, and a narrow terminal
  still needs clamping.

## Consequences

- A custom formatter that only lays out rows is a `RowRenderer` and one
  `frame` call.
- An explicit width under 20, set or detected, reads back as 20.
- A formatter module that imports only `argumint/help`, without
  `argumint`, no longer sees `StyledText` or `styled`; the guide always
  shows both imports.
