## Generates thin per-shell adapter scripts for dynamic completion. See
## `docs/adr/0012-fsm-driven-shell-completion.md` and
## `docs/adr/0022-completion-candidate-help-text.md`.
##
## Because completion is resolved dynamically (the compiled binary re-walks
## its own FSM via `completeArgs*` on every request), these scripts need to
## know almost nothing about `Spec`'s contents: they
## never enumerate commands/options themselves. Each one is purely
## mechanical -- register a completion function for `binaryName`, shell out
## to `<binaryName> __complete <words...>`, split stdout into one
## "value\thelp" line per candidate (`help` possibly empty, tab always
## present), and feed each candidate into that shell's own reply mechanism
## -- rendering the help text where the shell supports it (fish, zsh), or
## stripping it where it doesn't (bash).

import std/[importutils, sets, strformat, strutils, sugar, tables]

import ./[backend, matching, tokens]

# Reaches `Spec`'s private fields (ADR 0030) from non-generic code only -- see
# docs/gotchas.md.
privateAccess(Spec)

type
  Shell* {.pure.} = enum
    bash, zsh, fish

  Frontier = seq[tuple[state: State, pc: ParseContext]]
    ## Every `State` simultaneously still reachable after consuming a given
    ## prefix of tokens, paired with the `ParseContext` that reached it -- see
    ## `collectFrontier`.

  CompletionCandidate* = tuple[value: string, help: string]
    ## One shell-completion candidate -- `value` is the literal word offered,
    ## `help` is a short description (possibly `""`) for shells that can render
    ## one (fish, zsh) -- see ADR 0022. `help` is only ever non-empty for an
    ## Arg's own name (option/flag/command); a *value* candidate (an enumerable
    ## positional's or Choice validator's own values) always carries `""`, since
    ## there's no per-value description in the data model to draw from -- see
    ## architecture.md §6.

proc bareVariants(spec: Spec, arg: Arg, variant = ""): seq[string] =
  ## The bare option/flag spellings actually typed on the command line for
  ## `arg` (e.g. "--log-level", never "--log-level=<level>"). Reads
  ## `spec.options`, the same canonical bare-name -> Arg map `classify`
  ## itself looks up against, rather than re-deriving stripping logic from
  ## `arg.variants` -- for an Optional-kind `ValueArg` (`opt`/`args`),
  ## `variants` stores the *declared* string verbatim, including any
  ## `=<placeholder>` suffix used only for help-text rendering (`FlagArg`
  ## already stores bare names at construction time, so this is a no-op for
  ## it, but reusing one rule for both is simpler than branching by kind).
  ##
  ## When `variant` is non-empty, only variants that are `arg.aliases` of it
  ## are returned (`aliases` is reflexive, so this covers an exact literal
  ## match too) -- so a specific `Option`-kind transition (`candidateWords`)
  ## offers just its own FlagOp Alias set (e.g. `-u`'s completion never
  ## includes `-d`'s), rather than every variant `arg` has anywhere on the
  ## usage line. A no-op for non-Flag Args, whose base `aliases` always
  ## returns true for any two of their own variants. Leave `variant` blank
  ## for a catch-all context (e.g. `[options]`'s `Options`-kind matcher, or
  ## `pendingOptionalArgs`'s "was this bare word typed at all" check) where
  ## every variant genuinely applies.
  for k, v in spec.options:
    if v == arg and (variant.len == 0 or arg.aliases(variant, k)):
      result.add k

proc describeVariants(arg: Arg, variants: seq[string]): seq[CompletionCandidate] =
  ## Pairs each of `arg`'s own `variants` with its most useful description.
  ## `arg.variantDesc(v)` (e.g. a flag's auto-generated "Increase by 5", or
  ## a `flagOp*` call's own `help` override -- see `flag*`) is only trusted when `arg`'s
  ## variants genuinely diverge in what they do, i.e. `variantDesc` returns
  ## more than one distinct value across them; otherwise every variant
  ## shares `arg.help`. This mirrors `help.variantGroups`'s own
  ## "collapse to one group whenever every variant agrees" rule (used by
  ## `genHelp`) -- without it, an ordinary flag with no divergent variants
  ## (e.g. a bare bool `flag("--verbose", help = "Be noisy")`) would show
  ## its type's auto-generated blank-op description ("Toggle the value")
  ## instead of its own `help`, since `variantDesc`'s base case for a
  ## non-divergent flag still returns that blank description, not `""`.
  var descs: seq[string]
  for v in variants:
    descs.add arg.variantDesc(v)
  let divergent = descs.toHashSet.len > 1
  for i, v in variants:
    let desc = descs[i]
    result.add (v, if divergent and desc.len > 0: desc else: arg.help)

proc addUnseen(result: var seq[CompletionCandidate], seen: var HashSet[string],
    candidates: openArray[CompletionCandidate], prefix: string) =
  ## Appends each of `candidates` whose `.value` starts with `prefix` and
  ## hasn't already been seen (via `seen`, keyed on `.value` alone) into
  ## `result`, preserving first-seen-wins order -- the dedup rule shared by
  ## `candidateWords` and `completeArgs*`'s own pending-value branch.
  for c in candidates:
    if c.value.startsWith(prefix) and c.value notin seen:
      seen.incl c.value
      result.add c

