# Changelog

## [1.0.0](https://github.com/squattingmonk/argumint/compare/v0.1.0...v1.0.0) (2026-09-26)


### ⚠ BREAKING CHANGES

* a usage string with a whitespace-only line no longer accepts a bare call because of it, and help and parse errors no longer show a bare command line for a blank line.
* `Row.text` and `HelpContext.prose` are `Prose`; lay them out with `wrap` before rendering. `wrapProse` is removed.
* Column Style help whose text wraps shifts 2 columns left on paragraph continuation lines.
* HelpError.msg no longer carries escape codes (read styledMsg for the styled form), and styledMsg is no longer empty when the Spec has no Styler. A Help Formatter may be called twice per --help.
* autoStyler is a marker, not a call: write style = autoStyler. SpecSettings can no longer be built with an object constructor, and calling the styler through the settings needs
* a custom `HelpFormatter` takes a `HelpContext` instead of `(spec, command)`, and builds its message from the context's procs (`ctx.groups`, `ctx.rows(arg)`, `ctx.prose(ctx.spec.prolog)`, `ctx.usage`, `ctx.render(...)`); `rows`, `proseLines`, `annotations`, `variantsByDesc`, `helpGroups`, and `help`'s `markup` are no longer exported. Call a built-in directly as `spec.genHelp(command, formatColumn)`.
* a custom Arg's `validatorHelp` override drops its `keepTicks` parameter. `StyleRole` gains `srTick`, so a `Theme` written as a full array literal needs an entry for it (one copied from `defaultTheme` doesn't), and `markup` no longer takes `keepTicks`: call `withoutTicks` on its result instead.
* `StyleRole` gains `srInvalid`, so a `Theme` written as a complete array literal must add an entry for it.
* multi-line help text is re-flowed, and single-line help starting with a list marker (`- `, `1. `) now wraps as a list item. `Row.text`'s newlines mark block boundaries; custom formatters should lay it out with `wrapProse` rather than `wrap`.
* a multi-line prolog or epilog is re-flowed. Consecutive unindented lines now join into one paragraph; to keep a line break, leave a blank line or indent the line.
* help output changes for every spec with groups. A test pinning help text needs the colons, and a `group` name that already ended in `:` now renders with two.
* `Arg.validatorHelp` now takes `keepTicks` and returns `StyledText` instead of `string`, so a custom Arg overriding it must change its signature. `rows`/`annotations` gain a `keepTicks` parameter.
* Row's fields are StyledText, annotations() returns seq[StyledText], and formatUsage() is replaced by usageLines(), which returns seq[StyledText]; render it with `.render`.
* `envName*` and `envDelim*` are removed from the custom-`Arg` contract, replaced by a single `envSource*` returning `Option[EnvSource]`. A subtype opting into the environment-variable tier overrides that one method, so a delimiter override can no longer exist without a variable to apply it to. `envName` remains readable as a proc derived from `envSource`, but is no longer overridable. Nothing registered through `defineArg`/`defineFlag`/`defineSetFlag` is affected.
* `Arg.parse`'s `(command, spec, variant)` overload is now `action`, and is the only one -- the narrower `(variant)` form is gone. `MessageArg` and `HelpArg` both override it, a plain `MessageArg` ignoring `command`/`spec`, so the per-level message pass dispatches once with no type test. A Message Argument taking over the leaf's action mirrors `Spec.action` (ADR 0013).
* the three supplied Value Precedence tiers now run strongest-first (walk -> parseAllValues -> applyFallbacks -> dispatch), which is Value Precedence read top-down. A bad command-line value now raises before a bad environment-variable or Config Source value, where the lower tiers used to be converted first and reported first. Only observable when an invocation supplies invalid values on two tiers at once; which of the two failures surfaces changes, not whether the parse fails.
* an option-shaped token unrecognized by the spec raises ParseError instead of being absorbed as a positional value or as an option's value. Set `strictOptions = false` to restore the previous behavior in both slots. A declared option starved of its value is an error under either setting. Exactly one pre-existing test changed meaning: ADR 0019 gap 3's own regression test, kept as coverage under `strictOptions = false` alongside a strict-mode counterpart.
* a value that fails to convert or validate now raises before any `before`/`action`/`after` hook runs, where a hook at a shallower level than the failing value previously fired first. As a consequence `after` no longer runs for such an invocation either, since no `before` completed and nothing was entered to clean up. A matched Message Argument no longer wins against a failing value below it, so a usage line like `[-h] go` invoked as `-h go --port abc` raises instead of printing help; the single-level equivalent already behaved this way.
* `Spec`'s `prolog`, `epilog`, `usage`, `args`, `commands`, `arguments`, `options`, `groups`, and `fsm` fields are no longer exported. Reaching them previously required `import argumint/backend`, since `Spec` itself could not be named -- ordinary spec authors are unaffected, and `spec.settings` and the three hook fields are unchanged.
* `ConfigKey` is now a `distinct seq[string]`. Custom `ConfigSource` implementors whose `lookup` override treated the key as a plain `seq[string]` beyond `len`/`[]`/iteration now need `key.segments`. Both built-in adapters needed no changes. Ordinary spec authors are unaffected -- no `opt`/`opts`/`flag` call site changes.
* replace flag's embedded <op><value> syntax with explicit flagOp declarations ([#14](https://github.com/squattingmonk/argumint/issues/14))
* `clamp`/`adjust`'s `desc` param is now `Option[string]`
* reorder message/version params, drop version's default variants
* arg/opt fall back to default(T), matching args/opts (ADR 0023)
* pass HookInfo to before/action/after hooks (ADR 0021)
* parse* no longer quits on error; use parseOrQuit* for that. parseSpec* is gone -- use Spec.parse instead.
* subsume multi-value arg*/opt* into args*/opts*

