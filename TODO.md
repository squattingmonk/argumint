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

Open questions
--------------

- Should a Validator also apply to a coded default value? Currently a
  default bypasses `parseImpl`/`validate` entirely -- it's substituted
  later at read time (`toT`/`toSeqT`), so an author's own default is never
  checked against their own Validator, unlike a command-line or env-var
  value. Not yet decided whether this asymmetry is desired.

Packaging / docs
-----------------

- No top-level README.md -- CLAUDE.md is agent-facing internal
  documentation, not a user-facing quickstart. Anyone finding this on
  GitHub or Nimble has nothing to start from.