proc candidateWords(frontier: Frontier, prefix: string): seq[CompletionCandidate] =
  ## Reads every live frontier state's own outgoing transitions for literal
  ## next-word spellings (option/flag variants, command variants, or an
  ## enumerable positional's `completions()`), keeping only ones starting
  ## with `prefix` and deduplicating while preserving first-seen (== FSM
  ## priority/declaration) order.
  var seen: HashSet[string]
  for (state, pc) in frontier:
    for tr in state.transitions:
      let candidates =
        case tr.matcher.kind
        of mkOption: describeVariants(tr.matcher.opt, pc.cursor.spec.bareVariants(tr.matcher.opt, tr.matcher.variant))
        of mkOptions:
          collect:
            for opt in tr.matcher.opts:
              for c in describeVariants(opt, pc.cursor.spec.bareVariants(opt)): c
        of mkCommand: describeVariants(tr.matcher.cmd, tr.matcher.cmd.variants)
        of mkArgument:
          collect:
            for v in tr.matcher.arg.completions(): (v, "")
        of mkOptsEnd: newSeq[CompletionCandidate]() # invisible -- see ADR 0020 point 8
        of mkShortcut: newSeq[CompletionCandidate]()
      result.addUnseen(seen, candidates, prefix)

proc pendingOptionalArgs(frontier: Frontier, name: string): seq[Arg] =
  ## Every distinct `Optional`-kind (value-taking, not `Flag`) Arg reachable
  ## from a live frontier state whose variants include `name` exactly --
  ## used by `completeArgs` to detect "the last already-typed word is itself
  ## a bare option name still awaiting its value" (e.g. `--log-level` typed
  ## with nothing after it yet).
  var seenArgs: HashSet[Arg]
  for (state, pc) in frontier:
    for tr in state.transitions:
      var candidates: seq[Arg]
      case tr.matcher.kind
      of mkOption: candidates = @[tr.matcher.opt]
      of mkOptions: candidates = tr.matcher.opts
      else: discard
      for arg in candidates:
        if arg.kind == Optional and name in pc.cursor.spec.bareVariants(arg) and arg notin seenArgs:
          seenArgs.incl arg
          result.add arg

proc collectFrontier(s: State, pc: ParseContext, acc: var Frontier, seen: var HashSet[State]) =
  ## Generalizes `walk` into "every live branch, not just the first to
  ## succeed" for shell completion -- see architecture.md §6.
  ##
  ## `seen` only bounds zero-token transitions (a `mkShortcut`, or an
  ## env-satisfied `Option`); anything that consumes a real token recurses
  ## with a fresh `seen`, since that's a strictly smaller sub-problem.
  ## Revisiting a `State` within one zero-token layer can't discover
  ## anything new, since its transitions and `pc.cursor`'s tokens are
  ## unchanged -- so skipping it is safe, not just an optimization.
  if s in seen:
    return
  seen.incl s

  if pc.cursor.len == 0:
    acc.add (s, pc)

  for tr in s.transitions:
    var fresh = pc
    # `atTerminal` stays false: completion collects live branches, never
    # complaints, so the suppression it gates is moot here -- see ADR 0037.
    if tr.matcher.match(fresh, atTerminal = false):
      if fresh.cursor.len < pc.cursor.len:
        var freshSeen: HashSet[State]
        collectFrontier(tr.next, fresh, acc, freshSeen)
      else:
        collectFrontier(tr.next, fresh, acc, seen)


proc completeArgs*(spec: Spec, words: seq[string], command: string): seq[CompletionCandidate] =
  ## Returns shell-completion candidates for `words` -- everything typed
  ## after the `__complete` marker (see `parse*`). The last element of
  ## `words` is the word currently being completed (possibly `""` if the
  ## cursor follows a space with nothing typed for this word yet); every
  ## earlier element is already complete. Never raises -- an unparseable
  ## prefix simply yields no candidates (`collectFrontier` just finds no
  ## live transitions for it), leaving the shell's own file-completion
  ## fallback to take over. See `docs/adr/0012-fsm-driven-shell-completion.md`
  ## and `docs/adr/0022-completion-candidate-help-text.md`.
  let wordBeingCompleted = if words.len > 0: words[^1] else: ""
  let priorWords = if words.len > 0: words[0 ..< words.high] else: newSeq[string]()

  # Case (b): last word is a bare option name awaiting its value --
  # short-circuit to that Arg's completions() (see architecture.md §6).
  if priorWords.len > 0:
    let committed = priorWords[0 ..< priorWords.high]
    var frontier: Frontier
    var seen: HashSet[State]
    var pc = ParseContext(cursor: initCursor(spec, committed), command: command)
    collectFrontier(spec.fsm, pc, frontier, seen)
    let pending = frontier.pendingOptionalArgs(priorWords[^1])
    if pending.len > 0:
      var seenValues: HashSet[string]
      for arg in pending:
        let candidates = collect:
          for c in arg.completions(): (c, "")
        result.addUnseen(seenValues, candidates, wordBeingCompleted)
      return result

  # Case (a): ordinary "what word can come next" completion.
  var frontier: Frontier
  var seen: HashSet[State]
  var pc = ParseContext(cursor: initCursor(spec, priorWords), command: command)
  collectFrontier(spec.fsm, pc, frontier, seen)
  result = frontier.candidateWords(wordBeingCompleted)

