# This example implements the full canonical Naval Fate example from
# docopt's own README/tests:
# ```
# Naval Fate.
#
# Usage:
#   naval_fate ship new <name>...
#   naval_fate ship <name> move <x> <y> [--speed=<kn>]
#   naval_fate ship shoot <x> <y>
#   naval_fate mine (set|remove) <x> <y> [--moored|--drifting]
#   naval_fate -h | --help
#   naval_fate --version
# ```
# Unlike the smaller Naval Fate excerpt in `src/argumint.nim`'s
# `when isMainModule` block (which only covers `ship move` and a
# validator-based `mine <action>`), this covers every action and
# demonstrates *nested* commands: `ship`/`mine` are commands whose own specs
# are themselves built from further commands (`new`/`move`/`shoot` and
# `set`/`remove`), rather than plain positional/option args.
#
# One deviation from the canonical grammar: docopt's `ship <name> move <x>
# <y>` puts `<name>` before the literal word `move`. argumint's `command()`
# dispatches on the command word first, so this becomes `ship move <name> <x>
# <y>` instead -- the same information, just reordered to fit argumint's
# command-first idiom.

import std/strformat

import argumint
import argumint/validators

proc cmdShipNew(spec: tuple) =
  for name in spec.names:
    echo fmt"Ship {name} has been built"

proc cmdShipMove(spec: tuple) =
  echo fmt"Moving ship {spec.name} to ({spec.x}, {spec.y}) at {spec.speed} knots"

proc cmdShipShoot(spec: tuple) =
  echo fmt"Firing on ({spec.x}, {spec.y})"

proc mineKind(spec: tuple): string =
  if spec.moored: "moored mine"
  elif spec.drifting: "drifting mine"
  else: "mine"

proc cmdMineSet(spec: tuple) =
  echo fmt"Laying a {spec.mineKind} at ({spec.x}, {spec.y})"

proc cmdMineRemove(spec: tuple) =
  echo fmt"Removing a {spec.mineKind} from ({spec.x}, {spec.y})"

let
  shipNew = (
    names: args[string]("<name>", help = "Name(s) of the new ship(s)"),
    help: help()
  )

  shipMove = (
    name: arg("<name>", help = "Ship to move"),
    x: arg("<x>", default = 0, help = "x grid reference"),
    y: arg("<y>", default = 0, help = "y grid reference"),
    speed: opt("--speed=<kn>", default = 10, validator = range(1..100), help = "Speed in knots"),
    help: help()
  )

  shipShoot = (
    x: arg("<x>", default = 0, help = "x grid reference"),
    y: arg("<y>", default = 0, help = "y grid reference"),
    help: help()
  )

  ship = (
    new: command("new", shipNew, handler = cmdShipNew, usage = "<name>...", help = "Build new ship(s)"),
    move: command(
      "move", shipMove, handler = cmdShipMove,
      usage = "<name> <x> <y> [--speed=<kn>]", help = "Move a ship to a new position"
    ),
    shoot: command("shoot", shipShoot, handler = cmdShipShoot, usage = "<x> <y>", help = "Shoot at a position"),
    help: help()
  )

  mineSet = (
    x: arg("<x>", default = 0, help = "x grid reference"),
    y: arg("<y>", default = 0, help = "y grid reference"),
    moored: flag("--moored", help = "Moored (anchored) mine"),
    drifting: flag("--drifting", help = "Drifting mine"),
    help: help()
  )

  mineRemove = (
    x: arg("<x>", default = 0, help = "x grid reference"),
    y: arg("<y>", default = 0, help = "y grid reference"),
    moored: flag("--moored", help = "Moored (anchored) mine"),
    drifting: flag("--drifting", help = "Drifting mine"),
    help: help()
  )

  mine = (
    set: command("set", mineSet, handler = cmdMineSet, usage = "<x> <y> [--moored | --drifting]", help = "Lay a mine"),
    remove: command(
      "remove", mineRemove, handler = cmdMineRemove,
      usage = "<x> <y> [--moored | --drifting]", help = "Remove a mine"
    ),
    help: help()
  )

  spec = (
    ship: command("ship", ship, help = "Ship commands"),
    mine: command("mine", mine, help = "Mine commands"),
    help: help(),
    version: version("Naval Fate 2.0.0")
  )

spec.parseOrQuit(prolog = "Naval Fate")
