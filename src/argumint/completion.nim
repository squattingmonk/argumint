## Generates thin per-shell adapter scripts for dynamic completion. See
## `docs/adr/0012-fsm-driven-shell-completion.md` and
## `docs/adr/0022-completion-candidate-help-text.md`.
##
## Because completion is resolved dynamically (the compiled binary re-walks
## its own FSM via `resolveCompletion*` on every request), these scripts need to
## know almost nothing about `Spec`'s contents: they
## never enumerate commands/options themselves. Each one is purely
## mechanical -- register a completion function for `binaryName`, shell out
## to `<binaryName> __complete <words...>`, split stdout into one
## "value\thelp" line per candidate (`help` possibly empty, tab always
## present), and feed each candidate into that shell's own reply mechanism
## -- rendering the help text where the shell supports it (fish, zsh), or
## stripping it where it doesn't (bash).

import std/[sets, strformat, strutils, sugar, tables]

import ./[backend, matching, precedence, prose, tokens]

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

  Completion* = tuple[candidates: seq[CompletionCandidate], paths: PathCompletion]
    ## What `resolveCompletion` offers: the candidates, and which paths the
    ## shell adds to them.

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
  ## Pairs each of `arg`'s own `variants` with its description, read the way
  ## help reads it: the first paragraph of `arg.help.short`, then the
  ## variant's Flag Operation Description (`variantDesc`) in an `[action: ...]`
  ## bracket. With no short help, the description stands alone; long help
  ## never appears, being too long for a menu line. `variantDesc` is empty
  ## unless the flag's variants differ, so the same variant reads the same
  ## under every matcher. See
  ## `docs/adr/0063-flag-operation-description-in-completion.md`.
  let help = summary(arg.help.short)
  for v in variants:
    let opDesc = summary(arg.variantDesc(v))
    let desc =
      if opDesc.len == 0: help
      elif help.len == 0: opDesc
      else: help & " [action: " & opDesc & "]"
    result.add (v, desc)

proc addUnseen(result: var seq[CompletionCandidate], seen: var HashSet[string],
    candidates: openArray[CompletionCandidate], prefix: string) =
  ## Appends each of `candidates` whose `.value` starts with `prefix` and
  ## hasn't already been seen (via `seen`, keyed on `.value` alone) into
  ## `result`, preserving first-seen-wins order -- the dedup rule shared by
  ## `candidateWords` and `resolveCompletion*`'s own pending-value branch.
  for c in candidates:
    if c.value.startsWith(prefix) and c.value notin seen:
      seen.incl c.value
      result.add c

proc candidateWords(frontier: Frontier, prefix: string): seq[CompletionCandidate] =
  ## Reads every live frontier state's own outgoing transitions for literal
  ## next-word spellings (option/flag variants, command variants, or an
  ## enumerable positional's `completions()`), keeping only ones starting
  ## with `prefix` and deduplicating while preserving first-seen (== FSM
  ## priority/declaration) order. A `hidden` Arg is never offered -- see
  ## `docs/adr/0065-hidden-args-are-not-completed.md`.
  var seen: HashSet[string]
  for (state, pc) in frontier:
    for tr in state.transitions:
      let candidates =
        case tr.matcher.kind
        of mkOption:
          if tr.matcher.opt.hidden: newSeq[CompletionCandidate]()
          else: describeVariants(tr.matcher.opt, pc.cursor.spec.bareVariants(tr.matcher.opt, tr.matcher.variant))
        of mkOptions:
          collect:
            for opt in tr.matcher.opts:
              if not opt.hidden:
                for c in describeVariants(opt, pc.cursor.spec.bareVariants(opt)): c
        of mkCommand:
          if tr.matcher.cmd.hidden: newSeq[CompletionCandidate]()
          else: describeVariants(tr.matcher.cmd, tr.matcher.cmd.variants)
        of mkArgument:
          collect:
            if not tr.matcher.arg.hidden:
              for v in tr.matcher.arg.completions(): (v, "")
        of mkOptsEnd: newSeq[CompletionCandidate]() # invisible -- see ADR 0020 point 8
        of mkShortcut: newSeq[CompletionCandidate]()
      result.addUnseen(seen, candidates, prefix)

proc pendingOptionalArgs(frontier: Frontier, name: string): seq[Arg] =
  ## Every distinct `Optional`-kind (value-taking, not `Flag`) Arg reachable
  ## from a live frontier state whose variants include `name` exactly --
  ## used by `resolveCompletion` to detect "the last already-typed word is itself
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

proc frontierAfter(spec: Spec, words: seq[string], command: string): Frontier =
  ## Every live branch once `words` are consumed -- see `collectFrontier`.
  var seen: HashSet[State]
  let pc = ParseContext(cursor: initCursor(spec, words), command: command,
    tiers: initTiers(spec.settings))
  collectFrontier(spec.fsm, pc, result, seen)

