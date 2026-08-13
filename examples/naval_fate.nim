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
# This covers every action and demonstrates *nested* commands: `ship`/`mine`
# are commands whose own specs are themselves built from further commands
# (`new`/`move`/`shoot` and `set`/`remove`), rather than plain
# positional/option args.
#
# One deviation from the canonical grammar: docopt's `ship <name> move <x>
# <y>` puts `<name>` before the literal word `move`. argumint's `command()`
# dispatches on the command word first, so this becomes `ship move <name> <x>
# <y>` instead -- the same information, just reordered to fit argumint's
# command-first idiom.

import std/strformat

import argumint

proc cmdShipNew(spec: tuple, info: HookInfo) =
  for name in spec.names:
    echo fmt"Ship {name} has been built"

proc cmdShipMove(spec: tuple, info: HookInfo) =
  echo fmt"Moving ship {spec.name} to ({spec.x}, {spec.y}) at {spec.speed} knots"

proc cmdShipShoot(spec: tuple, info: HookInfo) =
  echo fmt"Firing on ({spec.x}, {spec.y})"

proc mineKind(spec: tuple): string =
  if spec.moored: "moored mine" else: "drifting mine"

proc cmdMineSet(spec: tuple, info: HookInfo) =
  echo fmt"Laying a {spec.mineKind} at ({spec.x}, {spec.y})"

proc cmdMineRemove(spec: tuple, info: HookInfo) =
  echo fmt"Removing a {spec.mineKind} from ({spec.x}, {spec.y})"

let
  moored = flag(ops = [
    flagOp("--moored", "=", true, "Moored (anchored) mine"),
    flagOp("--drifting", "=", false, "Drifting mine"),
  ])

  shipNew = (
    names: args("<name>", help = "Name(s) of the new ship(s)"),
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
    new: command("new", shipNew, action = cmdShipNew, usage = "<name>...", help = "Build new ship(s)"),
    move: command(
      "move", shipMove, action = cmdShipMove,
      usage = "<name> <x> <y> [--speed=<kn>]", help = "Move a ship to a new position"
    ),
    shoot: command("shoot", shipShoot, action = cmdShipShoot, usage = "<x> <y>", help = "Shoot at a position"),
    help: help()
  )

  mineSet = (
    x: arg("<x>", default = 0, help = "x grid reference"),
    y: arg("<y>", default = 0, help = "y grid reference"),
    moored: moored,
    help: help()
  )

  mineRemove = (
    x: arg("<x>", default = 0, help = "x grid reference"),
    y: arg("<y>", default = 0, help = "y grid reference"),
    moored: moored,
    help: help()
  )

  mine = (
    set: command("set", mineSet, action = cmdMineSet, usage = "<x> <y> [--moored | --drifting]", help = "Lay a mine"),
    remove: command(
      "remove", mineRemove, action = cmdMineRemove,
      usage = "<x> <y> [--moored | --drifting]", help = "Remove a mine"
    ),
    help: help()
  )

  spec = (
    ship: command("ship", ship, help = "Ship commands"),
    mine: command("mine", mine, help = "Mine commands"),
    help: help(),
    version: version("-v, --version", "Naval Fate 2.0.0")
  )

spec.parseOrQuit(prolog = "Naval Fate")
