# 1.x freezes the public modules and the usage grammar

> **Refined by [ADR 0090](0090-a-pin-backs-every-supported-name.md)**:
> a public module's name is supported only if a Pin backs it, and a
> `!` name in the Public Surface may change in a minor release.

argumint 1.0 follows Semantic Versioning, which needs a line drawn around
its public interface. Nim can't hide a submodule from a program that
imports it by path, so the line has to be stated rather than enforced. The
README's Stability section lists what it covers; this records why.

## Decision

1. **Only the modules meant to be imported are public.** That is
   `argumint` and the opt-in modules a user needs to extend or render it:
   `argumint/customarg` for a Custom Arg, `argumint/configsource` for a
   Config Source, its `ini` and `json` backends, and `argumint/help` to
   render help directly. Every other module may change or move in any
   release, without warning. This extends ADR 0043's facade/machinery
   split, which ADR 0076 already applied to `argumint/customarg`.
2. **Extension points are frozen.** Changing the signature of a method a
   Custom Arg or Config Source overrides, or the `HelpFormatter` type and
   the `HelpContext` it receives, is a major release. Adding a method with
   a default isn't.
3. **The usage-string grammar is frozen.** A usage string accepts and
   rejects the same command lines across 1.x, except where a release fixes
   a bug.
4. **Raising the minimum Nim version is a major release.** 1.x stays on
   Nim 2.2.4.
5. **Help and error text, styling and completion-script contents aren't
   frozen.** They can change in a minor release.

## Considered options

- **Raising the minimum Nim version in a minor release.** It would let #77
  drop the local `wrapWords` fork as soon as a stable Nim has the upstream
  fix, but a user pinned to an older Nim would be broken by a minor
  upgrade. The fork stays until 2.0.
- **Freezing help and error text.** It would protect users who
  snapshot-test their `--help` output, but every wording or layout fix
  would then need a major release.

## Consequences

- #77 waits for 2.0.
- A test that compares help output byte for byte may need updating after a
  minor upgrade.
