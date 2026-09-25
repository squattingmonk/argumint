## What `parseOrQuit*`, `parsedOrQuit*` and `dot*(tuple)` do with each
## exception they catch: the text printed, the stream, and the exit code,
## as an `Outcome`. Covers the failures (`ParseError`, `ValidationError`,
## `SpecDefect`) and the messages (`MessageError` and its subtypes), not a
## successful parse. Withheld from the facade.

import ./[errors, style]

type
  Outcome* = object
    text*: string
      ## What to print, rendered with the Spec's `Styler`
    toStderr*: bool
      ## Failures go to stderr, messages to stdout (ADR 0050)
    code*: int
      ## The exit code

proc outcome*(e: ref Exception, styler: Styler): Outcome =
  ## `e`'s outcome, its labels rendered with `styler`. The text is
  ## `e.styledMsg`, or `e.msg` if something outside argumint raised `e`
  ## without one.
  template body(styledMsg: string): string =
    if styledMsg.len > 0: styledMsg else: e.msg
  template failure(label, sep, shown: string): Outcome =
    Outcome(text: styled(srError, label).render(styler) & sep & shown,
      toStderr: true, code: QuitFailure)
  if e of MessageError:
    Outcome(text: body((ref MessageError)(e).styledMsg), code: QuitSuccess)
  elif e of ParseError:
    failure("Parsing error:", "\n", body((ref ParseError)(e).styledMsg))
  elif e of ValidationError:
    failure("Validation error:", "\n", body((ref ValidationError)(e).styledMsg))
  elif e of SpecDefect: failure("Error constructing spec:", " ", e.msg)
  else: raise newException(Defect, "no outcome for " & $e.name)

when isMainModule:
  import std/unittest

  proc tagged(role: StyleRole, text: string): string = "{" & $role & ":" & text & "}"

  suite "outcome":
    test "a parse failure goes to stderr, labelled, with its styled message":
      let e = (ref ParseError)(msg: "plain", styledMsg: "styled")
      check outcome(e, tagged) ==
        Outcome(text: "{srError:Parsing error:}\nstyled", toStderr: true, code: QuitFailure)

    test "a validation failure goes to stderr, labelled":
      let e = (ref ValidationError)(msg: "plain", styledMsg: "styled")
      check outcome(e, nil) ==
        Outcome(text: "Validation error:\nstyled", toStderr: true, code: QuitFailure)

    test "a spec defect goes to stderr, labelled on the same line":
      let e = newException(SpecDefect, "bad variant")
      check outcome(e, tagged) == Outcome(
        text: "{srError:Error constructing spec:} bad variant", toStderr: true, code: QuitFailure)

    test "help, messages and completions go to stdout with QuitSuccess, unlabelled":
      for e in [(ref MessageError)((ref HelpError)(msg: "p", styledMsg: "s")),
                (ref MessageError)(msg: "p", styledMsg: "s"),
                (ref CompletionError)(msg: "p", styledMsg: "s")]:
        check outcome(e, tagged) == Outcome(text: "s", toStderr: false, code: QuitSuccess)

    test "an exception raised outside argumint without styledMsg prints msg":
      check outcome(newException(MessageError, "plain"), tagged).text == "plain"
      check outcome(newException(ParseError, "plain"), nil).text == "Parsing error:\nplain"
