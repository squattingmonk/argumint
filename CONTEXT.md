# argumint

A Nim command-line argument parsing library where a docopt-style usage
string is compiled into a finite state machine that drives parsing.

## Language

**Spec**:
The complete declaration of a command-line interface: every argument it
accepts, its Usage String, and its help text. A Command owns its own
nested Spec, scoped to that subcommand — there is no separate concept for
a "sub-spec."
_Avoid_: Parser, schema, config

**Arg**:
The umbrella concept for anything a Spec declares: a Positional Argument,
Option (including its Flag specialization), Command, or Message Argument.
Distinct from a raw string typed on the actual command line, which isn't a
named domain concept here. (Note: the code's `ArgKind` enum — Command /
Positional / Optional / Flag — classifies by token shape, i.e. whether a
following value is expected on the command line, not by this domain-level
categorization; that's a separate axis, which is why Message Argument is
tagged `kind: Flag` despite not being a domain specialization of Flag.)
_Avoid_: Argument (ambiguous with a raw command-line string)

**Variant**:
A name that denotes a particular Arg within a Usage String. All of an
Arg's Variants are interchangeable for matching purposes — any one
satisfies that Arg's position in the grammar — but whether the *specific*
Variant seen affects behavior beyond identifying the Arg depends on the
Arg kind (see Option, Flag, Command, Positional Argument).
_Avoid_: Alias, spelling, flag name

**Option**:
A named argument that takes a value via one of its Variants (e.g.
`-o value`, `--option=value`). All of an Option's Variants trigger
identical value-capturing behavior — unlike a Flag, seeing one Variant
over another never changes what happens.
_Avoid_: Optional (the code's own `ArgKind` enum is inconsistent here —
`opt*`/`opts*` name the public API, so Option is canonical), named
argument, parameter

**Flag**:
A specialization of Option that acts as a shared value slot for one or
more Flag Operations, rather than a single value-capturing behavior.
Unlike an ordinary Option, seeing a Flag's Variant doesn't require the
user to type an explicit value. (Note: the code today models Option and
Flag as siblings, not an is-a relationship — `ArgKind` and the
`ValueArg`/`FlagArg` ref object hierarchies don't yet mirror this domain
relationship.)
_Avoid_: Boolean option, switch

**Flag Operation**:
The atomic unit of Flag behavior: a single Variant paired with a
predetermined operation (set, increment, decrement, toggle, etc.) and,
where applicable, a fixed value. A Flag is the shared value slot that one
or more independent Flag Operations mutate — the Flag Operation, not the
Flag itself, determines what happens when a particular Variant is seen.
_Avoid_: FlagOp (code-level name), variant behavior

**Positional Argument**:
A value-carrying Arg whose value is determined by its position in the
argument list. Unlike an Option, Flag, or Command, its Variant (e.g.
`<src>`) is never itself matched against literal user input — the Arg
accepts any value in that position; the Variant exists only to label the
slot within the Usage String and help text.
_Avoid_: Positional, bare argument, value argument

**Command**:
A named subcommand that carries no value of its own; matching one of its
Variants routes the remaining argument list into that Command's own nested
Spec. A raw argument is checked against known Command Variants before it's
considered for a Positional Argument. All Variants route to the same
nested Spec, but a Command's handler could still branch on which Variant
was actually seen.
_Avoid_: Subcommand, verb, action

**Message Argument**:
An Arg whose match, via any of its Variants, displays a fixed message and
halts parsing instead of capturing a value — a peer of Positional
Argument, Option, and Command, not a specialization of Flag. Built with
`message()`/`version()`; Help is the built-in specialization whose
displayed message is the Spec's dynamically-generated usage/help text
rather than a fixed author-supplied string.
_Avoid_: MessageArg (code-level name), display flag

