# Arguments and Options

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

## Declaring Arguments and Options

Every field in a spec tuple is built with a constructor: `arg[T]()` for
positional arguments or `opt[T]()` for options, where `T` is the value type for
the argument. `T` and `default` can each be given explicitly, or left for
argumint to infer:

- explicit `[T]`, no `default` — falls back to `default(T)` (e.g. `0`, `0.0`,
  `false`)
- no `[T]`, explicit `default` — `T` is inferred from the default value's type
- neither — `T` falls back to `string`, `default` to `""`

The implicit forms are more friendly, so they are preferred in the examples.

```nim
let
  spec = (
    foo: arg("<foo>"),              # T implicitly string, default ""
    bar: arg("<bar>", default = 3), # T implicitly int, default 3
    baz: opt[int]("--baz=<n>"),     # T explicitly int, default 0
    qux: opt[int]("--qux=<n>", 5)   # T explicitly int, default 5
  )
```

**`arg` and `opt` can each capture a single value.** If the argument or option
is matched more than once (e.g., usage string is `<name>...`), only the last
value seen is kept. `args[T]()` and `opts[T]()` are their **multi-value
counterparts**: instead of a plain `T`, their stored value is a `seq[T]`,
collecting every value matched. `T` and `default` follow the same rules as
`arg[T]()`/`opt[T]()`, with one difference — `T` can't be inferred from a bare
`@[]`, so an explicit `default` needs at least one element:

- explicit `[T]`, no `default` — falls back to `newSeq[T]()` (`@[]`)
- no `[T]`, explicit `default` (non-empty) — `T` is inferred from the
  default's element type
- neither — `T` falls back to `string`, `default` to `@[]`

```nim
let
  spec = (
    foo: args("<foo>"),                    # T implicitly string, default @[]
    bar: opts[int]("--bar=<n>"),           # T explicitly int, default @[]
    baz: opts("--baz=<n>", default = @[1]) # T implicitly int, default @[1]
  )

spec.parseOrQuit(
  usage = "<foo>... [--bar=<n>]... [--baz=<n>]...",
  args = @["a.txt", "b.txt", "--bar", "3", "--bar", "4", "--baz", "5"])
assert spec.foo == @["a.txt", "b.txt"]
assert spec.bar == @[3, 4]
assert spec.baz == @[5]
```

The default value of `arg[T]()`/`args[T]()`/`opt[T]()`/`opts[T]()` fall back to
`default` for their value if the `Arg` is not seen during parsing. `opt[T]()`
and `opts[T]()` can also fall back to an environment variable via `env` or a
config file via `configKey` if the user doesn't specify a value on the
command-line. See [Value Precedence](precedence.md#value-precedence).

### Validating Values

`arg`/`opt`/`args`/`opts` each take an optional `validator: Validator[T]`
(`argumint/validators`), checked against every value the user actually
supplies — never against a coded `default`, so an `Arg` the user never
touches is exempt (see
`docs/adr/0008-validators-dont-run-against-defaults.md`). A failing value
raises `ValidationError` (contrast `flag`'s `clamp`, which never raises —
see below).

- `choice(values)` — must be one of `values`
- `range(bounds)` — must fall within `bounds`
- `check(pred)` / `checkIt(pred)` — must satisfy an arbitrary predicate
  (`checkIt` lets you write the predicate inline, using `it` for the value)
- `unique()` — for `args`/`opts`, must not repeat a value already matched
  for the same `Arg`
- `all(...)` / `any(...)` — combine several validators with AND/OR
  semantics, nesting freely

`choice`/`range` infer `T` from their arguments, and `all`/`any` infer it
from their child validators; `check`/`checkIt`/`checkSeen`/`checkSeenIt`/
`unique` always need an explicit `[T]` (e.g. `unique[string]()`), no matter
how `T` is determined elsewhere in the same `arg`/`opt`/`args`/`opts` call.

```nim
let spec = (
  port: opt[int]("--port=<n>", default = 8080, validator = range(1..65535)),
  env: opt("--env=<name>", default = "dev",
    validator = choice(["dev", "staging", "prod"])),
  tags: opts("--tag=<t>", validator = unique[string]()),
  even: opt[int]("--even=<n>", default = 0,
    validator = check[int](proc (x: int): bool = x mod 2 == 0, "must be even")),
  word: arg("<word>",
    validator = checkIt[string](it.len <= 10, "must be at most 10 characters"))
)
```

Passing `--port=0` or `--env=test` above raises a `ValidationError` before
the value is ever stored; passing `--tag=a --tag=a` raises on the second
`a`; `--even=3` raises via `check`; a `<word>` longer than 10 characters
raises via `checkIt`.

Every validator also folds its constraint into the auto-generated help text
(e.g. `[choices: "dev", "staging", "prod"]`), so users see what's accepted
without needing `--help` to fail first.
