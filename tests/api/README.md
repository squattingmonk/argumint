# API tests

What a program reaches through argumint's public modules (ADR 0080): the
names it can use, the private fields it can't, and the constraints the
types are designed to enforce. A test here shows a call is accepted the
way a user would write it. Behaviour belongs in the other `tests/` files: a
test here may repeat a behaviour check when that's the natural way to make
the call, but no behaviour is tested only here.

Every file here imports public modules and `std/` only, never an internal
module such as `argumint/core/backend`. An internal import can put a name in
scope that the public modules don't, so a `compiles(...)` check would pass
for the wrong reason. `backend`'s exported `prolog` accessor, for one, makes
`spec.prolog` compile even though the field is private.

No test checks that a name is withheld (#363). A private field's
`not compiles(...)` sits beside a `privateAccess` positive in the same test,
since the negative alone would also pass for a field that no longer exists.

## Pins

A name a public module reaches is supported only if a Pin backs it (ADR
0090). `surface.txt` lists every such name, one `<module>.<doc anchor>` per
line, and `nimble surface` rewrites it from `htmldocs/`, so run `nimble
docs` first. A Pin is a test here that reaches the name through its line's
module and carries the line as a tag, one per line:

```nim
test "reading a value":
  # pins: argumint.get,ValueArg[T]
  check spec.port.get == 1
```

The tag goes on the code that reaches the name: usually a statement in a
test, but also a top-level declaration a test relies on, such as a type
that inherits `ConfigSource` or a proc that's never run (below).

A file with tags imports that one public module and no other argumint
module, so an overload resolves the way it would for a program that does
the same. Where a module alone can't build what a call needs (an Arg from
`argumint/customarg`, a Spec from `argumint/help`), compile the call in a
proc that's never run; `test_customarg.nim`'s `paramType` names a type the
module doesn't export.

Two changes don't show as a changed line: a `std/` type's members, such as
`ForegroundColor`'s values, aren't listed, since std's own docs aren't in
`htmldocs/`, and docgen leaves a generic first parameter such as
`spec: tuple` out of the anchor (`argumint.dot,,string`).

A line marked `!` is reachable but unsupported: a leak 1.x can't withhold
without breaking someone, which 2.0 removes. It has no Pin. A new line is
unmarked, so `nimble surface` fails on it until it gets a Pin or a `!`,
and the rewrite keeps the `!`s already there. CI fails if the rewrite
changed `surface.txt`, if a supported line has no Pin, or if a tag matches
no line.