proc genCompletionScript*(spec: Spec, shell: Shell, binaryName: string): string =
  ## Returns a completion script for `shell` that, once installed per that
  ## shell's own convention, completes `binaryName` by shelling out to it
  ## (`<binaryName> __complete <words...>`). `spec` is accepted for
  ## call-site consistency with `dot`/`genHelp`, but the generated script
  ## doesn't need to inspect it -- completion (including each candidate's
  ## help text, rendered by fish and zsh but not bash -- see
  ## `docs/adr/0022-completion-candidate-help-text.md`) is resolved
  ## dynamically at request time by the compiled binary itself.
  let script =
    case shell
    of bash:
      fmt"""
      _{binaryName}_complete() {{
        # `__complete` prints "value<TAB>help" per line (see docs/adr/0022) --
        # bash's own COMPREPLY has no slot to render a description into, so
        # strip everything from the first tab onward before feeding compgen.
        local words
        words=$({binaryName} __complete "${{COMP_WORDS[@]:1}}" | cut -f1)
        COMPREPLY=($(compgen -W "$words" -- "${{COMP_WORDS[COMP_CWORD]}}"))
      }}
      complete -F _{binaryName}_complete {binaryName}
      """
    of zsh:
      fmt"""
      #compdef {binaryName}
      _{binaryName}_complete() {{
        # `$words` here is zsh's own current-command-line array (set by the
        # completion system), not a variable this function declares.
        #
        # `__complete` prints "value<TAB>help" per line (see docs/adr/0022) --
        # split each into parallel candidate/description arrays so zsh's own
        # completion menu can show the description next to each candidate.
        local -a lines candidates descriptions
        lines=("${{(@f)$({binaryName} __complete "${{words[@]:1}}")}}")
        local line
        for line in "${{lines[@]}}"; do
          candidates+=("${{line%%$'\t'*}}")
          descriptions+=("${{line#*$'\t'}}")
        done
        compadd -d descriptions -a candidates
      }}
      compdef _{binaryName}_complete {binaryName}
      """
    of fish:
      fmt"""
      function __{binaryName}_complete
        # `commandline -opc`, unlike bash's $COMP_WORDS or zsh's $words,
        # includes the invoked command name itself as its first element --
        # drop it the same way the bash/zsh branches above do via
        # `[@]:1`, or it leaks into every __complete call as a bogus
        # leading word.
        set -l tokens (commandline -opc)
        set -l cur (commandline -ct)
        # Unlike bash's $COMP_WORDBREAKS, fish never splits an =/:-joined
        # option+value into two words on its own (argumint accepts either
        # separator -- see OptionalVariantFormat), so a pending
        # "--opt=<TAB>"/"--opt:<TAB>" would otherwise arrive as one opaque,
        # unmatchable word. Split it by hand into the bare option name and
        # its (possibly empty) pending value.
        if string match -qr '^-[^=:]*[=:]' -- $cur
          set -l name (string replace -r '[=:].*' '' -- $cur)
          set -l prefix (string replace -r '^([^=:]*[=:]).*' '$1' -- $cur)
          set -l value (string replace -r '^[^=:]*[=:]' '' -- $cur)
          # fish's own -a candidate filter compares each returned line
          # literally against $cur (the whole "--opt=" token typed so
          # far), not just the value -- unlike bash/zsh, which isolate
          # the value automatically. Re-prepend the option+separator so
          # a bare value candidate like "debug" survives that filter as
          # "--opt=debug".
          #
          # `__complete` prints "value<TAB>help" per line (see docs/adr/0022)
          # -- split that off first so $prefix lands on the value half only,
          # then re-append the description (if any) after its own tab, so
          # fish still matches "$prefix<value>" against $cur while keeping
          # any description intact.
          for candidate in ({binaryName} __complete $tokens[2..-1] $name $value)
            set -l parts (string split -m1 \t -- $candidate)
            if test -n "$parts[2]"
              echo "$prefix$parts[1]"\t"$parts[2]"
            else
              echo "$prefix$parts[1]"
            end
          end
        else
          # `__complete` already prints "value<TAB>help" per line, which is
          # exactly fish's own native format for a candidate with a
          # description (see `complete`'s docs on multi-line command
          # substitution output) -- passed straight through, unchanged.
          {binaryName} __complete $tokens[2..-1] $cur
        end
      end
      complete -c {binaryName} -f -a '(__{binaryName}_complete)'
      """
  script.dedent
