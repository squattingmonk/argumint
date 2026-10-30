# `thisDir()`, not `$projectDir`: a test in a subdirectory such as
# `tests/api/` also loads this file, and `$projectDir` is its own directory.
switch("path", thisDir() & "/../src")
# argumint has no dependencies, so nothing should come from nimble's package
# dir; without this, a wrong `path` silently tests an installed argumint.
switch("noNimblePath")
