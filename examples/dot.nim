# This example demonstrates the FSM-visualization feature: any `Spec`'s finite
# state machine can be rendered as a Graphviz dot graph via `spec.dot` (see
# `src/argumint/dot.nim` and CLAUDE.md's architecture notes). Nothing calls this
# automatically -- it's a debugging aid you wire up yourself. Pipe the output
# through `scripts/dot2png.sh` to turn it into a viewable PNG:
#
#   nim c examples/dot.nim && ./examples/dot | scripts/dot2png.sh
import argumint

let
  spec = (
    src: args("<src>", help = "The source file(s) to copy"),
    dest: arg("<dest>", help = "The destination to copy to"),
    recursive: flag("-r, --recursive", help = "Whether to recurse into subdirectories"),
    help: help()
  )

echo spec.dot(usage = "[-r] <src>... <dest>")
