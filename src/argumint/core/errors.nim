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
##
## Every failure of the user's input is a `ParseError`, raised as one of its
## three subtypes -- `UsageError`, `ConversionError`, `ValidationError` -- or,
## when one parse fails in more than one of those ways, as `ParseError`
## itself. See `docs/adr/0078-parse-error-hierarchy.md`.

type
  SpecDefect* = object of Defect
    ## A malformed developer-authored spec -- a bad `arg`/`opt`/`flag`/
    ## `command` variant string, a duplicate name, or an unparseable Usage
    ## String. Raised during spec construction, before any command-line
    ## argument is looked at.

  ParseError* = object of CatchableError
    ## Anything the user's input got wrong. Raised as itself only when the
    ## failures it reports span more than one subtype, or when user code
    ## raises it. Its `msg` is a bulleted complaint list followed by a usage
    ## block -- see `docs/adr/0035-parse-failure-reporting.md`.
    styledMsg*: string
      ## `msg` rendered by the Spec's `Styler`, for `parseOrQuit*` to print;
      ## the same as `msg` if the Spec has none, and empty only if raised
      ## outside argumint. `msg` itself stays plain -- see
      ## `docs/adr/0059-plain-help-msg.md`

  UsageError* = object of ParseError
    ## The input doesn't fit any Usage Line: an unrecognized, unexpected or
    ## missing option, argument or command. Also a fallback tier supplying
    ## more values than the walk had room for, though the user didn't type
    ## them.

  ConversionError* = object of ParseError
    ## A value won't convert to its Arg's type, or names no Variant of the
    ## flag it was supplied to.

  ValidationError* = object of ParseError
    ## A value matched the grammar but failed its Arg's own `Validator`
    ## (`validators.nim`). Never raised for a `flag`, which takes a Flag
    ## Clamp instead -- see `docs/adr/0016-flag-clamp.md`.

  MessageError* = object of CatchableError
    ## A `message()`/`version()` Arg matched: parsing short-circuits so the
    ## message can be delivered. Not a failure -- `parseOrQuit*` exits `0`.
    styledMsg*: string
      ## As `ParseError.styledMsg`

  HelpError* = object of MessageError
    ## A `help()` Arg matched, carrying the rendered help text as its `msg`.

  CompletionError* = object of MessageError
    ## Carries the shell-completion candidates for a `__complete` request
    ## (see `fsm.parse*`) as its `msg`, one candidate per line, each
    ## formatted `"value\thelp"` (`help` may be empty, but the tab is always
    ## present -- see `docs/adr/0022-completion-candidate-help-text.md`). A
    ## peer of `HelpError`, not a subtype of it -- `parseOrQuit*` prints it
    ## to stdout like every other message (`outcome.nim`). See
    ## `docs/adr/0012-fsm-driven-shell-completion.md` and
    ## `docs/adr/0050-message-output-to-stdout.md`.

proc newPlainError*[E: ParseError | MessageError](
    kind: typedesc[E], msg: string): ref E =
  ## An `E` whose `styledMsg` is `msg`, for text raised where there's no
  ## Styler to render it. Withheld from the facade.
  (ref E)(msg: msg, styledMsg: msg)
