# `completion()` is a built-in command printing the completion script

Amends ADR 0012.

ADR 0012 left script generation "explicit and author-driven":
`completionScript` returns the script, and the author exposes it. In
practice every CLI wrote the same `completion <shell>` command, with a
`var cli: Spec` declared before the spec so the hook could reach the root,
and `choice` or `arg[Shell]` for the shell. As an ordinary `action`, it also
left `info.showsMessage` false, so a `before` hook that skips setup for
`--help` still ran it for `completion fish`.

## Decision

1. **`completion(variants = "completion", help, prolog, epilog, group,
   hidden): CommandArg`** sits in the facade beside `help`, `message` and
   `version`, and is used as `completion: completion()`. Its own Spec is
   `<shell>` and `help()`, with usage `<shell>`.
2. **`<shell>` is a positional Message Argument** (ADR 0073): a withheld
   subtype of `ValueArg[Shell]`, declared in `argumint.nim` since that's
   the only module importing both `argtypes` and `completion`. Being a
   `Shell`, help shows `[choices: bash, zsh, fish]`, Tab offers the three,
   and anything else is a parse error before any hook. Its `action` raises
   a `MessageError` carrying `info.root.spec`'s script, so `parseOrQuit`
   prints it to stdout and exits 0 (ADR 0050), and `info.showsMessage` is
   true for the invocation.
3. **The script completes `info.root.command`**, the `command` given to
   `parse`, which defaults to `appName()`. Help's usage lines and the script
   always name the program alike.
4. **The default `prolog` says how to load the script** in each shell,
   with `prog` standing for the program, whose name isn't known when the
   Spec is built.
5. **The script is still never wired in automatically.** `completion()` is
   opt-in, like `help()`, and `completionScript` stays public for packaging
   that writes the script at build or install time.

## Considered options

- **A building-block Message Argument the user places in their own
  command**: deferred. It can be exported later without breaking anything.
- **An option, `--completion=<shell>`**: rejected. Cobra, clap and Click
  all use a subcommand.
- **A `binaryName` parameter**: rejected. The `command` given to `parse`
  already names the program, and a second name could disagree with it.
- **`before`/`action`/`after` parameters**: rejected. The command only
  prints a message, so no `action` would fire, and the root's hooks already
  run around it.

## Consequences

- A CLI's hand-written `completion` command can become `completion:
  completion()`, dropping the kept `Spec` and its hook.
- A `before` hook guarding with `info.showsMessage` now skips its setup for
  `completion <shell>` too.
- A plain `arg[Shell]` elsewhere is unaffected: only the withheld subtype
  is a Message Argument.