### Features

* add `put`, the typed write accessor, and read stored values over `seen` ([#29](https://github.com/squattingmonk/argumint/issues/29)) ([#57](https://github.com/squattingmonk/argumint/issues/57)) ([a064586](https://github.com/squattingmonk/argumint/commit/a0645863cceac09b17f270a07cf7c8dba587a45f))
* add `replace`, an atomic typed one-call replace for a multi-valued Arg ([#56](https://github.com/squattingmonk/argumint/issues/56)) ([#58](https://github.com/squattingmonk/argumint/issues/58)) ([d53cf85](https://github.com/squattingmonk/argumint/commit/d53cf850da56cdc0d527ffe856e533f0653513f6))
* add a dot-graph-to-PNG script and example ([33fc75c](https://github.com/squattingmonk/argumint/commit/33fc75c5071b8ad6c62fd6c33d8118c91b32a605))
* add composable all()/any() Validators (ADR 0006) ([42f4e67](https://github.com/squattingmonk/argumint/commit/42f4e6768086a80c1cc87020148ad84e80be40cd))
* add Config Source, a third Value Precedence tier ([576a606](https://github.com/squattingmonk/argumint/commit/576a6064e255d25833136ff1dbe71d37213652d2))
* add dynamic shell completion via a `__complete` FSM re-walk (ADR 0012) ([4c6c3c3](https://github.com/squattingmonk/argumint/commit/4c6c3c351e06c7d6eec74b809211575812cec57f))
* add Flag Clamp for silently constraining Flag values ([317295f](https://github.com/squattingmonk/argumint/commit/317295f4ff1d00ecdd428c5c215f22a9caa16cc6))
* add get/get(otherwise) accessors for reading parsed values ([#16](https://github.com/squattingmonk/argumint/issues/16)) ([#46](https://github.com/squattingmonk/argumint/issues/46)) ([d13bc2d](https://github.com/squattingmonk/argumint/commit/d13bc2d4a12ee87fc94df3beebad5c30b806c110))
* add history-aware Validators via checkSeen()/checkSeenIt()/unique() (ADR 0007) ([d2c59f3](https://github.com/squattingmonk/argumint/commit/d2c59f3ab991c949adef518bb0c995b3cf0c5151))
* add parsed/parsedOrQuit for a fresh spec per parse ([#21](https://github.com/squattingmonk/argumint/issues/21)) ([#26](https://github.com/squattingmonk/argumint/issues/26)) ([6cd815d](https://github.com/squattingmonk/argumint/commit/6cd815d8f030291b239c0436e98f3428f1a7574c))
* add per-arg env delimiter overrides via EnvSource ([dfe24d3](https://github.com/squattingmonk/argumint/commit/dfe24d351f5cbc681b4f4c91962674a4345f39e5))
* add Strict Option Checking so an option-shaped token is never data ([#36](https://github.com/squattingmonk/argumint/issues/36)) ([4af7886](https://github.com/squattingmonk/argumint/commit/4af78860dde799f952e0d2cb0bb7b60ac26d44b8))
* add typo suggestion for long options ([da0c91f](https://github.com/squattingmonk/argumint/commit/da0c91fb521ab88efabe2dfb06b40aa1f9779ca9))
* add usage-string End-of-Options Marker (--) ([a32aa91](https://github.com/squattingmonk/argumint/commit/a32aa913f5d7f6425eb7926322ab967ad2d97e3d))
* allow suppressing FlagClamp's help annotation (issue [#12](https://github.com/squattingmonk/argumint/issues/12)) ([#13](https://github.com/squattingmonk/argumint/issues/13)) ([02378bb](https://github.com/squattingmonk/argumint/commit/02378bb3c241508320e3c61d356e0cadcb0daff8))
* arg/opt fall back to default(T), matching args/opts (ADR 0023) ([a6400c8](https://github.com/squattingmonk/argumint/commit/a6400c87e8589e0d036eb2864850a3df0386405f))
* auto-detect terminal width for usage/help wrapping ([dfc7ea9](https://github.com/squattingmonk/argumint/commit/dfc7ea912a69bf666477b16e547860c85b319316))
* auto-generate per-variant descriptions for flags with divergent ops ([42b2ea4](https://github.com/squattingmonk/argumint/commit/42b2ea4dfacebca803b0df0eb3a8e4c78b138ec5))
* cap and wrap the help text's variants column ([8e7509e](https://github.com/squattingmonk/argumint/commit/8e7509e54e00b71977ac7a891f8d8f9b2a947eb7))
* cap the detected help width at 100 columns ([#105](https://github.com/squattingmonk/argumint/issues/105)) ([dcb8589](https://github.com/squattingmonk/argumint/commit/dcb85892ebaa114c7e519eabbb5685454fa50ee0)), closes [#100](https://github.com/squattingmonk/argumint/issues/100)
* end every help heading with a colon ([#104](https://github.com/squattingmonk/argumint/issues/104)) ([1d0ada0](https://github.com/squattingmonk/argumint/commit/1d0ada05cbf24f3a1aa1972bbe893675e738530c)), closes [#103](https://github.com/squattingmonk/argumint/issues/103)
* enforce Flag Operation exclusivity across usage-string alternation (issue [#8](https://github.com/squattingmonk/argumint/issues/8)) ([#10](https://github.com/squattingmonk/argumint/issues/10)) ([f15aea4](https://github.com/squattingmonk/argumint/commit/f15aea4a072888626a1cf325ae05223352acd749))
* export the core types so `import argumint` alone is enough ([#17](https://github.com/squattingmonk/argumint/issues/17)) ([#24](https://github.com/squattingmonk/argumint/issues/24)) ([25ce259](https://github.com/squattingmonk/argumint/commit/25ce25978f751c6c651d2e6a4f7fcde71e94ce35))
* export ValueArg and FlagArg so args can cross a proc boundary ([#35](https://github.com/squattingmonk/argumint/issues/35)) ([4d2c96f](https://github.com/squattingmonk/argumint/commit/4d2c96f40b60d78474215f4b0d2d598f50d29c6b))
* expose `genHelp` via `argumint/help`, splitting help rendering out of `argumint.nim` ([#50](https://github.com/squattingmonk/argumint/issues/50)) ([#52](https://github.com/squattingmonk/argumint/issues/52)) ([8b162d7](https://github.com/squattingmonk/argumint/commit/8b162d70bf5de0bc0021cbe17ab7c37e1c763f77))
* generate HTML API docs with nim doc and publish to GitHub Pages ([d828a6b](https://github.com/squattingmonk/argumint/commit/d828a6bccc9f2a44505ddd14cc09100bbbd83704))
* give arg/opt/args/opts/flag default(T) fallback and a bare-call shorthand together (ADR 0024) ([f9b07d6](https://github.com/squattingmonk/argumint/commit/f9b07d645f7189ef22c322121c77a7fcca260d2c))
* let -d: defines set newSpecSettings's defaults ([#107](https://github.com/squattingmonk/argumint/issues/107)) ([a5237cd](https://github.com/squattingmonk/argumint/commit/a5237cdc4ebcf863d19577121ba975e507ca30c0)), closes [#106](https://github.com/squattingmonk/argumint/issues/106)
* let a required Option/Flag's env var satisfy the requirement ([b3d4313](https://github.com/squattingmonk/argumint/commit/b3d43139227fc49fa11e4ac1458327242718b95b))
* let a Usage Line start with {cmd}, allowing Bare Calls ([#142](https://github.com/squattingmonk/argumint/issues/142)) ([b0256e7](https://github.com/squattingmonk/argumint/commit/b0256e7c04890319f512c80a50d1ccfa82beb567)), closes [#139](https://github.com/squattingmonk/argumint/issues/139)
* let an env var supply multiple values to Options and Flags ([815862a](https://github.com/squattingmonk/argumint/commit/815862a05699017da444d78df887ff830951f7d8))
* make `parse` the public write surface, carrying its own provenance ([#47](https://github.com/squattingmonk/argumint/issues/47)) ([#48](https://github.com/squattingmonk/argumint/issues/48)) ([2b0ea6a](https://github.com/squattingmonk/argumint/commit/2b0ea6ad6efb845baaa8bd6aba25bf05cc835889))
* name the offending token when a parse fails ([#20](https://github.com/squattingmonk/argumint/issues/20)) ([#39](https://github.com/squattingmonk/argumint/issues/39)) ([cef9140](https://github.com/squattingmonk/argumint/commit/cef914037950b6b5a3e4e3425f8877a2a3bbb7a3))
* name the offending token when a parse fails ([#20](https://github.com/squattingmonk/argumint/issues/20)) ([#39](https://github.com/squattingmonk/argumint/issues/39)) ([9040c9c](https://github.com/squattingmonk/argumint/commit/9040c9cc815db673c8aab56796e01b36e3f7ffcb))
* parse every matched level's values before any hook fires ([#30](https://github.com/squattingmonk/argumint/issues/30)) ([#32](https://github.com/squattingmonk/argumint/issues/32)) ([e084f18](https://github.com/squattingmonk/argumint/commit/e084f185e2d9bcfe29585d18c13c2011eaadf895))
* pass HookInfo to before/action/after hooks (ADR 0021) ([79d8fc2](https://github.com/squattingmonk/argumint/commit/79d8fc2b0101bcddfa80ece59cfb702fb689ff6d))
* pluggable help formatters with Column and Paragraph styles ([#85](https://github.com/squattingmonk/argumint/issues/85)) ([ab5e387](https://github.com/squattingmonk/argumint/commit/ab5e387a73bb2102be1e45d395ca26d181853ccd))
* reorder message/version params, drop version's default variants ([ebbfce4](https://github.com/squattingmonk/argumint/commit/ebbfce4464b80ede9aee55986a614e6d999ee0e9))
* replace CommandArg.handler with before/action/after hooks on Spec (ADR 0009) ([e8d1aa9](https://github.com/squattingmonk/argumint/commit/e8d1aa98956c8a139e3bede0bf0b952fd15a07fa))
* replace eager tokenizeArgs with lazy, walk-time token classification ([#5](https://github.com/squattingmonk/argumint/issues/5)) ([43fb463](https://github.com/squattingmonk/argumint/commit/43fb4633a3cf21db490101c41d5d01a345862daf))
* replace eager tokenizeArgs with lazy, walk-time token classification ([#5](https://github.com/squattingmonk/argumint/issues/5)) ([43fb463](https://github.com/squattingmonk/argumint/commit/43fb4633a3cf21db490101c41d5d01a345862daf))
* replace flag's embedded &lt;op&gt;&lt;value&gt; syntax with explicit flagOp declarations ([#14](https://github.com/squattingmonk/argumint/issues/14)) ([2ca974d](https://github.com/squattingmonk/argumint/commit/2ca974d79e9a92084c5b171de506ea1a58934802))
* report which Value Precedence tier supplied each Arg ([#22](https://github.com/squattingmonk/argumint/issues/22)) ([#45](https://github.com/squattingmonk/argumint/issues/45)) ([73db69c](https://github.com/squattingmonk/argumint/commit/73db69cbed0fc5ee8e1f0c6f6e93949fd09b5bf7))
* share width/maxVariantsWidth/envDelim via a mutable SpecConfig ref ([1094522](https://github.com/squattingmonk/argumint/commit/1094522c4bf97acc8257ebb937ad323efac186b9))
* show help text on shell completion candidates (fish, zsh) ([4797ef8](https://github.com/squattingmonk/argumint/commit/4797ef832e471f521c8742067474b40fb979fd91))
* style help and error output by role ([#99](https://github.com/squattingmonk/argumint/issues/99)) ([8bf3c6e](https://github.com/squattingmonk/argumint/commit/8bf3c6e2a7da146bc7ab8bd9ef2ab1138e948bce))
* style parse-error complaints by role, with srInvalid for bad input ([#115](https://github.com/squattingmonk/argumint/issues/115)) ([aab6062](https://github.com/squattingmonk/argumint/commit/aab6062ff5bdb8c88c4aa3001d662453e40f94db)), closes [#101](https://github.com/squattingmonk/argumint/issues/101)
* support environment variables for opt/flag values ([0d7939c](https://github.com/squattingmonk/argumint/commit/0d7939c78d45e543d57f38af21220a1950392a1a))
* support hiding args from help messages ([5e709a9](https://github.com/squattingmonk/argumint/commit/5e709a9237532612978990821c726cdfac3745c1))
* support set[enum] flags, with typed variant values ([dd4372a](https://github.com/squattingmonk/argumint/commit/dd4372ab1499220726f49f695d5df07d2bbcb37b))


### Bug Fixes

* a spec with zero declared args can now parse successfully ([6927d13](https://github.com/squattingmonk/argumint/commit/6927d1323732a6a81ec9447f15969947622169ad))
* align Column Style's paragraph continuations at the text column ([#134](https://github.com/squattingmonk/argumint/issues/134)) ([d071bed](https://github.com/squattingmonk/argumint/commit/d071bed7885350ff541dd48510940be0ea168b81)), closes [#132](https://github.com/squattingmonk/argumint/issues/132)
* apply env-var fallback to every entered spec level, not just the deepest ([a692fae](https://github.com/squattingmonk/argumint/commit/a692faea03d9d4b5190fc89b9c99dcbafdef7c3d))
* clear help.nim's compile warnings ([#111](https://github.com/squattingmonk/argumint/issues/111)) ([6473262](https://github.com/squattingmonk/argumint/commit/6473262253665b2b577e1bed2920e6373358dc68))
* de-noise parse-error messages ([8c536a2](https://github.com/squattingmonk/argumint/commit/8c536a29c293e589897e9a49c748fb8fb05193b1))
* detect terminal width and colour on first read of SpecSettings ([#125](https://github.com/squattingmonk/argumint/issues/125)) ([c293fae](https://github.com/squattingmonk/argumint/commit/c293fae470f3329cf1e8db618c9e4eb4df8fe0cd)), closes [#123](https://github.com/squattingmonk/argumint/issues/123)
* drop redundant same-Arg branches from usage choice groups ([b862fee](https://github.com/squattingmonk/argumint/commit/b862fee25e004f4db9cace4cdf6a9d1783f25eff))
* fire before/after hooks around a matched MessageArg ([6480d76](https://github.com/squattingmonk/argumint/commit/6480d76d7d63d050d6e5b6dac53560c1f70882d4))
* fix formatUsage's blank usage line handling and genHelp's epilog formatting ([#68](https://github.com/squattingmonk/argumint/issues/68)) ([#69](https://github.com/squattingmonk/argumint/issues/69)) ([#73](https://github.com/squattingmonk/argumint/issues/73)) ([3e2d0eb](https://github.com/squattingmonk/argumint/commit/3e2d0ebb201a55340e576c2111366f48f4bc1152))
* keep completion descriptions to one line ([#114](https://github.com/squattingmonk/argumint/issues/114)) ([059e81d](https://github.com/squattingmonk/argumint/commit/059e81d703bf27a3a305d008b1eedbf07fa04f7f)), closes [#112](https://github.com/squattingmonk/argumint/issues/112)
* keep HelpError.msg plain and give every outcome a styledMsg ([#129](https://github.com/squattingmonk/argumint/issues/129)) ([24aa0f7](https://github.com/squattingmonk/argumint/commit/24aa0f710911e77a73bd7a3edca6d7e159615fd6)), closes [#127](https://github.com/squattingmonk/argumint/issues/127)
* make [options] catch-all repeatable by default (ADR 0002) ([6f794b2](https://github.com/squattingmonk/argumint/commit/6f794b2a35c472808845ce095bfc5f96bbdf0dcf))
* make ConfigKey a distinct type so its converter can't leak ([#15](https://github.com/squattingmonk/argumint/issues/15)) ([#23](https://github.com/squattingmonk/argumint/issues/23)) ([8702a97](https://github.com/squattingmonk/argumint/commit/8702a97c55145052d3be210015137f1faaf9ff96))
* name the short option that failed, not the whole cluster remainder ([#37](https://github.com/squattingmonk/argumint/issues/37)) ([58e60f9](https://github.com/squattingmonk/argumint/commit/58e60f93f1be8f5433f3c46a5e8729bfc8ff1a3a))
* preserve earned terminal flag when autoFillUsage splices onto an already-skippable line ([eafe7ed](https://github.com/squattingmonk/argumint/commit/eafe7ed55bf9a2aa9c3f09cf4df68e5388b64149)), closes [#6](https://github.com/squattingmonk/argumint/issues/6)
* prevent infinite loop in FSM shortcut-cycle simplification ([4f8a8d9](https://github.com/squattingmonk/argumint/commit/4f8a8d92b39165fefc54c2b5a8149d741089e0ea))
* print help and message output to stdout, not stderr ([#94](https://github.com/squattingmonk/argumint/issues/94)) ([8f4029c](https://github.com/squattingmonk/argumint/commit/8f4029c4fc8062c1f3f7b21f7f156c8faea36f52)), closes [#90](https://github.com/squattingmonk/argumint/issues/90)
* rank failed parse branches by Reach, not matchers satisfied ([#40](https://github.com/squattingmonk/argumint/issues/40)) ([62e7665](https://github.com/squattingmonk/argumint/commit/62e7665b0dccd75c01dea7934c543c519190b9ba))
* re-flow and wrap prolog and epilog at the help width ([#110](https://github.com/squattingmonk/argumint/issues/110)) ([4b6ba11](https://github.com/squattingmonk/argumint/commit/4b6ba118136c7c49672a2a21e05c2fd1ad1d5881)), closes [#108](https://github.com/squattingmonk/argumint/issues/108)
* re-flow Arg help text into paragraphs and lists ([#113](https://github.com/squattingmonk/argumint/issues/113)) ([18bb123](https://github.com/squattingmonk/argumint/commit/18bb123132a5ef2119bbe99f789a543954c6a79f)), closes [#109](https://github.com/squattingmonk/argumint/issues/109)
* reject a repeated Command (cmd...) too, closing the ADR 0010 gap ([9e4b5e6](https://github.com/squattingmonk/argumint/commit/9e4b5e6906eff0bdde3a0900442404b537c3b7ca))
* reject anything sequential after a Command atom (issue [#2](https://github.com/squattingmonk/argumint/issues/2), ADR 0010) ([17f6bca](https://github.com/squattingmonk/argumint/commit/17f6bca9bcdc53984696395e75a33e97a31dbdc5))
* remove stray unmatched paren in Option matcher's dot label ([916be0b](https://github.com/squattingmonk/argumint/commit/916be0bee2323e069091464399efc31eb41e8636))
* repair the generated fish completion script ([97ab082](https://github.com/squattingmonk/argumint/commit/97ab082b0b6870f5dca92b89b00d83867fa6ada4))
* report `missing argument` only where the grammar required one ([#38](https://github.com/squattingmonk/argumint/issues/38)) ([a16f267](https://github.com/squattingmonk/argumint/commit/a16f26773337eec59d4402b296c7a2fde5c6dcda))
* require every letter of an explicit short-option cluster ([#11](https://github.com/squattingmonk/argumint/issues/11)) ([7164fad](https://github.com/squattingmonk/argumint/commit/7164fad761f5e4c602be9e59548e41813833f192)), closes [#9](https://github.com/squattingmonk/argumint/issues/9)
* scope [options] catch-all exclusion to the current Usage Line ([3c6b92e](https://github.com/squattingmonk/argumint/commit/3c6b92e199341b39546aa7df297ef419d47f986d))
* show the Usage Lines the parser builds ([#140](https://github.com/squattingmonk/argumint/issues/140)) ([1783887](https://github.com/squattingmonk/argumint/commit/17838874f4be61bb13c56ec4e9ddecfd2944f359)), closes [#137](https://github.com/squattingmonk/argumint/issues/137)
* split overlong variant names and help words instead of overflowing ([#76](https://github.com/squattingmonk/argumint/issues/76)) ([160f643](https://github.com/squattingmonk/argumint/commit/160f6430d43e4111ae8ade6d8eba9162a3ecf377))
* stop exporting per-type generated Arg/Flag methods ([af237ca](https://github.com/squattingmonk/argumint/commit/af237caed8fbde8420149fdba29f9dba4b74f96d))
* tidy up exported API surface and SpecDefect messages ([abb5401](https://github.com/squattingmonk/argumint/commit/abb54017390b5bae6f484e2a27a160ebd104c0d5))


### Code Refactoring

* collapse the custom-Arg value-source contract and make it readable ([#59](https://github.com/squattingmonk/argumint/issues/59)) ([#60](https://github.com/squattingmonk/argumint/issues/60)) ([e6a6d69](https://github.com/squattingmonk/argumint/commit/e6a6d69945e00f08f7953e2c8ad41fad734c0c62))
* hand Help Formatters a HelpContext ([#120](https://github.com/squattingmonk/argumint/issues/120)) ([018e829](https://github.com/squattingmonk/argumint/commit/018e829cd86e60916e0409866c8065b1abd11c42))
* keep Help Markup's backticks as srTick spans ([#119](https://github.com/squattingmonk/argumint/issues/119)) ([df0e1d3](https://github.com/squattingmonk/argumint/commit/df0e1d35b9db7fa9a612082624ddc5e2b61cd7a6)), closes [#117](https://github.com/squattingmonk/argumint/issues/117)
* re-flowed help text becomes a Prose type ([#135](https://github.com/squattingmonk/argumint/issues/135)) ([efddc1d](https://github.com/squattingmonk/argumint/commit/efddc1d00b0f8f11f962821a6abd790c58ccab81)), closes [#133](https://github.com/squattingmonk/argumint/issues/133)
* render help through a span model ([#95](https://github.com/squattingmonk/argumint/issues/95)) ([2ed3c7d](https://github.com/squattingmonk/argumint/commit/2ed3c7d3de752f0c6c9093cefbd8c896ef86e8c9)), closes [#91](https://github.com/squattingmonk/argumint/issues/91)
* retire parseSpec; split parse (raises) from parseOrQuit (quits) ([59c83f1](https://github.com/squattingmonk/argumint/commit/59c83f16e6b28881a7fe4124a64a18d060ba3f3d))
* subsume multi-value arg*/opt* into args*/opts* ([d2802b7](https://github.com/squattingmonk/argumint/commit/d2802b723a05237372b37e6d30f82a5b9c7ad0c1))
