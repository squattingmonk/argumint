## Generates thin per-shell adapter scripts for dynamic completion. See
## `docs/adr/0012-fsm-driven-shell-completion.md` and
## `docs/adr/0022-completion-candidate-help-text.md`.
##
## Because completion is resolved dynamically (the compiled binary re-walks
## its own FSM via `fsm.completeArgs*` on every request -- see `fsm.nim`),
## these scripts need to know almost nothing about `Spec`'s contents: they
## never enumerate commands/options themselves. Each one is purely
## mechanical -- register a completion function for `binaryName`, shell out
## to `<binaryName> __complete <words...>`, split stdout into one
## "value\thelp" line per candidate (`help` possibly empty, tab always
## present), and feed each candidate into that shell's own reply mechanism
## -- rendering the help text where the shell supports it (fish, zsh), or
## stripping it where it doesn't (bash).

import std/[strformat, strutils]

import ./backend

type
  Shell* {.pure.} = enum
    bash, zsh, fish

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
