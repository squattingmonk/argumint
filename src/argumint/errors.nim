## Every exception argumint raises, in one place. Deliberately a leaf module
## with no local imports, so any module can name an exception without
## depending on whichever module happens to raise it -- see
## `docs/architecture.md`.
##
## The split is by *whose* mistake it reports. `SpecDefect` is a `Defect`:
## the spec is malformed, which is a developer error caught at construction
## time and not meant to be handled. Everything else is a `CatchableError`
## raised while parsing user input -- `parse*` lets those propagate to the
## caller, `parseOrQuit*` catches them and `quit()`s with a formatted
## message (both `argumint.nim`).

type
  SpecDefect* = object of Defect
    ## A malformed developer-authored spec -- a bad `arg`/`opt`/`flag`/
    ## `command` variant string, a duplicate name, or an unparseable Usage
    ## String. Raised during spec construction, before any command-line
    ## argument is looked at.

  ParseError* = object of CatchableError
    ## The command line doesn't match any Usage Line, or a matched value
    ## couldn't be converted to its Arg's type. Its `msg` is a bulleted
    ## complaint list followed by a usage block -- see
    ## `docs/adr/0035-parse-failure-reporting.md`.

  ValidationError* = object of CatchableError
    ## A value matched the grammar but failed its Arg's own `Validator`
    ## (`validators.nim`). Never raised for a `flag`, which takes a Flag
    ## Clamp instead -- see `docs/adr/0016-flag-clamp.md`.

  MessageError* = object of CatchableError
    ## A `message()`/`version()` Arg matched: parsing short-circuits so the
    ## message can be delivered. Not a failure -- `parseOrQuit*` exits `0`.

  HelpError* = object of MessageError
    ## A `help()` Arg matched, carrying the rendered help text as its `msg`.

  CompletionError* = object of MessageError
    ## Carries the shell-completion candidates for a `__complete` request
    ## (see `fsm.parse*`) as its `msg`, one candidate per line, each
    ## formatted `"value\thelp"` (`help` may be empty, but the tab is always
    ## present -- see `docs/adr/0022-completion-candidate-help-text.md`). A
    ## peer of `HelpError`, not a subtype of it -- reuses `parseOrQuit*`'s
    ## existing `except MessageError as e: quit(e.msg, QuitSuccess)` branch
    ## for free. See `docs/adr/0012-fsm-driven-shell-completion.md`.
