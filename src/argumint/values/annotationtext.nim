## `AnnotationText`, the `desc` a Validator or Flag Clamp takes to replace
## or hide its generated Help Annotation. See
## `docs/adr/0089-annotation-text-overrides-a-help-annotation.md`.

import std/options

type
  AnnotationText* = distinct Option[string]
    ## A Help Annotation's text: generated (`""`, the default), custom (any
    ## other string), or hidden (`some("")`). A custom one is a noun phrase
    ## for what's accepted, such as `a positive even number`.
    ##
    ## `distinct` so its converters don't leak: see
    ## `docs/adr/0029-config-key-distinct.md`.

converter toAnnotationText*(text: string): AnnotationText =
  ## Lets a `desc` param be given a plain string: `""` keeps the generated
  ## text, and anything else replaces it.
  AnnotationText(if text.len > 0: some(text) else: none(string))

converter toAnnotationText*(text: Option[string]): AnnotationText =
  ## Lets a `desc` param be given an `Option`: `some("")` hides the
  ## annotation, other `some` text replaces it, and `none` keeps it
  ## generated.
  AnnotationText(text)

when isMainModule:
  import std/unittest

  suite "AnnotationText":
    test "an empty string is generated, and some(\"\") is hidden":
      check Option[string](toAnnotationText("")) == none(string)
      check Option[string](toAnnotationText("x")) == some("x")
      check Option[string](toAnnotationText(some(""))) == some("")
      check Option[string](toAnnotationText(none(string))) == none(string)
