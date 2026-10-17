## The Completer model: what an Arg declares about completing its value
## (`Completer`, built from a `CompleterProc` or a fixed `Offer`), what a
## Completer is told (`CompletionContext`), and what it answers (`Offer`,
## its `CompletionCandidate`s and `PathCompletion`). `argumint/completion`
## is the other half: how a shell's request is answered, using these. A
## leaf, below `argumint/backend`, whose `Arg.complete` field needs it. See
## `docs/adr/0071-runtime-completers.md`.

import std/strutils

type
  PathCompletion* {.pure.} = enum
    ## Which paths shell completion offers for a value with no enumerable
    ## values of its own -- see
    ## `docs/adr/0066-completion-falls-back-to-paths.md`.
    Files
      ## Files, and directories to descend into
    Dirs
      ## Directories only
    None
      ## No paths

  CompletionContext* = object
    ## What a Completer is told about the Tab it answers.
    word*: string
      ## The word being completed, possibly `""`. argumint filters the
      ## candidates by it anyway, so it is only for narrowing a slow query.

  CompletionCandidate* = tuple[value: string, help: string]
    ## One shell-completion candidate -- `value` is the literal word offered,
    ## `help` is a short description (possibly `""`) for shells that can render
    ## one (fish, zsh) -- see
    ## `docs/adr/0022-completion-candidate-help-text.md`. A *value* candidate
    ## carries `""` unless a Completer's `offer` described it -- see
    ## `docs/adr/0071-runtime-completers.md`. `reply` puts it on one line.

  Offer* = object
    ## A Completer's answer: candidate values, each with a description
    ## (possibly `""`), which paths the shell adds to them, and the patterns
    ## a file's name must match. Built with `offer`.
    values: seq[CompletionCandidate]
    paths: PathCompletion
    patterns: seq[string]

  CompleterProc* = proc (ctx: CompletionContext): Offer {.closure.}
    ## Lists an Arg's completion candidates when the user presses Tab. It
    ## runs inside the shell's completion, so:
    ## - return quickly, with your own timeout on any network call;
    ## - never write to stdout, which would become candidates, or stderr,
    ##   which lands in the user's shell;
    ## - expect no hook to have run, so nothing a `before` hook sets up.
    ##
    ## Earlier Args have their values filled, so a completer reads them by
    ## capturing them. A `CatchableError` it raises offers nothing. See
    ## `docs/adr/0071-runtime-completers.md`.

  CompleterKind = enum
    ckDefault ## The Arg's enumerable values, else files
    ckFixed ## The same Offer every Tab, such as a `PathCompletion`'s
    ckProc ## A `CompleterProc`, run after earlier values are filled

  Completer* = object
    ## How shell completion offers an Arg's value: a `CompleterProc`, or a
    ## `PathCompletion` converted by `toCompleter`. The zero value offers
    ## the Arg's enumerable values if it has any, otherwise files.
    case kind: CompleterKind
    of ckDefault: discard
    of ckFixed: fixed: Offer
    of ckProc: fn: CompleterProc

proc initOffer*(values: seq[CompletionCandidate], paths: PathCompletion,
    patterns: seq[string] = @[]): Offer =
  ## Machinery behind the facade's `offer` and `files`. Patterns need
  ## `Files`, and can't hold the directive's tab or newline -- see
  ## `docs/adr/0072-file-completion-patterns.md`.
  doAssert patterns.len == 0 or paths == PathCompletion.Files,
    "file patterns need paths = Files"
  for p in patterns:
    doAssert '\t' notin p and '\n' notin p,
      "a file pattern can't contain a tab or newline: " & p.escape
  Offer(values: values, paths: paths, patterns: patterns)

func values*(o: Offer): lent seq[CompletionCandidate] =
  ## `o`'s candidates, in the order given.
  o.values

func paths*(o: Offer): PathCompletion =
  ## Which paths the shell adds to `o`'s candidates.
  o.paths

func patterns*(o: Offer): lent seq[string] =
  ## The patterns a file's name must match to be offered; none means any.
  o.patterns

func initCompleter*(fixed: Offer): Completer =
  ## A Completer offering `fixed` every Tab, with nothing filled.
  Completer(kind: ckFixed, fixed: fixed)

func initCompleter*(fn: CompleterProc): Completer =
  ## A Completer running `fn`, with earlier values filled first.
  Completer(kind: ckProc, fn: fn)

func isDefault*(c: Completer): bool =
  ## Whether `c` is the zero value: the Arg's enumerable values, else files.
  c.kind == ckDefault

func fills*(c: Completer): bool =
  ## Whether earlier values are filled before `c` runs.
  c.kind == ckProc

proc run*(c: Completer, ctx: CompletionContext): Offer =
  ## What `c` offers for `ctx`. Not for the default Completer.
  case c.kind
  of ckDefault: raiseAssert "the default Completer has no Offer of its own"
  of ckFixed: c.fixed
  of ckProc: c.fn(ctx)
