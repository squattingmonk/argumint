## Generates thin per-shell adapter scripts for dynamic completion. See
## `docs/adr/0012-fsm-driven-shell-completion.md`.
##
## Because completion is resolved dynamically (the compiled binary re-walks
## its own FSM via `fsm.completeArgs*` on every request -- see `fsm.nim`),
## these scripts need to know almost nothing about `Spec`'s contents: they
## never enumerate commands/options themselves. Each one is purely
## mechanical -- register a completion function for `binaryName`, shell out
## to `<binaryName> __complete <words...>`, split stdout on newlines, and
## feed the result into that shell's own reply mechanism.

import std/[strformat, strutils]

import ./backend

type
  Shell* {.pure.} = enum
    bash, zsh, fish

proc genCompletionScript*(spec: Spec, shell: Shell, binaryName: string): string =
  ## Returns a completion script for `shell` that, once installed per that
  ## shell's own convention, completes `binaryName` by shelling out to it
  ## (`<binaryName> __complete <words...>`). `spec` is accepted for
  ## call-site consistency with `dot`/`genHelp` and to leave room for a
  ## future richer per-shell rendering (e.g. zsh `_describe` groups with
  ## descriptions) -- v1's output doesn't need to inspect it.
  let script =
    case shell
    of bash:
      fmt"""
      _{binaryName}_complete() {{
        local words
        words=$({binaryName} __complete "${{COMP_WORDS[@]:1}}")
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
        local -a candidates
        candidates=("${{(@f)$({binaryName} __complete "${{words[@]:1}}")}}")
        compadd -a candidates
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
          for candidate in ({binaryName} __complete $tokens[2..-1] $name $value)
            echo "$prefix$candidate"
          end
        else
          {binaryName} __complete $tokens[2..-1] $cur
        end
      end
      complete -c {binaryName} -f -a '(__{binaryName}_complete)'
      """
  script.dedent
