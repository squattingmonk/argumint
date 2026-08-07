# Changelog

## [1.0.0](https://github.com/squattingmonk/argumint/compare/v0.1.0...v1.0.0) (2026-08-07)


### ⚠ BREAKING CHANGES

* reorder message/version params, drop version's default variants
* arg/opt fall back to default(T), matching args/opts (ADR 0023)
* pass HookInfo to before/action/after hooks (ADR 0021)
* parse* no longer quits on error; use parseOrQuit* for that. parseSpec* is gone -- use Spec.parse instead.
* subsume multi-value arg*/opt* into args*/opts*

### Features

* add a dot-graph-to-PNG script and example ([33fc75c](https://github.com/squattingmonk/argumint/commit/33fc75c5071b8ad6c62fd6c33d8118c91b32a605))
* add composable all()/any() Validators (ADR 0006) ([42f4e67](https://github.com/squattingmonk/argumint/commit/42f4e6768086a80c1cc87020148ad84e80be40cd))
* add Config Source, a third Value Precedence tier ([576a606](https://github.com/squattingmonk/argumint/commit/576a6064e255d25833136ff1dbe71d37213652d2))
* add dynamic shell completion via a `__complete` FSM re-walk (ADR 0012) ([4c6c3c3](https://github.com/squattingmonk/argumint/commit/4c6c3c351e06c7d6eec74b809211575812cec57f))
* add Flag Clamp for silently constraining Flag values ([317295f](https://github.com/squattingmonk/argumint/commit/317295f4ff1d00ecdd428c5c215f22a9caa16cc6))
* add history-aware Validators via checkSeen()/checkSeenIt()/unique() (ADR 0007) ([d2c59f3](https://github.com/squattingmonk/argumint/commit/d2c59f3ab991c949adef518bb0c995b3cf0c5151))
* add per-arg env delimiter overrides via EnvSource ([dfe24d3](https://github.com/squattingmonk/argumint/commit/dfe24d351f5cbc681b4f4c91962674a4345f39e5))
* add typo suggestion for long options ([da0c91f](https://github.com/squattingmonk/argumint/commit/da0c91fb521ab88efabe2dfb06b40aa1f9779ca9))
* add usage-string End-of-Options Marker (--) ([a32aa91](https://github.com/squattingmonk/argumint/commit/a32aa913f5d7f6425eb7926322ab967ad2d97e3d))
* arg/opt fall back to default(T), matching args/opts (ADR 0023) ([a6400c8](https://github.com/squattingmonk/argumint/commit/a6400c87e8589e0d036eb2864850a3df0386405f))
* auto-detect terminal width for usage/help wrapping ([dfc7ea9](https://github.com/squattingmonk/argumint/commit/dfc7ea912a69bf666477b16e547860c85b319316))
* auto-generate per-variant descriptions for flags with divergent ops ([42b2ea4](https://github.com/squattingmonk/argumint/commit/42b2ea4dfacebca803b0df0eb3a8e4c78b138ec5))
* cap and wrap the help text's variants column ([8e7509e](https://github.com/squattingmonk/argumint/commit/8e7509e54e00b71977ac7a891f8d8f9b2a947eb7))
* generate HTML API docs with nim doc and publish to GitHub Pages ([d828a6b](https://github.com/squattingmonk/argumint/commit/d828a6bccc9f2a44505ddd14cc09100bbbd83704))
* give arg/opt/args/opts/flag default(T) fallback and a bare-call shorthand together (ADR 0024) ([f9b07d6](https://github.com/squattingmonk/argumint/commit/f9b07d645f7189ef22c322121c77a7fcca260d2c))
* let a required Option/Flag's env var satisfy the requirement ([b3d4313](https://github.com/squattingmonk/argumint/commit/b3d43139227fc49fa11e4ac1458327242718b95b))
* let an env var supply multiple values to Options and Flags ([815862a](https://github.com/squattingmonk/argumint/commit/815862a05699017da444d78df887ff830951f7d8))
* pass HookInfo to before/action/after hooks (ADR 0021) ([79d8fc2](https://github.com/squattingmonk/argumint/commit/79d8fc2b0101bcddfa80ece59cfb702fb689ff6d))
* reorder message/version params, drop version's default variants ([ebbfce4](https://github.com/squattingmonk/argumint/commit/ebbfce4464b80ede9aee55986a614e6d999ee0e9))
* replace CommandArg.handler with before/action/after hooks on Spec (ADR 0009) ([e8d1aa9](https://github.com/squattingmonk/argumint/commit/e8d1aa98956c8a139e3bede0bf0b952fd15a07fa))
* replace eager tokenizeArgs with lazy, walk-time token classification ([#5](https://github.com/squattingmonk/argumint/issues/5)) ([43fb463](https://github.com/squattingmonk/argumint/commit/43fb4633a3cf21db490101c41d5d01a345862daf))
* replace eager tokenizeArgs with lazy, walk-time token classification ([#5](https://github.com/squattingmonk/argumint/issues/5)) ([43fb463](https://github.com/squattingmonk/argumint/commit/43fb4633a3cf21db490101c41d5d01a345862daf))
* share width/maxVariantsWidth/envDelim via a mutable SpecConfig ref ([1094522](https://github.com/squattingmonk/argumint/commit/1094522c4bf97acc8257ebb937ad323efac186b9))
* show help text on shell completion candidates (fish, zsh) ([4797ef8](https://github.com/squattingmonk/argumint/commit/4797ef832e471f521c8742067474b40fb979fd91))
* support environment variables for opt/flag values ([0d7939c](https://github.com/squattingmonk/argumint/commit/0d7939c78d45e543d57f38af21220a1950392a1a))
* support hiding args from help messages ([5e709a9](https://github.com/squattingmonk/argumint/commit/5e709a9237532612978990821c726cdfac3745c1))
* support set[enum] flags, with typed variant values ([dd4372a](https://github.com/squattingmonk/argumint/commit/dd4372ab1499220726f49f695d5df07d2bbcb37b))


### Bug Fixes

* a spec with zero declared args can now parse successfully ([6927d13](https://github.com/squattingmonk/argumint/commit/6927d1323732a6a81ec9447f15969947622169ad))
* apply env-var fallback to every entered spec level, not just the deepest ([a692fae](https://github.com/squattingmonk/argumint/commit/a692faea03d9d4b5190fc89b9c99dcbafdef7c3d))
* de-noise parse-error messages ([8c536a2](https://github.com/squattingmonk/argumint/commit/8c536a29c293e589897e9a49c748fb8fb05193b1))
* drop redundant same-Arg branches from usage choice groups ([b862fee](https://github.com/squattingmonk/argumint/commit/b862fee25e004f4db9cace4cdf6a9d1783f25eff))
* fire before/after hooks around a matched MessageArg ([6480d76](https://github.com/squattingmonk/argumint/commit/6480d76d7d63d050d6e5b6dac53560c1f70882d4))
* make [options] catch-all repeatable by default (ADR 0002) ([6f794b2](https://github.com/squattingmonk/argumint/commit/6f794b2a35c472808845ce095bfc5f96bbdf0dcf))
* preserve earned terminal flag when autoFillUsage splices onto an already-skippable line ([eafe7ed](https://github.com/squattingmonk/argumint/commit/eafe7ed55bf9a2aa9c3f09cf4df68e5388b64149)), closes [#6](https://github.com/squattingmonk/argumint/issues/6)
* prevent infinite loop in FSM shortcut-cycle simplification ([4f8a8d9](https://github.com/squattingmonk/argumint/commit/4f8a8d92b39165fefc54c2b5a8149d741089e0ea))
* reject a repeated Command (cmd...) too, closing the ADR 0010 gap ([9e4b5e6](https://github.com/squattingmonk/argumint/commit/9e4b5e6906eff0bdde3a0900442404b537c3b7ca))
* reject anything sequential after a Command atom (issue [#2](https://github.com/squattingmonk/argumint/issues/2), ADR 0010) ([17f6bca](https://github.com/squattingmonk/argumint/commit/17f6bca9bcdc53984696395e75a33e97a31dbdc5))
* remove stray unmatched paren in Option matcher's dot label ([916be0b](https://github.com/squattingmonk/argumint/commit/916be0bee2323e069091464399efc31eb41e8636))
* repair the generated fish completion script ([97ab082](https://github.com/squattingmonk/argumint/commit/97ab082b0b6870f5dca92b89b00d83867fa6ada4))
* require every letter of an explicit short-option cluster ([#11](https://github.com/squattingmonk/argumint/issues/11)) ([7164fad](https://github.com/squattingmonk/argumint/commit/7164fad761f5e4c602be9e59548e41813833f192)), closes [#9](https://github.com/squattingmonk/argumint/issues/9)
* scope [options] catch-all exclusion to the current Usage Line ([3c6b92e](https://github.com/squattingmonk/argumint/commit/3c6b92e199341b39546aa7df297ef419d47f986d))
* stop exporting per-type generated Arg/Flag methods ([af237ca](https://github.com/squattingmonk/argumint/commit/af237caed8fbde8420149fdba29f9dba4b74f96d))
* tidy up exported API surface and SpecDefect messages ([abb5401](https://github.com/squattingmonk/argumint/commit/abb54017390b5bae6f484e2a27a160ebd104c0d5))


### Code Refactoring

* retire parseSpec; split parse (raises) from parseOrQuit (quits) ([59c83f1](https://github.com/squattingmonk/argumint/commit/59c83f16e6b28881a7fe4124a64a18d060ba3f3d))
* subsume multi-value arg*/opt* into args*/opts* ([d2802b7](https://github.com/squattingmonk/argumint/commit/d2802b723a05237372b37e6d30f82a5b9c7ad0c1))
