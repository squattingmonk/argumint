# Required options skip Value Precedence's env/default fallback

Value Precedence lets an Option/Flag's value come from an explicit
command-line value, then a configured environment variable, then a coded
default. For a *required* (unbracketed) Option, though, none of that ever
runs: FSM matching fails with "missing option" the moment the Option is
absent from the command line, before `Spec.parse`'s env-fallback sweep or
the coded default is ever consulted — even if the environment variable is
set. This was chosen deliberately: letting an environment variable
silently satisfy a required Option would mean `--help`'s Usage: line could
show something as mandatory that secretly isn't, depending on the runtime
environment. The bracket in the Usage String stays the single source of
truth for whether an Option is actually required.

This is currently viewed as a wart rather than a settled trade-off — see
the TODO item to let a required Option/Flag be satisfied by its env var
being set instead.
