# Parse-error complaints are styled by role, with `srInvalid` for bad input

ADR 0051 styled only a parse error's `Parsing error:` label and its usage
block, leaving the complaint list plain. The complaints are now styled too,
and a new Style Role, `srInvalid`, marks the token the user got wrong. The
default Theme shows it bold yellow, so the error label stays the only red.

```
  - unrecognized option: --shp; did you mean --ship?
                         ^^^^^ srInvalid     ^^^^^^ srOption
```

Each complaint's roles are assigned where it's built, which already knows
what every piece names:

- **`srInvalid`**: an unrecognized option or command, the typed token of an
  unexpected leftover (a whole `--name=value`), and both the short option
  and the cluster it came from in `-z (in -xyz)`.
- **The role it has in help**: a Did-You-Mean suggestion (`srOption` or
  `srCommand`), a missing option (with `=<m>` split off, as in a help
  row), argument (`srPositional`) or command (`srCommand`), a starved
  option, and an option a fallback tier oversupplies.
- **`srPlain`**: the kind labels, bullets, `|` and parentheses, the
  Did-You-Mean and starved wording, and a converter's or validator's
  message.

Roles come from the call site, not Help Markup, because a complaint holds
text the user typed, and typed input must never be parsed as markup. A
converter's or validator's message stays plain for now: it's free text
from the author, and Help Markup there is a separate decision.

The offending token gets its own role, as clap's errors do, rather than
reusing the role of what it looks like. A mistyped `--shp` isn't an option
this program has, and styling it like `--ship` would blur the one
difference the message is about.

`ParseError.msg` and `ValidationError.msg` are unchanged, being the plain
text of the same complaints; only `styledMsg` changes. Complaints that
differ only in role still count as one, so styling never changes which
complaints appear.

Adding `srInvalid` to `StyleRole` is a breaking change for a `Theme`
written as a complete array literal, which must add an entry. One copied
from `defaultTheme`, as the README shows, is unaffected.

## Considered options

- **Style the complaints with Help Markup.** It would need the wording to
  backtick every name, and would parse whatever the user typed as markup.
- **Style the offending token by its shape** (`--shp` as `srOption`). No
  new role, but it colours a typo like a real option.
- **Use `srError` for the offending token.** It makes the label and the
  token compete, and a Theme couldn't style them apart.
