argumint - possible future work
================================

Parsing / UX
------------

- Shell completion generation (bash/zsh/fish) from a Spec.
- Reading args from a file (@file / --flagfile-style), for very long
  argument lists.
- Support Option Operations for multi-value Options (e.g. `--option^=value`
  to prepend, mirroring Flag Operation's `=`/`+=`/`-=`), instead of always
  appending on repeated matches. `OptionValueFormat` (`fsm.nim:43-56`)
  already tokenizes the prepend/append/remove/reset op prefix into
  `CmdLineToken.optSep`; nothing downstream consumes it yet.

Packaging / docs
-----------------

- No top-level README.md -- CLAUDE.md is agent-facing internal
  documentation, not a user-facing quickstart. Anyone finding this on
  GitHub or Nimble has nothing to start from.
