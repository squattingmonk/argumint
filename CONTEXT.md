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
Arg -- each match is validated individually as it arrives, though a Check
built via `checkSeen`/`unique` may also consult Seen Values (see below).
Six kinds: Choice (value must be one of an enumerated set), Range (value
must fall within a range), Check (value must satisfy an arbitrary
predicate, with an optional description for help text), a history-aware
specialization of Check built via `checkSeen`/`checkSeenIt`/`unique` (see
Seen Values), and the two composing kinds, All and Any (see below). A
Validator runs on a value from the command line or from Value Precedence's
environment-variable tier (both funnel through the same conversion path),
but never on the coded default, which is substituted later at read time
instead -- whether that's intended or not is still an open question (see
`TODO.md`).
_Avoid_: Constraint, check (ambiguous with the Check kind specifically)

**Seen Values**:
The sequence of values already matched for the same multi-value Option or
Positional Argument at the moment a new candidate value is being checked --
consulted only by a Check Validator built via `checkSeen`/`checkSeenIt`/
`unique` (every other Validator kind ignores it). Reflects everything ever
matched across every `parse` call made on that Arg's spec tuple, not just
the current call, since nothing resets an Arg's accumulated state between
`parse` calls on a reused spec tuple (deliberately; see
`docs/adr/0007-history-aware-validators.md`). Never includes the candidate
value currently being checked. A caller wanting Seen Values scoped to a
single `parse` call should wrap spec construction in a builder proc and
call it fresh each time, per the same ADR.
_Avoid_: history, accumulated values (ambiguous with a multi-value Arg's
stored result, which is a superset -- Seen Values excludes the candidate)

**All**:
A Validator composing several other Validators of the same element type
with AND semantics -- every one must pass. Short-circuits left-to-right:
the first child to fail determines the failure. May itself contain another
All or Any as a child; children are never auto-flattened into the parent's
list, both because a mixed All/Any nest can't be flattened without
changing its meaning, and because flattening would silently discard a
child's own optional `desc` override. See Any for the OR counterpart, and
Validator Failure Message for how All and Any report failure differently.
_Avoid_: AND, combinator (ambiguous with Any, which is also a combinator)

**Any**:
A Validator composing several other Validators of the same element type
with OR semantics -- at least one must pass. May itself contain another
Any or All as a child, with the same no-auto-flatten rule as All. In
generated help text, a child that is itself a composite (All or Any) is
parenthesized to disambiguate nested AND/OR grouping, e.g. `(choices: a, b
or range: 0..5) and must be even`. See All for the AND counterpart, and
Validator Failure Message for how All and Any report failure differently.
_Avoid_: OR, combinator (ambiguous with All)

**Validator Failure Message**:
The text of the `ValidationError` a failing Validator raises. All and Any
both accept the same optional trailing `desc` override (named to match
Check's existing `desc` param, and to avoid colliding with the `help()`
proc), and both use it identically when given: it's shown directly as the
failure reason, regardless of which child(ren) actually failed. They
differ only when `desc` is absent: All passes the first failing child's
own message through
verbatim (already the most specific reason, since All short-circuits), while
Any -- which has no single dispositive failing child, since none of them
passed -- falls back to joining each child's own help text with "or".
_Avoid_: error message (ambiguous with `ParseError`'s conversion-failure
message, a separate failure point -- see Validator)

**Usage String**:
The complete docopt-style declaration of a Spec's valid argument patterns —
one or more Usage Lines, each an independent alternative, implicitly OR'd
together.
_Avoid_: Grammar, usage text

**Value Precedence**:
The fixed order in which candidate sources are consulted to determine an
Option's (or Flag's) final value: an explicit value from the actual
command line, then a value from a configured environment variable, then a
coded default. Applies uniformly regardless of whether the Option/Flag is
required or optional in the usage grammar, and only to Option/Flag — a
Positional Argument or Command has no environment-variable source.

The environment-variable tier can contribute more than one value: the raw
env string is always split (see Env Delimiter), and each resulting value
is consumed one at a time, each time the Arg's position in the FSM is
actually walked. Whether that happens once or several times is never
precomputed or stored anywhere — it falls straight out of the graph
already built from the Usage String, the same way it does for real
command-line tokens: a genuine repeat (Repetition, or Options Catch-all)
loops back and keeps consuming values until the split list runs out; the
same Arg named more than once in one Usage Line with no Repetition marker
is just several separate positions, each consuming one value in turn, no
different in kind. If the env var has values left over once the walk
finishes — more than the Usage Line actually had positions for — that's a
parse failure, not a silent truncation to a prefix of the values (this is
what keeps a single-position Option whose one legitimate value happens to
contain the delimiter safe: it fails loudly rather than silently using
only the first fragment). An Arg whose position was never reached at all
in the matched Usage Line — reachable only through a different Usage Line
that isn't the one that ended up matching — has no walk-derived count to
bound it by, so every available value is applied; env is a per-Arg
concern, not a per-Usage-Line one, so it still applies even to an Arg the
matched Usage Line never mentions.

For a Flag specifically, each value names one of the Flag's own declared
Variants (matching its literal spelling, e.g. `--verbose`) and is applied
via *that* Variant's own Flag Operation — unlike an ordinary Option, a
Flag's env value was never a value in `T` to begin with, so there's
nothing else for it to name.
_Avoid_: Fallback order, resolution order

**Env Delimiter**:
The character sequence a configured environment variable's raw value is
split on before being fed into Value Precedence's environment-variable
tier. Always `\x1e` (ASCII Record Separator) if present — this is how
fish auto-joins a native list variable's elements when exporting it to a
subprocess's environment, for any variable name, not just ones fish
special-cases like `PATH` — otherwise `Spec.envDelim`, which cascades to
nested Command Specs the same way `width` does and defaults to `:` (the
`PATH`-style convention `bash`/`zsh` users already reach for). A resulting
empty value (a stray leading/trailing/doubled delimiter) is kept as a
literal value rather than dropped, so an env value is never treated
differently from a value typed on the command line.
_Avoid_: envDelim (code-level name, fine in prose about the API itself)

**Usage Line**:
One line within a Usage String, expressing one complete alternative
invocation pattern (e.g. `[-r] <src>... <dest>`).
_Avoid_: Usage pattern, usage rule
