# A Pin backs every supported name

Refines [ADR 0080](0080-1x-freezes-the-public-modules-and-the-usage-grammar.md),
which makes six modules public and leaves the README's Stability section
to say what they cover. The README promised every name they export, and
"export" meant whatever the compiler reaches. A wholesale re-export behind
an `except` list can leak a name nobody meant to promise, and until #363
the only guard was a test per withheld name, which can't catch the next
leak. Nothing recorded what a public module reaches, or which of those
names argumint stands behind.

It ships in 1.x. Every name a program reaches today stays reachable until
2.0; what narrows is the promise about a leaked name's signature and
behaviour, which no one chose to make.

## Decision

1. **A name is supported only if a Pin backs it.** A Pin is a test in
   `tests/api/` that imports one public module and no other argumint
   module, reaches the name through it, and carries a `# pins: <line>` tag
   naming the name's Public Surface line. A name without a Pin is
   unsupported, even if a public module exports it. ADR 0080's freeze
   covers the supported names.
2. **The Public Surface is checked in.** `tests/api/surface.txt` lists
   every name the six public modules from ADR 0080 reach, one
   `<module>.<doc anchor>` per line, so an overload or a changed signature
   is a changed line. Enum members and public fields are listed as
   `Type.member`. `nimble surface` rewrites it from the generated API
   docs: the `.idx` files, the HTML Exports section (the only place the
   doc generator lists what survives an `except`), and the facade's `std/`
   exports.
3. **CI fails on any change.** The Docs job runs `nimble surface` after
   `nimble docs`, then fails if the snapshot differs from the checked-in
   one, if a line has no Pin, or if a `# pins:` tag matches no line.
   Adding, removing or changing a public name is then a diff of
   `surface.txt` in review.
4. **`!` marks a name that's reachable but unsupported.** A leaked name
   that 1.x can't withhold without a breaking change is listed with a
   leading `!` and has no Pin. It stays reachable through 1.x, but its
   signature and behaviour may change in a minor release. 2.0 withholds it
   and deletes the line.
5. **A private field's negative test sits beside its accessor's Pin.**
   The `not compiles(...)` check shares a test with the public accessor
   and a scoped `privateAccess` positive, kept inside that `test` block, so
   it fails if the field is renamed. New negatives are added only where
   writing the field would corrupt state or where an accessor shadows it.

## Considered options

- **A test per withheld name** (the rule #363 removed): rejected. It lists
  the leaks someone already thought of and misses the next one.
- **Treating every exported name as supported**, as the README read:
  rejected. It promises names nobody chose, and a leak becomes frozen the
  moment it ships.
- **An existing tool.** Nothing in the Nim ecosystem diffs a module's
  exports. `nim jsondoc` leaves out re-exports, so the HTML docs are the
  source; their output is identical on Nim 2.2.4 and 2.4.0. .NET's
  PublicApiAnalyzers, Kotlin's binary-compatibility-validator and
  `cargo-public-api` check in the same kind of snapshot.

## Consequences

- The README's Stability section promises the names in `surface.txt`
  without a `!`, instead of every exported name.
- Every public name needs a Pin before CI passes, and a leak shows up as a
  new line with no Pin.
- `argumint/customarg` gets an API doc page, since the snapshot is built
  from them.
- Code that uses a `!` name may need changes after a minor upgrade, and
  breaks in 2.0.
