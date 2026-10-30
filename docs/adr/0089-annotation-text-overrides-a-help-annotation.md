# `AnnotationText` overrides a Help Annotation

Amends [ADR 0088](0088-help-context-filters-help-annotations.md), whose
first rejected option it half adopts, and
[ADR 0016](0016-flag-clamp.md)'s `desc`. It ships in a minor release: the
signatures stay source compatible, and
[ADR 0080](0080-1x-freezes-the-public-modules-and-the-usage-grammar.md)
doesn't freeze help or error text.

A Validator's `desc` is a bare `string`: `""` keeps the generated text, and
anything else replaces both its Help Annotation and the reason in its
Validator Failure Message. A Flag Clamp's `desc` is an `Option[string]`,
where `some("")` hides the annotation (issue #12). So a Flag Clamp can say
"I have no annotation" and a Validator can't, and the two spell the same
idea differently (issue #357). ADR 0088 turned down a Validator
`some("")` only because `desc` was also the failure text and its type
couldn't change in 1.x.

A custom `desc` also reads badly in failures. Authors write one to tame
long or opaque generated help: `a NATO phonetic alphabet letter` instead
of 26 quoted choices, `a positive even number` instead of
`it >= 0 and it mod 2 == 0`. Those are noun phrases for what's accepted,
and they fit help. A failure puts them after
`3 did not meet condition: `, a frame written for a predicate like
`must be even`, while `choice` and `range` generate
`got "x" but expected one of …` and `got 5 but expected a value in 0..4`.

## Decision

1. **`AnnotationText` is generated, custom or hidden text for a Help
   Annotation.** It's a public `distinct Option[string]` with two
   converters: from `string`, where `""` is `none` (generated) and other
   text is custom; and from `Option[string]`, where `some("")` is hidden.
   It's distinct because a converter to `Option[string]` itself would join
   every overload resolution in a program that imports argumint, as
   `ConfigKey`'s did (ADR 0029). Validators and Flag Clamps use it first;
   it's named for any Help Annotation, so a later override of another kind,
   such as a default's, can take it too.
2. **Every Validator constructor and `clamp`/`adjust` take
   `desc: AnnotationText`.** That's `choice`, `range`, `check`, `checkIt`,
   `checkSeen`, `checkSeenIt`, `unique`, `all` and `any`. An existing call
   compiles and means what it did: `desc = "x"`, `desc = ""`, a string
   variable, and a Flag Clamp's `some(...)`/`none(string)`.
3. **One text serves help and failure.** A custom `desc` describes what's
   accepted, as a noun phrase. It replaces the generated Help Annotation,
   and a failure reads `got <value> but expected <desc>`. A hidden `desc`
   shows no annotation, and the failure stays generated: an empty reason
   is no reason.
4. **Generated text keeps a frame that fits it.** `choice` and `range`
   already use `got … but expected …`. `unique`'s generated text becomes
   `a unique value`, in the same frame. A `checkIt`/`checkSeenIt`
   predicate's source text and `any`'s joined child help aren't noun
   phrases, so they keep `<value> did not meet condition: <text>`. A plain
   `check` with no text keeps the bare `<value> did not meet condition`.
   `all` with no custom text still passes on its failing child's message.
5. **Two kinds of hiding.** `desc = some("")` is the Arg saying it has no
   annotation, the same in every help message. One help message showing
   less than another, such as a terse `--help` beside a detailed one, is
   still a formatter's `filterAnnotations` (ADR 0088).

Help Markup is unchanged: a custom `desc` gets it in help and is shown
plain in a failure.

## Considered options

- **Separate help and failure text** (`help: Option[string]` beside
  `failure: string`): rejected. A description that reads badly in one
  place is badly written, not a sign the two need different text; the
  real mismatch was the failure frame. Not prototyped on its own; the
  modifier prototype below carried both texts.
- **Chained modifiers** (`range(1..65535).withHelp("…").withFailure("…")`,
  no text parameters): prototyped, and it worked, including with
  `all`/`any` and `checkIt`. Rejected for now: it would be the only chained
  API in argumint and needed 2.0 to drop `desc`. Whether 2.0 adopts
  chaining is a library-wide question, for when it has more than one use.
- **A converter from `string` to `Option[string]`**: rejected for
  ADR 0029's reason. `AnnotationText` is distinct instead.
- **A named constant for hiding** (`desc = noHelp`): not added. Flag Clamps
  already document `some("")`, and one spelling serves both kinds.
- **Keeping `did not meet condition:` for custom text**: rejected. It
  suits a predicate, not the noun phrase a description is.

## Consequences

- A Validator can hide its own annotation, spelled as a Flag Clamp's is.
- A custom failure reads like a generated one.
- A failure message for a Validator with a custom `desc` changes wording.
  A test that pins it needs updating after a minor upgrade.
- `unique`'s generated help changes from `must be unique` to
  `a unique value`.
- `AnnotationText` appears in every constructor's signature, and its two
  converters are in scope wherever argumint is imported.