**Options Catch-all**:
The `[options]` construct in a Usage Line, matching any Option or Flag not
explicitly named elsewhere in that same Usage Line. An Option or Flag
reachable only through the catch-all is Repeatable by default -- unlike an
explicitly-named Arg, it needs no Repetition marker of its own, since
argumint's static single-/multi-value typing (not repetition) already
determines whether repeated matches accumulate into a list or are simply
redundant (see `docs/adr/0002-catch-all-options-repeatable-by-default.md`
for why). "Explicitly named" scopes to the current Usage Line only -- an
Option or Flag named explicitly on one Usage Line is still reachable
through the catch-all on a different Usage Line in the same Usage String.
_Avoid_: `[options]`, options wildcard

**Repetition**:
The `...` suffix in a Usage Line, marking an explicitly-named Positional
Argument, Option, or Flag as matchable more than once. Without it, an
explicitly-named Arg matches at most once. Doesn't apply the same way to
the Options Catch-all, where repeatability is the default for whatever's
reachable only through it, independent of any `...` -- see Options
Catch-all.
_Avoid_: Ellipsis, repeat marker

**Match Accumulation**:
The rule governing how multiple matches of the same Arg combine into its
final stored value, which differs by Arg kind:
- Scalar Option/Positional Argument: each match overwrites the previous —
  the final match wins.
- Multi-value Positional Argument: each match appends to an ordered list.
- Multi-value Option: today, each match always appends to an ordered
  list, same as a multi-value Positional Argument. This is expected to
  grow into a selectable operation (prepend/append/remove/reset,
  mirroring Flag Operation) once the operator symbol already tokenized
  into `optSep` is wired through to parsing -- see `TODO.md`. This future
  pluggability is Option-only: a Positional Argument has no separator
  syntax to select an operation with.
- Flag: each match applies its Variant's Flag Operation to one shared
  value, in the order seen — composing sequentially, not overwriting or
  listing. This ordering is a guaranteed invariant, not incidental: an
  Arg's matches are always consumed earliest-remaining-first from the
  original command line and never reordered, so repeated matches of the
  same Flag are always recorded, and thus applied, in true left-to-right
  command-line order.
_Avoid_: Accumulation, repeat handling

**Validator**:
A constraint attached to a Positional Argument or Option, checked against
the converted value before it's stored. A value that fails to convert to
the Arg's type raises `ParseError`; a value that converts successfully but
fails the Validator raises `ValidationError` instead -- two distinct
failure points, not one. Never applies to Flag, Command, or Message
Argument, since a Flag's value comes from author-declared Flag Operations
rather than arbitrary user-typed text. Always checked against
the scalar element type, never a collected list, even for a multi-value
Arg -- each match is validated individually as it arrives. Currently one
kind per Validator: Choice (value must be one of an enumerated set), Range
(value must fall within a range), or Check (value must satisfy an
arbitrary predicate, with an optional description for help text). A
Validator runs on a value from the command line or from Value
Precedence's environment-variable tier (both funnel through the same
conversion path), but never on the coded default, which is substituted
later at read time instead -- whether that's intended or not is still an
open question (see `TODO.md`).

Planned: a fourth kind, **All**, composing several Validators so every one
of them must pass (AND-only, e.g. a Range and a Check together) -- see
`TODO.md`.
_Avoid_: Constraint, check (ambiguous with the Check kind specifically)

**Usage String**:
The complete docopt-style declaration of a Spec's valid argument patterns —
one or more Usage Lines, each an independent alternative, implicitly OR'd
together.
_Avoid_: Grammar, usage text

**Value Precedence**:
The fixed order in which candidate sources are consulted to determine an
Option's (or Flag's) final value: an explicit value from the actual
command line, then a value from a configured environment variable, then a
coded default. Applies only to Option/Flag — a Positional Argument or
Command has no environment-variable source. For a Flag specifically, the
environment-variable tier always applies via the `=` Flag Operation,
regardless of which Flag Operations the Arg's declared Variants actually
use.
_Avoid_: Fallback order, resolution order

**Usage Line**:
One line within a Usage String, expressing one complete alternative
invocation pattern (e.g. `[-r] <src>... <dest>`).
_Avoid_: Usage pattern, usage rule