iterator levelOptions(frontier: Frontier): (string, Arg) =
  ## Each bare option spelling, and its Arg, of every spec level `frontier`
  ## reached.
  var levels: seq[Spec]
  for (_, pc) in frontier:
    if pc.cursor.spec notin levels:
      levels.add pc.cursor.spec
  for level in levels:
    for variant, arg in level.options:
      yield (variant, arg)

proc accepts(spec: Spec, words: seq[string], command, variant: string, arg: Arg): bool =
  ## Whether parsing would accept `variant` after `words` -- see
  ## architecture.md §6, "Options after a positional".
  # Any value will do: the walk never converts or validates one.
  let probe = if arg.kind == Optional: variant & "=x" else: variant
  spec.frontierAfter(words & probe, command).len > 0

proc pathsFor(arg: Arg): PathCompletion =
  ## What `arg`'s value falls back to: its own `complete`, unless it has
  ## enumerable values, which a `choice` accepts alone.
  if arg.completions().len > 0: PathCompletion.None else: arg.complete

proc widen(paths: var PathCompletion, other: PathCompletion) =
  ## `Files` beats `Dirs`, which beats `None` -- declared in that order.
  paths = min(paths, other)

proc resolveCompletion*(spec: Spec, words: seq[string], command: string): Completion =
  ## Returns shell-completion candidates for `words` -- everything typed
  ## after the `__complete` marker (see `parse*`) -- and which paths the
  ## shell should add to them. The last element of `words` is the word
  ## currently being completed (possibly `""` if the cursor follows a space
  ## with nothing typed for this word yet); every earlier element is
  ## already complete. Never raises -- an unparseable prefix simply yields
  ## no candidates and no paths (`collectFrontier` just finds no live
  ## transitions for it). See `docs/adr/0012-fsm-driven-shell-completion.md`,
  ## `docs/adr/0022-completion-candidate-help-text.md`, and
  ## `docs/adr/0066-completion-falls-back-to-paths.md`.
  result.paths = PathCompletion.None
  let wordBeingCompleted = if words.len > 0: words[^1] else: ""
  let priorWords = if words.len > 0: words[0 ..< words.high] else: newSeq[string]()

  # Case (b): last word is a bare option name awaiting its value --
  # short-circuit to that Arg's completions() (see architecture.md §6).
  if priorWords.len > 0:
    let committed = priorWords[0 ..< priorWords.high]
    let name = priorWords[^1]
    let frontier = spec.frontierAfter(committed, command)
    var pending = frontier.pendingOptionalArgs(name)
    if pending.len == 0:
      for (variant, arg) in frontier.levelOptions:
        if variant == name and arg.kind == Optional and
            spec.accepts(committed, command, variant, arg):
          pending.add arg
    if pending.len > 0:
      var seenValues: HashSet[string]
      for arg in pending:
        let candidates = collect:
          for c in arg.completions(): (c, "")
        result.candidates.addUnseen(seenValues, candidates, wordBeingCompleted)
        result.paths.widen arg.pathsFor
      return result

  # Case (a): ordinary "what word can come next" completion, plus any
  # option accepted after a positional (see `accepts`).
  let frontier = spec.frontierAfter(priorWords, command)
  result.candidates = frontier.candidateWords(wordBeingCompleted)
  var seen: HashSet[string]
  for c in result.candidates:
    seen.incl c.value
  for (variant, arg) in frontier.levelOptions:
    # The prefix and `seen` checks only spare `accepts` a walk.
    if not arg.hidden and variant.startsWith(wordBeingCompleted) and
        variant notin seen and spec.accepts(priorWords, command, variant, arg):
      result.candidates.addUnseen(seen, describeVariants(arg, @[variant]), wordBeingCompleted)
  for (state, _) in frontier:
    for tr in state.transitions:
      if tr.matcher.kind == mkArgument and not tr.matcher.arg.hidden:
        result.paths.widen tr.matcher.arg.pathsFor

