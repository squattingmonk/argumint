argumint - possible future work
================================

Parsing / UX
------------

- Shell completion generation (bash/zsh/fish) from a Spec.
- Reading args from a file (@file / --flagfile-style), for very long
  argument lists.
- Let a required Option/Flag be satisfied by its env var being set, rather
  than always failing FSM matching first. Currently a required option's
  Value Precedence env/default tiers are dead code -- see
  `docs/adr/0001-required-options-skip-value-precedence-fallback.md` for
  why it works this way today.
- Make an Options Catch-all (`[options]`) grant repetition to any
  Option/Flag reachable only through it unconditionally, rather than only
  when `[options]` itself carries a trailing `...` (`fsm.nim:239`). See
  `docs/adr/0002-catch-all-options-repeatable-by-default.md`.
- Support Option Operations for multi-value Options (e.g. `--option^=value`
  to prepend, mirroring Flag Operation's `=`/`+=`/`-=`), instead of always
  appending on repeated matches. `OptionValueFormat` (`fsm.nim:43-56`)
  already tokenizes the prepend/append/remove/reset op prefix into
  `CmdLineToken.optSep`; nothing downstream consumes it yet.
- Support composable Validators: a fourth Validator kind (e.g. `all()`)
  that ANDs several Validators together, so an Arg can require e.g. both a
  Range and a Check to pass, instead of only ever accepting one Validator
  per Arg. AND-only for now, no OR.

Open questions
--------------

- Should a Validator also apply to a coded default value? Currently a
  default bypasses `parseImpl`/`validate` entirely -- it's substituted
  later at read time (`toT`/`toSeqT`), so an author's own default is never
  checked against their own Validator, unlike a command-line or env-var
  value. Not yet decided whether this asymmetry is desired.

Bugs
----

- `collectExplicitOptions` (`parser.nim`) scans every Usage Line in the
  whole Usage String for explicitly-mentioned options, not just the
  current Usage Line. This means an Options Catch-all (`[options]`) on one
  Usage Line can silently exclude an option that's only explicitly named
  on a *different* Usage Line -- it should scope to the current Usage Line
  only.

Packaging / docs
-----------------

- No top-level README.md -- CLAUDE.md is agent-facing internal
  documentation, not a user-facing quickstart. Anyone finding this on
  GitHub or Nimble has nothing to start from.
- argumint.nimble declares license = "MIT" but there's no LICENSE file in
  the repo.
