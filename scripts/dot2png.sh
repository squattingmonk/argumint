#!/usr/bin/env bash
# Renders a Graphviz dot graph (e.g. from argumint's `spec.dot`/
# `spec.fsm.dot`) to a PNG.
#
# Usage: scripts/dot2png.sh [input.dot] [output.png]
#   - With no input.dot, reads dot source from stdin.
#   - With no output.png, writes to fsm.png (or <input>.png alongside a
#     given input.dot).
set -euo pipefail

if ! command -v dot >/dev/null 2>&1; then
  echo "error: graphviz's 'dot' command not found; install graphviz" >&2
  exit 1
fi

if [[ -n "${1:-}" ]]; then
  input="$1"
  output="${2:-${1%.*}.png}"
else
  input="/dev/stdin"
  output="${2:-fsm.png}"
fi

dot -Tpng "$input" -o "$output"
echo "wrote $output"
