## This module generates graphviz dot graphs for FSMs.

import std/[sequtils, strformat, strutils, tables]
import ./[backend, fsmgraph]

type
  StateNames = ref object
    counter: Positive = 1
    ids: TableRef[State, Positive] = newTable[State, Positive]()

proc `[]`(sn: StateNames, s: State): Positive =
  if sn.ids.hasKeyOrPut(s, sn.counter):
    return sn.ids[s]
  result = sn.counter
  sn.counter.inc

proc format(t: OrderedTableRef[State, seq[string]]): string =
  result = t.values.toSeq.mapIt(it.join("\n")).join("\n\n")

proc dot(s: State, sn: StateNames, seen: OrderedTableRef[State, seq[string]]) =
  if s in seen:
    return

  let attrs = if s.terminal: " [peripheries=2]" else: ""
  seen[s] = @["    S{sn[s]}{attrs} [label=\"S{sn[s]}\"]".fmt]

  for tr in s.transitions:
    seen[s].add(fmt"    S{sn[s]} -> S{sn[tr.next]} [label={tr.matcher.name.escape}]")
    dot(tr.next, sn, seen)

proc dot*(s: State): string =
  ## Generates a graphviz dot graph for the fsm having root node `s`. This can
  ## be used to visualize the fsm.
  let
    sn = StateNames()
    seen = newOrderedTable[State, seq[string]]()
  dot(s, sn, seen)
  result = """
    digraph G {
        rankdir=LR

    $#
    }""".dedent % [seen.format]

proc dot*(s: State, p: proc (s: State)): string =
  ## Runs the proc `p` on the fsm with the root node `s` and generates a
  ## graphviz dot graph showing the pre-proc and post-proc graph. State names
  ## are preserved between the two graphs, allowing you to see which nodes have
  ## been trimmed.
  let
    sn = StateNames()
    pre = newOrderedTable[State, seq[string]]()
    post = newOrderedTable[State, seq[string]]()

  dot(s, sn, pre)
  s.p()
  dot(s, sn, post)
  result = """
  digraph pre {
      rankdir=LR
      label="Before"

  $1
  }

  digraph post {
      rankdir=LR
      label="After"

  $2
  }
  """.dedent % [pre.format, post.format]

