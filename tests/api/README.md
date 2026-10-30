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