proc directive*(paths: PathCompletion): string =
  ## The line ending `__complete`'s output, telling the shell script which
  ## paths to add -- see `docs/adr/0066-completion-falls-back-to-paths.md`.
  case paths
  of PathCompletion.Files: ":files"
  of PathCompletion.Dirs: ":dirs"
  of PathCompletion.None: ":"

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
        # Words before the cursor, minus `=`/`:` -- see architecture.md §6.
        local cur="${{COMP_WORDS[COMP_CWORD]}}"
        local -a args=()
        local i w
        for ((i = 1; i < COMP_CWORD; i++)); do
          w="${{COMP_WORDS[i]}}"
          if [[ ($w == "=" || $w == ":") && ${{COMP_WORDS[i-1]}} == -* ]]; then
            continue
          fi
          args+=("$w")
        done
        # A bare separator: complete the value from scratch.
        if [[ ($cur == "=" || $cur == ":") && ${{COMP_WORDS[COMP_CWORD-1]}} == -* ]]; then
          cur=""
        fi
        # `__complete` prints "value<TAB>help" per line, then a directive
        # line (see docs/adr/0022 and 0066). bash has no slot for help, so
        # cut it off; `-o filenames` escapes paths and marks directories.
        # No `mapfile`/`compopt` in bash 3.2 (macOS's /bin/bash).
        local out paths="" line
        out=$({binaryName} __complete "${{args[@]}}" "$cur")
        case ${{out##*$'\n'}} in
          :files) paths=-f ;;
          :dirs)  paths=-d ;;
        esac
        COMPREPLY=()
        while IFS= read -r line; do COMPREPLY+=("$line"); done < <(
          compgen -W "$(printf '%s\n' "$out" | sed '$d' | cut -f1)" -- "$cur"
          if [[ -n $paths ]]; then compgen $paths -- "$cur"; fi
        )
        if [[ -n $paths ]]; then compopt -o filenames 2>/dev/null; fi
      }}
      complete -F _{binaryName}_complete {binaryName}
      """
    of zsh:
      fmt"""
      #compdef {binaryName}
      _{binaryName}_complete() {{
        # `$words`/`$CURRENT`/`$PREFIX` are zsh's own -- see architecture.md §6.
        local -a args=("${{(@)words[2,CURRENT-1]}}")
        local cur="$PREFIX"
        # Split `--opt=value`, as the fish script does.
        if [[ $cur == -*[=:]* ]]; then
          args+=("${{cur%%[=:]*}}")
          compset -P 1 '*[=:]'
          cur="$PREFIX"
        fi
        # `__complete` prints "value<TAB>help" per line, then a directive
        # line (see docs/adr/0022 and 0066); the display string replaces the
        # word.
        local -a lines candidates descriptions
        lines=("${{(@f)$({binaryName} __complete "${{args[@]}}" "$cur")}}")
        local directive=${{lines[-1]}}
        lines=("${{(@)lines[1,-2]}}")
        local line word help
        for line in "${{lines[@]}}"; do
          word="${{line%%$'\t'*}}"
          help="${{line#*$'\t'}}"
          candidates+=("$word")
          descriptions+=("$word${{help:+  -- $help}}")
        done
        (( ${{#candidates}} )) && compadd -d descriptions -a candidates
        case $directive in
          :files) _files ;;
          :dirs) _files -/ ;;
        esac
      }}
      compdef _{binaryName}_complete {binaryName}
      """
    of fish:
      fmt"""
      function __{binaryName}_complete
        # `commandline -opc` includes the invoked command name itself as its
        # first element -- drop it, as the bash/zsh branches above skip their
        # first word, or it leaks into every __complete call as a bogus
        # leading word.
        set -l tokens (commandline -opc)
        set -l cur (commandline -ct)
        # Unlike bash's $COMP_WORDBREAKS, fish never splits an =/:-joined
        # option+value into two words on its own (argumint accepts either
        # separator -- see OptionalVariantFormat), so a pending
        # "--opt=<TAB>"/"--opt:<TAB>" would otherwise arrive as one opaque,
        # unmatchable word. Split it by hand into the bare option name and
        # its (possibly empty) pending value.
        set -l words $tokens[2..-1]
        set -l prefix ""
        set -l value $cur
        if string match -qr '^-[^=:]*[=:]' -- $cur
          set -a words (string replace -r '[=:].*' '' -- $cur)
          set prefix (string replace -r '^([^=:]*[=:]).*' '$1' -- $cur)
          set value (string replace -r '^[^=:]*[=:]' '' -- $cur)
        end
        # fish's own -a candidate filter compares each returned line
        # literally against $cur (the whole "--opt=" token typed so far), not
        # just the value -- unlike bash/zsh, which isolate the value
        # automatically. Re-prepend the option+separator (an empty $prefix
        # otherwise) so a bare value candidate like "debug" survives that
        # filter as "--opt=debug".
        #
        # `__complete` prints "value<TAB>help" per line (see docs/adr/0022),
        # fish's own format for a candidate with a description, then a
        # directive line (docs/adr/0066) -- split the help off first so
        # $prefix lands on the value half only, then re-append it.
        set -l out ({binaryName} __complete $words "$value")
        set -l directive $out[-1]
        set -e out[-1]
        for candidate in $out
          set -l parts (string split -m1 \t -- $candidate)
          if test -n "$parts[2]"
            printf '%s\t%s\n' "$prefix$parts[1]" "$parts[2]"
          else
            printf '%s\n' "$prefix$parts[1]"
          end
        end
        switch $directive
          case :files
            for p in (__fish_complete_path "$value")
              printf '%s\n' "$prefix$p"
            end
          case :dirs
            for p in (__fish_complete_directories "$value")
              printf '%s\n' "$prefix$p"
            end
        end
      end
      complete -c {binaryName} -f -a '(__{binaryName}_complete)'
      """
  script.dedent
