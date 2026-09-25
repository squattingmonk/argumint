## Terminal capability detection: how wide output can be (`resolvedWidth`)
## and whether it can take colour (`resolvedStyler`), which `SpecSettings`'
## `width`/`style` getters call on first read (ADR 0058). Each rule is a
## pure decider taking its environment as parameters (`chooseWidth`,
## `wantsColor`), which is what the tests drive, beside a thin probe that
## reads the real process.
##
## Imports only `argumint/style`, for the ANSI styler colour resolves to.

import std/[os, parseutils, terminal]

import ./style

when defined(windows):
  import std/winlean

# Overridable at compile time with their `-d:argumint.*` defines -- see
# `docs/adr/0053-compile-time-defaults.md`.
const
  DefaultWidth* {.intdefine: "argumint.width".} = 80
    ## `newSpecSettings`'s default `width` when no terminal width can be
    ## auto-detected (e.g. piped output with `COLUMNS` unset). Set with
    ## `-d:argumint.width`.
  DefaultMaxWidth* {.intdefine: "argumint.maxWidth".} = 100
    ## The widest `newSpecSettings`'s default `width` gets on a wide
    ## terminal -- see `docs/adr/0052-default-help-width-cap.md`. Set with
    ## `-d:argumint.maxWidth`.

# 20 is the floor the help renderers already clamp a width to.
static:
  doAssert DefaultWidth >= 20,
    "-d:argumint.width must be at least 20, got " & $DefaultWidth
  doAssert DefaultMaxWidth >= 20,
    "-d:argumint.maxWidth must be at least 20, got " & $DefaultMaxWidth

proc chooseWidth*(columns: string, terminal: int): int =
  ## `detectWidth`'s rule, given `COLUMNS`'s value and the width the standard
  ## streams report (`0` if none is a terminal): a positive `columns`, else a
  ## positive `terminal`, else `DefaultWidth`.
  if parseSaturatedNatural(columns, result) > 0 and result > 0: return
  if terminal > 0: terminal else: DefaultWidth

proc detectWidth*(): int =
  ## The terminal's width, uncapped: a positive `COLUMNS`, else the width of
  ## whichever standard stream is a terminal, else `DefaultWidth`. Doesn't use
  ## `terminalWidth()`, which reads `COLUMNS` only on POSIX and falls back to
  ## its own 80 -- see `docs/gotchas.md`.
  let terminal =
    when defined(windows):
      terminalWidthIoctl([getStdHandle(STD_INPUT_HANDLE),
        getStdHandle(STD_OUTPUT_HANDLE), getStdHandle(STD_ERROR_HANDLE)])
    else:
      terminalWidthIoctl([0, 1, 2])
  chooseWidth(getEnv("COLUMNS"), terminal)

proc wantsColor(env: proc (key: string): string, ttys: bool): bool =
  ## `autoStyler`'s rule, given how to read an env var and whether stdout and
  ## stderr are both terminals.
  let clicolorForce = env("CLICOLOR_FORCE")
  if env("FORCE_COLOR").len > 0 or clicolorForce notin ["", "0"]:
    true
  elif env("NO_COLOR").len > 0 or env("TERM") == "dumb":
    false
  else:
    ttys

when defined(windows):
  const EnableVirtualTerminalProcessing = 0x0004

  # Declared here because `winlean` only gained them after 2.2.4.
  proc readConsoleMode(handle: Handle, mode: ptr DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetConsoleMode".}
  proc writeConsoleMode(handle: Handle, mode: DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "SetConsoleMode".}

  proc enableVirtualTerminal(): bool =
    ## Turns on ANSI escape handling for stdout and stderr; false if either
    ## isn't a console that supports it.
    for id in [STD_OUTPUT_HANDLE, STD_ERROR_HANDLE]:
      let handle = getStdHandle(id)
      var mode: DWORD
      if readConsoleMode(handle, addr mode) == 0 or
          writeConsoleMode(handle, mode or EnableVirtualTerminalProcessing) == 0:
        return false
    true

proc resolvedWidth*(): int =
  ## What a `width` of `0` resolves to: `detectWidth()`, capped at
  ## `DefaultMaxWidth` -- see `docs/adr/0052-default-help-width-cap.md`.
  min(detectWidth(), DefaultMaxWidth)

proc resolvedStyler*(): Styler =
  ## What an `autoStyler` style resolves to: `ansiStyler(defaultTheme)` if
  ## output is going to a terminal, else nil (plain). Nil when `NO_COLOR` is
  ## non-empty, `TERM` is `dumb`, or stdout and stderr aren't both terminals
  ## -- unless `FORCE_COLOR` is non-empty or `CLICOLOR_FORCE` is set to
  ## anything but `0`, which force colour on. On Windows it also enables the
  ## console's ANSI handling, and is nil if that fails and colour wasn't
  ## forced.
  let env = proc (key: string): string = getEnv(key)
  if not wantsColor(env, ttys = stdout.isatty and stderr.isatty):
    return nil
  when defined(windows):
    let forced = wantsColor(env, ttys = false)
    if not enableVirtualTerminal() and not forced:
      return nil
  ansiStyler(defaultTheme)

when isMainModule:
  import std/unittest

  suite "wantsColor":
    proc env(vars: varargs[(string, string)]): proc (key: string): string =
      let vars = @vars
      result = proc (key: string): string =
        for (k, v) in vars:
          if k == key: return v

    test "colour follows whether both streams are terminals":
      check wantsColor(env(), ttys = true)
      check not wantsColor(env(), ttys = false)

    test "a non-empty NO_COLOR turns it off":
      check not wantsColor(env(("NO_COLOR", "1")), ttys = true)
      check wantsColor(env(("NO_COLOR", "")), ttys = true)

    test "TERM=dumb turns it off":
      check not wantsColor(env(("TERM", "dumb")), ttys = true)
      check wantsColor(env(("TERM", "xterm")), ttys = true)

    test "a non-empty FORCE_COLOR turns it on, even over NO_COLOR":
      check wantsColor(env(("FORCE_COLOR", "1")), ttys = false)
      check wantsColor(env(("FORCE_COLOR", "0")), ttys = false)
      check wantsColor(env(("FORCE_COLOR", "1"), ("NO_COLOR", "1")), ttys = false)
      check not wantsColor(env(("FORCE_COLOR", "")), ttys = false)

    test "CLICOLOR_FORCE turns it on unless it's 0":
      check wantsColor(env(("CLICOLOR_FORCE", "1")), ttys = false)
      check wantsColor(env(("CLICOLOR_FORCE", "1"), ("TERM", "dumb")), ttys = false)
      check not wantsColor(env(("CLICOLOR_FORCE", "0")), ttys = false)

  suite "resolvedStyler":
    test "is nil when output isn't a terminal and colour isn't forced":
      let forced = getEnv("FORCE_COLOR").len > 0 or
        getEnv("CLICOLOR_FORCE") notin ["", "0"]
      if not forced and not (stdout.isatty and stderr.isatty):
        check resolvedStyler().isNil
      else:
        skip()

    when defined(windows):
      test "enabling ANSI handling fails without crashing when not a console":
        if not (stdout.isatty and stderr.isatty):
          check not enableVirtualTerminal()
          putEnv("FORCE_COLOR", "1")
          defer: delEnv("FORCE_COLOR")
          check not resolvedStyler().isNil # forced, despite the failure
        else:
          skip()
