## What `parseOrQuit*` does with each exception it catches: the text it
## prints, the stream, and the exit code, as an `Outcome`. Covers the
## failures (`ParseError`, `ValidationError`, `SpecDefect`) and the messages
## (`MessageError` and its subtypes), not a successful parse. Withheld from
## the facade.

import ./[errors, style]

type
  Outcome* = object
    text*: string
      ## What to print, rendered with the Spec's `Styler`
    toStderr*: bool
      ## Failures go to stderr, messages to stdout (ADR 0050)
    code*: int
      ## The exit code

proc body(e: ref Exception): string =
  ## `e.styledMsg`, or `e.msg` if something outside argumint raised `e`
  ## without one.
  let styled =
    if e of ParseError: (ref ParseError)(e).styledMsg
    elif e of ValidationError: (ref ValidationError)(e).styledMsg
    elif e of MessageError: (ref MessageError)(e).styledMsg
    else: ""
  if styled.len > 0: styled else: e.msg

proc outcome*(e: ref Exception, styler: Styler): Outcome =
  ## `e`'s outcome, its labels rendered with `styler`.
  template failure(label, sep: string): Outcome =
    Outcome(text: styled(srError, label).render(styler) & sep & e.body,
      toStderr: true, code: QuitFailure)
  if e of MessageError: Outcome(text: e.body, code: QuitSuccess)
  elif e of ParseError: failure("Parsing error:", "\n")
  elif e of ValidationError: failure("Validation error:", "\n")
  elif e of SpecDefect: failure("Error constructing spec:", " ")
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
