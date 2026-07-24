## This module handles the navigation of the FSM based on a set of provided
## command-line arguments.
import std/[editdistance, os, pegs, sets, strformat, strutils, sugar, tables]

# `Option` (the type) deliberately left unqualified-unimported --
# `options.Option[T]` instead, since a bare `import std/options` breaks
# every `case ... of Option:` branch matching `MatcherKind.Option` in this
# file -- see docs/gotchas.md.
from std/options import some, none, isSome, get

import ./[backend, configsource, parser]
export ParseError, SpecDefect, CompletionError


type
  Match = tuple[variant: string, value: string, spec: Spec]
  MatchTable = OrderedTable[Arg, seq[Match]]
  Complaint = tuple[kind: string, subject: string]
    ## A failure reason, e.g. `("missing option", "-v")`. Kept structured
    ## (rather than a pre-formatted string) so same-kind complaints can be
    ## grouped into one message at render time -- see `parse`.

  ValueCursor = object
    ## Owns one Value Precedence fallback tier (env or Config Source) --
    ## see architecture.md's "Env var mechanics",
    ## `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`, and
    ## `docs/adr/0018-config-source.md`. Shared shape for both tiers:
    ## `probe` resolves and caches an Arg's available values (via a
    ## tier-specific `resolve` closure -- see `resolveEnv`/`resolveConfig`)
    ## the first time it's consulted during the walk, then hands out one
    ## value per subsequent call; `applyFallbacks`'s post-walk sweep reads
    ## `consumed`/`values` back to apply whatever the walk consumed (or
    ## complain about oversupply).
    values: Table[Arg, seq[string]]
    consumed: Table[Arg, int]
    tried: HashSet[Arg]
      ## Ensures `resolve` runs at most once per Arg for the life of this
      ## cursor, including caching a miss -- unlike an env lookup, a
      ## user-supplied `ConfigSource.lookup` may be arbitrarily expensive.

  ParseContext = object
    depth: int            ## The depth of the current fsm path
    maxDepth: int         ## The depth of the deepest fsm path prior to the current one
    spec: Spec            ## The spec for the *live* walk position -- consulted by classify()/match() as the walk progresses; never retroactively overwritten by a failed sibling's own descent (see errorSpec)
    command: string       ## The command string up to the current subcommand, for the live walk position -- see `spec`
    errorSpec: Spec       ## Spec for the deepest fsm path's own failure, for the final error message only -- must stay separate from `spec`, see ADR 0019 point 7
    errorCommand: string  ## See `errorSpec`
    messages: seq[Complaint] ## A list of complaints indicating failure reason of the deepest fsm path
    tokens: seq[RawToken]     ## The arguments left to be parsed
    optsEnd: bool          ## Whether this path has crossed a literal `--` -- see ADR 0019
    matches: MatchTable   ## A table of processed matches
    env: ValueCursor        ## Value Precedence's environment-variable tier -- see `ValueCursor`
    configValues: ValueCursor ## Value Precedence's Config Source tier -- see `ValueCursor`

  RawToken = object
    ## A raw command-line token, classified only as far as pure string shape
    ## can tell without consulting a `Spec` -- see ADR 0019.
    raw: string     ## The literal token as typed
    optShape: bool  ## True if `raw` looks like `-o`/`--opt`/`-o=val`/
      ## `--opt=val`, or a `-xyz`-shaped cluster candidate

  Classification = object
    ## What a `RawToken` actually is, resolved lazily against a `Spec` --
    ## see `classify`, ADR 0019. `consumed`/`remainder` feed `consume`.
    consumed: int
    remainder: string
    case kind: ArgKind
    of Command:
      cmd: CommandArg
      cmdName: string
    of Optional:
      opt: Arg
      optName: string
      optVal: string
      optSep: string
    of Flag:
      flag: Arg
      flagName: string
    of Positional:
      argVal: string

let
  OptionValueFormat = peg"""
    # Allows you to capture [-o, =, val] / [--option, =, val] in -o=val / --option=val
    option <- ^ {(shortOption / longOption)} ({equals} {value}) $
    equals <- '=' / ':'
    shortOption <- '-' \w
    longOption <- '--' \w (\w / ('-' \w))+
    value <- _*
  """

  OptionFormat = peg"""
  # Allows you to capture -o / --option
  option <- ^ {(shortOption / longOption)} $
  shortOption <- '-' \w
  longOption <- '--' \w (\w / ('-' \w))+
  """

proc unknownOptionMsg(unknownVariant: string, spec: Spec): string =
  result = fmt"unrecognized option {unknownVariant}"
  if unknownVariant.len > 2:
    for knownVariant in spec.options.keys:
      if knownVariant.len > 2 and editDistance(unknownVariant, knownVariant) == 1:
        result.add fmt"; did you mean {knownVariant}?"
        break

proc isOptShape(raw: string): bool =
  ## Pure string-shape recognition needing no `Spec` -- see ADR 0019.
  raw =~ OptionFormat or raw =~ OptionValueFormat or
    (raw.len > 2 and raw[0] == '-' and raw[1] != '-')

proc tokenizeArgs(args: seq[string], start = 0): seq[RawToken] =
  ## Splits `args[start..]` into `RawToken`s by shape only -- never touches
  ## `Spec`, never raises -- see ADR 0019.
  for i in start ..< args.len:
    result.add RawToken(raw: args[i], optShape: args[i].isOptShape)

proc classify(spec: Spec, tokens: seq[RawToken], pos: int, optsEnd: bool): Classification =
  ## Decides what `tokens[pos]` is against `spec`'s tables -- the lazy half
  ## of ADR 0019. Never raises: an unresolved option-shaped token falls
  ## through to the `Positional` fallback at the bottom.
  let token = tokens[pos]
  if optsEnd:
    return Classification(kind: Positional, argVal: token.raw, consumed: 1)
  if token.raw in spec.commands:
    return Classification(kind: Command, cmd: spec.commands[token.raw], cmdName: token.raw, consumed: 1)
  if token.optShape:
    # Bare `-o`/`--option`; an Optional's value comes from the next token.
    if token.raw =~ OptionFormat:
      let variant = token.raw
      if variant in spec.options:
        let option = spec.options[variant]
        case option.kind
        of Flag:
          return Classification(kind: Flag, flag: option, flagName: variant, consumed: 1)
        of Optional:
          if pos + 1 < tokens.len:
            return Classification(kind: Optional, opt: option, optName: variant, optVal: tokens[pos + 1].raw, consumed: 2)
        else: discard
    # `-o=val` / `--option=value`.
    elif token.raw =~ OptionValueFormat:
      let (variant, sep, value) = (matches[0], matches[1], matches[2])
      if variant in spec.options and spec.options[variant].kind == Optional:
        return Classification(kind: Optional, opt: spec.options[variant], optName: variant, optSep: sep, optVal: value, consumed: 1)
    # A cluster of short options (`-abc`). Only the first letter resolves
    # here -- a Flag leaves the rest as `remainder` for `consume` to
    # reinsert; an Optional swallows the rest as its value. See ADR 0019
    # point 2 on why this can't be decided eagerly.
    elif token.raw.len > 2 and token.raw[0] == '-' and token.raw[1] != '-':
      let variant = "-" & token.raw[1]
      if variant in spec.options:
        let option = spec.options[variant]
        let folded = token.raw.substr(2)
        case option.kind
        of Flag:
          return Classification(kind: Flag, flag: option, flagName: variant, consumed: 1,
            remainder: (if folded.len > 0: "-" & folded else: ""))
        of Optional:
          if folded.len == 0:
            if pos + 1 < tokens.len:
              return Classification(kind: Optional, opt: option, optName: variant, optVal: tokens[pos + 1].raw, consumed: 2)
          elif fmt"{variant}{folded}" =~ OptionValueFormat:
            return Classification(kind: Optional, opt: option, optName: variant, optSep: matches[1], optVal: matches[2], consumed: 1)
          else:
            return Classification(kind: Optional, opt: option, optName: variant, optVal: folded, consumed: 1)
        else: discard
  Classification(kind: Positional, argVal: token.raw, consumed: 1)

proc consume(pc: var ParseContext, pos: int, c: Classification) =
  ## Removes/reinserts the raw token(s) an accepted `Classification`
  ## accounts for at `pos` -- see `classify`'s cluster branch, ADR 0019.
  pc.tokens.delete pos
  if c.consumed == 2:
    pc.tokens.delete pos # the value that was tokens[pos + 1]
  elif c.remainder.len > 0:
    pc.tokens.insert(RawToken(raw: c.remainder, optShape: c.remainder.isOptShape), pos)

proc consumeOptsEnd(pc: var ParseContext, pos: int): bool =
  ## Drops a not-yet-consumed literal `--` at `pos` and marks this path
  ## past the end of options -- see ADR 0019. Returns whether it did so,
  ## so callers can re-examine `pos` without incrementing.
  if not pc.optsEnd and pc.tokens[pos].raw == "--":
    pc.tokens.delete pos
    pc.optsEnd = true
    result = true

proc push(matches: var MatchTable, arg: Arg, spec: Spec, variant: string, value = "") =
  ## Adds a matched arg's seen variant and value to the table of matches,
  ## tagged with the Spec it was matched under (`spec`, i.e. the spec
  ## level whose own grammar this match's Matcher belongs to) -- needed so
  ## `dispatch` (`Spec.parse`'s tail) can tell apart two independent real
  ## matches of the same `Arg` reachable at two different grammar levels
  ## from one match seen twice. See
  ## `docs/adr/0009-command-before-action-after-hooks.md`.
  if matches.hasKeyOrPut(arg, @[(variant, value, spec)]):
    matches[arg].add (variant, value, spec)

proc resolveEnv(arg: Arg, spec: Spec): options.Option[seq[string]] =
  ## Resolver for `ValueCursor.probe`'s env tier -- see architecture.md's
  ## "Env var mechanics".
  let envName = arg.envName
  if envName.len == 0 or not existsEnv(envName):
    none(seq[string])
  else:
    some(splitEnvValue(getEnv(envName), arg.envDelim, spec.settings.envDelim))

proc resolveConfig(arg: Arg, spec: Spec): options.Option[seq[string]] =
  ## Resolver for `ValueCursor.probe`'s Config Source tier -- see
  ## `docs/adr/0018-config-source.md`.
  let key = arg.configKey
  if key.len == 0:
    none(seq[string])
  else:
    lookupConfigSources(spec.settings.configSources, key)

proc probe(cursor: var ValueCursor, arg: Arg, resolve: proc (): options.Option[seq[string]]): bool =
  ## Lets a fallback tier's value stand in for a missing CLI value during
  ## the walk -- see `ValueCursor`. `resolve` is called at most once per
  ## `arg` for the life of `cursor` (see `ValueCursor.tried`). Returning
  ## `false` just lets the walk fail normally; the actual value-setting
  ## happens later, in `applyFallbacks`'s post-walk sweep.
  if arg notin cursor.tried:
    cursor.tried.incl arg
    let found = resolve()
    if found.isSome:
      cursor.values[arg] = found.get
  if arg notin cursor.values:
    return false
  let consumed = cursor.consumed.getOrDefault(arg, 0)
  if consumed < cursor.values[arg].len:
    cursor.consumed[arg] = consumed + 1
    return true

proc match(m: Matcher, pc: var ParseContext): bool =
  ## Checks if `m` matches a token in `tokens`. May consume a token and may add
  ## a variant and value to `matches`. Returns whether the match was successful.
  case m.kind:
  of Shortcut:
    # A shortcut consumes no tokens and always indicates success.
    result = true
  of OptsEnd:
    # Always matches, forcing pc.optsEnd regardless of whether a literal
    # `--` is actually there to consume -- see ADR 0020.
    if pc.tokens.len > 0:
      discard pc.consumeOptsEnd(0)
    pc.optsEnd = true
    result = true
  of Argument:
    # Skip Option/Flag-classified tokens (order-independent -- see ADR
    # 0019). A Command-classified token is accepted as literal text just
    # like a Positional one -- the scan must not skip past it looking
    # further ahead, see ADR 0019 point 6 on why that breaks ordering.
    var pos = 0
    while pos < pc.tokens.len:
      if pc.consumeOptsEnd(pos):
        continue
      let c = classify(pc.spec, pc.tokens, pos, pc.optsEnd)
      case c.kind
      of Positional, Command:
        pc.matches.push(m.arg, pc.spec, m.arg.name, pc.tokens[pos].raw)
        pc.consume(pos, c)
        result = true
        break
      else:
        pos.inc
    if not result and pc.matches.getOrDefault(m.arg).len == 0:
      # Only report a genuinely-unmatched arg -- if this arg already matched
      # at least once (a satisfied `<arg>...` repeat), a failed attempt at
      # *another* repeat isn't a real deficiency worth reporting.
      pc.messages.add ("missing argument", m.arg.name)
  of Command:
    # If the next token classifies as this specific command, consume it and
    # return true. Otherwise return false -- a Command matcher never scans
    # past position 0 (see `docs/architecture.md`).
    if pc.tokens.len > 0 and not pc.consumeOptsEnd(0):
      let c = classify(pc.spec, pc.tokens, 0, pc.optsEnd)
      if c.kind == Command and c.cmd == m.cmd:
        pc.matches.push(m.cmd, pc.spec, c.cmdName)
        pc.command = fmt"{pc.command} {c.cmdName}"
        pc.spec = m.cmd.spec
        pc.consume(0, c)
        result = true
    if not result:
      pc.messages.add ("missing command", m.cmd.name)
  of Option:
    # Skip tokens that don't classify as *this* opt so option/arg order
    # doesn't matter -- see the Argument branch above on why a
    # Command-classified token doesn't need special-casing here either.
    var pos = 0
    while pos < pc.tokens.len:
      if pc.consumeOptsEnd(pos):
        continue
      let c = classify(pc.spec, pc.tokens, pos, pc.optsEnd)
      case c.kind
      of Optional:
        if c.opt == m.opt:
          pc.matches.push(c.opt, pc.spec, c.optName, c.optVal)
          pc.consume(pos, c)
          return true
      of Flag:
        if c.flag == m.opt:
          pc.matches.push(c.flag, pc.spec, c.flagName)
          pc.consume(pos, c)
          return true
      else:
        discard
      pos.inc

    # No CLI token matched; let the configured env var, then a Config
    # Source, stand in instead -- see architecture.md's "Env var
    # mechanics" and `docs/adr/0018-config-source.md`. `spec` is copied
    # out to a local `let` first -- the closures below can't capture `pc`
    # itself (a `var ParseContext` parameter) without violating memory
    # safety.
    let spec = pc.spec
    if pc.env.probe(m.opt, () => resolveEnv(m.opt, spec)):
      return true
    if pc.configValues.probe(m.opt, () => resolveConfig(m.opt, spec)):
      return true

    pc.messages.add ("missing option", m.opt.name)
    # Did-you-mean suggestion for an unresolved option-shaped leftover --
    # see ADR 0019 point 4 on why this lives here, not in tokenization.
    if pc.tokens.len > 0 and pc.tokens[0].optShape and
        classify(pc.spec, pc.tokens, 0, pc.optsEnd).kind == Positional:
      pc.messages.add ("unexpected option", unknownOptionMsg(pc.tokens[0].raw, pc.spec))
  of Options:
    # Try each option in m.opts (see ADR 0002 for the catch-all repeat rule).
    for opt in m.opts:
      # Probe only -- a failed probe's own message isn't user-facing, so
      # roll pc.messages back and add our own complaint instead.
      let before = pc.messages.len
      if newOptMatcher(opt).match(pc):
        result = true
      else:
        pc.messages.setLen(before)
        if not result: pc.messages.add ("missing option", opt.name)

proc walk(s: State, pc: var ParseContext): bool =
  ## Recursively matches each transition in `s` until a terminal state is
  ## reached or all branches have been tried. Returns `true` if a terminal state
  ## was reached. Matched values may be stored in `pc` by matchers.
  if s.terminal and pc.tokens.len == 0:
    return true

  # Try each transition. If it matches, recursively descend into the next state.
  for idx, tr in s.transitions:
    var fresh = pc
    if tr.matcher.match(fresh):
      fresh.depth.inc
      fresh.messages = @[]
      if tr.next.walk(fresh):
        pc = fresh
        return true
      elif tr.next.terminal and fresh.tokens.len > 0 and pc.messages.len == 0:
        # Word the complaint from classify()'s best-effort answer now that
        # nothing claimed this token -- see ADR 0019.
        let c = classify(fresh.spec, fresh.tokens, 0, fresh.optsEnd)
        case c.kind
        of Command:
          fresh.messages.add ("unexpected command", c.cmdName)
        of Flag:
          fresh.messages.add ("unexpected flag", c.flagName)
        of Optional:
          fresh.messages.add ("unexpected option", fmt"{c.optName}{c.optSep}{c.optVal}")
        of Positional:
          if fresh.tokens[0].optShape:
            fresh.messages.add ("unexpected option", unknownOptionMsg(fresh.tokens[0].raw, fresh.spec))
          else:
            fresh.messages.add ("unexpected argument", c.argVal)

    if fresh.depth >= pc.maxDepth or pc.messages.len == 0:
      pc.maxDepth = fresh.depth
      pc.errorSpec = fresh.spec
      pc.messages = fresh.messages
      pc.errorCommand = fresh.command

type
  Frontier = seq[tuple[state: State, pc: ParseContext]]
    ## Every `State` simultaneously still reachable after consuming a given
    ## prefix of tokens, paired with the `ParseContext` that reached it --
    ## see `collectFrontier`.

proc collectFrontier(s: State, pc: ParseContext, acc: var Frontier, seen: var HashSet[State]) =
  ## Generalizes `walk` into "every live branch, not just the first to
  ## succeed" for shell completion -- see architecture.md §6.
  ##
  ## `seen` only bounds zero-token transitions (a `Shortcut`, or an
  ## env-satisfied `Option`); anything that consumes a real token recurses
  ## with a fresh `seen`, since that's a strictly smaller sub-problem.
  ## Revisiting a `State` within one zero-token layer can't discover
  ## anything new, since its transitions and `pc.tokens` are unchanged --
  ## so skipping it is safe, not just an optimization.
  if s in seen:
    return
  seen.incl s

  if pc.tokens.len == 0:
    acc.add (s, pc)

  for tr in s.transitions:
    var fresh = pc
    if tr.matcher.match(fresh):
      if fresh.tokens.len < pc.tokens.len:
        var freshSeen: HashSet[State]
        collectFrontier(tr.next, fresh, acc, freshSeen)
      else:
        collectFrontier(tr.next, fresh, acc, seen)

proc bareVariants(spec: Spec, arg: Arg): seq[string] =
  ## The bare option/flag spellings actually typed on the command line for
  ## `arg` (e.g. "--log-level", never "--log-level=<level>"). Reads
  ## `spec.options`, the same canonical bare-name -> Arg map `classify`
  ## itself looks up against, rather than re-deriving stripping logic from
  ## `arg.variants` -- for an Optional-kind `ValueArg` (`opt`/`args`),
  ## `variants` stores the *declared* string verbatim, including any
  ## `=<placeholder>` suffix used only for help-text rendering (`FlagArg`
  ## already stores bare names at construction time, so this is a no-op for
  ## it, but reusing one rule for both is simpler than branching by kind).
  for k, v in spec.options:
    if v == arg: result.add k

proc candidateWords(frontier: Frontier, prefix: string): seq[string] =
  ## Reads every live frontier state's own outgoing transitions for literal
  ## next-word spellings (option/flag variants, command variants, or an
  ## enumerable positional's `completions()`), keeping only ones starting
  ## with `prefix` and deduplicating while preserving first-seen (== FSM
  ## priority/declaration) order.
  for (state, pc) in frontier:
    for tr in state.transitions:
      let candidates =
        case tr.matcher.kind
        of Option: pc.spec.bareVariants(tr.matcher.opt)
        of Options:
          collect:
            for opt in tr.matcher.opts:
              for v in pc.spec.bareVariants(opt): v
        of Command: tr.matcher.cmd.variants
        of Argument: tr.matcher.arg.completions()
        of OptsEnd: newSeq[string]() # invisible -- see ADR 0020 point 8
        of Shortcut: newSeq[string]()
      for c in candidates:
        if c.startsWith(prefix) and c notin result:
          result.add c

proc pendingOptionalArgs(frontier: Frontier, name: string): seq[Arg] =
  ## Every distinct `Optional`-kind (value-taking, not `Flag`) Arg reachable
  ## from a live frontier state whose variants include `name` exactly --
  ## used by `completeArgs` to detect "the last already-typed word is itself
  ## a bare option name still awaiting its value" (e.g. `--log-level` typed
  ## with nothing after it yet).
  var seenArgs: HashSet[Arg]
  for (state, pc) in frontier:
    for tr in state.transitions:
      var candidates: seq[Arg]
      case tr.matcher.kind
      of Option: candidates = @[tr.matcher.opt]
      of Options: candidates = tr.matcher.opts
      else: discard
      for arg in candidates:
        if arg.kind == Optional and name in pc.spec.bareVariants(arg) and arg notin seenArgs:
          seenArgs.incl arg
          result.add arg

proc completeArgs*(spec: Spec, words: seq[string], command: string): seq[string] =
  ## Returns shell-completion candidates for `words` -- everything typed
  ## after the `__complete` marker (see `parse*`). The last element of
  ## `words` is the word currently being completed (possibly `""` if the
  ## cursor follows a space with nothing typed for this word yet); every
  ## earlier element is already complete. Never raises -- an unparseable
  ## prefix simply yields no candidates (`collectFrontier` just finds no
  ## live transitions for it), leaving the shell's own file-completion
  ## fallback to take over. See `docs/adr/0012-fsm-driven-shell-completion.md`.
  let wordBeingCompleted = if words.len > 0: words[^1] else: ""
  let priorWords = if words.len > 0: words[0 ..< words.high] else: newSeq[string]()

  # Case (b): last word is a bare option name awaiting its value --
  # short-circuit to that Arg's completions() (see architecture.md §6).
  if priorWords.len > 0:
    let committed = priorWords[0 ..< priorWords.high]
    var frontier: Frontier
    var seen: HashSet[State]
    var pc = ParseContext(spec: spec, command: command, tokens: tokenizeArgs(committed))
    collectFrontier(spec.fsm, pc, frontier, seen)
    let pending = frontier.pendingOptionalArgs(priorWords[^1])
    if pending.len > 0:
      for arg in pending:
        for c in arg.completions():
          if c.startsWith(wordBeingCompleted) and c notin result:
            result.add c
      return result

  # Case (a): ordinary "what word can come next" completion.
  var frontier: Frontier
  var seen: HashSet[State]
  var pc = ParseContext(spec: spec, command: command, tokens: tokenizeArgs(priorWords))
  collectFrontier(spec.fsm, pc, frontier, seen)
  result = frontier.candidateWords(wordBeingCompleted)

proc parseOwnValues(spec: Spec, matches: MatchTable, command: string) =
  ## Parses every non-Command, non-MessageArg match belonging to `spec`'s
  ## own level (per `Match.spec` provenance -- see `push`). Commands are
  ## left for `dispatch`; MessageArgs are left for `parseMessageArgs`, which
  ## runs after `before` -- see
  ## `docs/adr/0009-command-before-action-after-hooks.md`.
  for arg in spec.args:
    if arg.kind == Command or arg of MessageArg:
      continue
    for (variant, value, matchSpec) in matches.getOrDefault(arg):
      if matchSpec != spec:
        continue
      arg.parse(value, variant)

proc parseMessageArgs(spec: Spec, matches: MatchTable, command: string) =
  ## Parses (and raises on) any matched MessageArg/HelpArg at `spec`'s own
  ## level. Called after `before`, inside `dispatch`'s try/finally, so a
  ## `before`-time mutation is visible in this level's own message/help
  ## output, and `after` still fires as a guaranteed cleanup even though
  ## this raises instead of returning.
  for arg in spec.args:
    if not (arg of MessageArg):
      continue
    for (variant, value, matchSpec) in matches.getOrDefault(arg):
      if matchSpec != spec:
        continue
      if arg of HelpArg:
        arg.parse(command, spec, variant)
      else:
        arg.parse(value, variant)

proc matchedCommand(spec: Spec, matches: MatchTable): tuple[cmd: CommandArg, variant: string] =
  ## The Command actually matched at this spec's own level for this
  ## invocation, if any -- `cmd` is nil if this spec is the dynamic leaf.
  ## At most one Command can ever be matched per spec level: `match`'s own
  ## `Command` branch permanently reassigns `pc.spec` to the matched
  ## command's own nested spec, so a sibling command word can never be
  ## recognized afterward.
  for arg in spec.args:
    if arg.kind != Command:
      continue
    let cmd = CommandArg(arg)
    for (variant, _, matchSpec) in matches.getOrDefault(cmd):
      if matchSpec == spec:
        return (cmd, variant)

proc dispatch(spec: Spec, matches: MatchTable, command: string) =
  ## Recursively dispatches `spec` and, if a Command was matched at its own
  ## level, whichever nested spec that routes to -- firing `before`/
  ## `action`/`after` per `docs/adr/0009-command-before-action-after-hooks.md`.
  parseOwnValues(spec, matches, command)
  if not spec.before.isNil:
    spec.before()
  try:
    parseMessageArgs(spec, matches, command)
    let (cmd, variant) = matchedCommand(spec, matches)
    if cmd.isNil:
      if not spec.action.isNil:
        spec.action()
    else:
      dispatch(cmd.spec, matches, "{command} {variant}".fmt)
  finally:
    if not spec.after.isNil:
      spec.after()

proc formatComplaints(messages: seq[Complaint]): string =
  ## Groups same-kind complaints (e.g. two unmatched commands) into one line
  ## joined by " | ".
  var subjectsByKind = initOrderedTable[string, seq[string]]()
  for (kind, subject) in messages:
    if subject notin subjectsByKind.getOrDefault(kind, @[]):
      subjectsByKind.mgetOrPut(kind, @[]).add subject
  for kind, subjects in subjectsByKind.pairs:
    let joined = subjects.join(" | ")
    let subject = if subjects.len > 1: "({joined})".fmt else: joined
    result.add "\n  - {kind}: {subject}".fmt

proc applyTier(cursor: ValueCursor, arg: Arg, resolve: proc (): options.Option[seq[string]],
    setValue: proc (values: seq[string]), complaints: var seq[Complaint]): bool =
  ## Applies one Value Precedence fallback tier's contribution to `arg` in
  ## `applyFallbacks`'s post-walk sweep, mirroring `probe`'s own
  ## consumption-count semantics: if the walk actually visited `arg`'s
  ## matcher and pulled values from this tier (`arg in cursor.consumed`),
  ## apply everything the tier had available, or complain if the walk
  ## didn't consume all of it (more values than the grammar had positions
  ## for). If the matcher was visited but `resolve` found nothing (`arg in
  ## cursor.tried` but not `cursor.consumed`), there's nothing to apply --
  ## and, per `ValueCursor.tried`'s own contract, `resolve` must not be
  ## called again here even though it would return the same answer, since
  ## it may be an arbitrarily expensive user-supplied `ConfigSource.lookup`.
  ## Only when the matcher was never visited at all this walk (reachable
  ## only via a different, unmatched Usage Line -- `arg notin cursor.tried`)
  ## does this resolve fresh and apply every available value. Returns
  ## whether this tier had anything at all for `arg` -- a real application,
  ## or an oversupply complaint -- telling the caller whether to fall
  ## through to the next-lower tier.
  if arg in cursor.consumed:
    result = true
    let consumed = cursor.consumed[arg]
    let total = cursor.values[arg].len
    if consumed < total:
      let kind = if arg.kind == Flag: "unexpected flag" else: "unexpected option"
      complaints.add (kind, arg.name)
    else:
      setValue(cursor.values[arg])
  elif arg notin cursor.tried:
    let found = resolve()
    if found.isSome:
      result = true
      setValue(found.get)

proc applyFallbacks(env, configValues: var ValueCursor, spec: Spec, matches: MatchTable,
    seen: var HashSet[Arg], complaints: var seq[Complaint]) =
  ## Recurses through every spec level actually entered during this parse
  ## (mirroring `dispatch`'s own recursion -- see architecture.md §5),
  ## falling back to each unmatched Arg's env var, then (only if env had
  ## nothing) its Config Source value. Deliberately outside `walk`'s
  ## FSM/backtracking, so an Arg only reachable via `[options]` still
  ## picks up its fallback values -- see architecture.md's "Env var
  ## mechanics", `docs/adr/0005-env-supplied-multi-value-options-and-
  ## flags.md`, and `docs/adr/0018-config-source.md` for the
  ## value-count/`ParseError` rules, shared identically by both tiers.
  ##
  ## `seen` guards against double-applying an Arg reachable from more than
  ## one spec level: unlike a real CLI match (tagged per-level via `push`'s
  ## `Match.spec`), a fallback-driven `setFromEnv`/`setFromConfig` call
  ## carries no such tagging to dedupe on otherwise.
  ##
  ## Runs to completion (or raises) entirely before `dispatch` is called --
  ## so a fallback problem at any level blocks every level's hooks from
  ## firing at all, not just that level's, since `dispatch` never starts.
  for a in spec.args:
    let arg = a # local copy -- a `for` loop's `lent Arg` can't be captured by the closures below
    if arg in seen or arg in matches:
      continue
    seen.incl(arg)
    let envHad = applyTier(env, arg, () => resolveEnv(arg, spec),
      proc (values: seq[string]) = arg.setFromEnv(values), complaints)
    if not envHad:
      discard applyTier(configValues, arg, () => resolveConfig(arg, spec),
        proc (values: seq[string]) = arg.setFromConfig(values), complaints)

  let (cmd, _) = matchedCommand(spec, matches)
  if not cmd.isNil:
    applyFallbacks(env, configValues, cmd.spec, matches, seen, complaints)

proc parse*(spec: Spec, args: seq[string] = commandLineParams(),
    command = extractFilename(getAppFilename())) =
  ## Creates an FSM for `spec` and attempts to navigate it using `args`. If a
  ## terminal state was reached and all args were consumed, the parse was
  ## successful and each match is parsed into its arg. Raises `ParseError`,
  ## `ValidationError`, `HelpError`, `MessageError`, or `CompletionError` on
  ## failure -- use `parseOrQuit*` (`argumint.nim`) if you want those to
  ## print a message and `quit()` instead.
  ##
  ## `args[0] == "__complete"` is a shell-completion request (see
  ## `docs/adr/0012-fsm-driven-shell-completion.md`): short-circuits before
  ## any real FSM matching, env fallback, or dispatch (so no `before`/
  ## `action`/`after` hook fires), raising `CompletionError` with the
  ## newline-joined candidates as its `msg`.
  if args.len > 0 and args[0] == "__complete":
    raise newException(CompletionError, spec.completeArgs(args[1 ..< args.len], command).join("\n"))

  var pc = ParseContext(spec: spec, command: command, errorSpec: spec, errorCommand: command,
    tokens: tokenizeArgs(args))
  if not spec.fsm.walk(pc):
    raiseParseError(formatComplaints(pc.messages), pc.errorCommand, pc.errorSpec)

  var fallbackComplaints: seq[Complaint]
  var fallbackSeen: HashSet[Arg]
  applyFallbacks(pc.env, pc.configValues, spec, pc.matches, fallbackSeen, fallbackComplaints)
  if fallbackComplaints.len > 0:
    raiseParseError(formatComplaints(fallbackComplaints), pc.command, pc.spec)

  dispatch(spec, pc.matches, command)

when isMainModule:
  import std/unittest

  type
    TestArg = ref object of Arg
      ## A minimal concrete Arg for exercising ValueCursor.probe/
      ## applyFallbacks directly, without going through argumint.nim's
      ## ValueArg/FlagArg (which import this module, so the reverse import
      ## isn't available here).
      env: string
      delim: options.Option[string]
      cfg: ConfigKey
      recorded: seq[string]
      configRecorded: seq[string]

    FakeSource = ref object of ConfigSource
      data: seq[(ConfigKey, seq[string])]

    CountingSource = ref object of ConfigSource
      ## Counts `lookup` calls, to verify `ValueCursor.probe` only ever
      ## resolves once per Arg even across several `probe` calls.
      lookups: int

  method envName(self: TestArg): string = self.env
  method envDelim(self: TestArg): options.Option[string] = self.delim
  method setFromEnv(self: TestArg, values: seq[string]) =
    self.recorded = values
  method configKey(self: TestArg): ConfigKey = self.cfg
  method setFromConfig(self: TestArg, values: seq[string]) =
    self.configRecorded = values

  method lookup(self: FakeSource, key: ConfigKey): options.Option[seq[string]] =
    for (k, v) in self.data:
      if k == key:
        return some(v)
    none(seq[string])

  method lookup(self: CountingSource, key: ConfigKey): options.Option[seq[string]] =
    self.lookups.inc
    some(@["x"])

  proc newTestArg(name: string, env = "", delim = none(string), cfg: ConfigKey = @[]): TestArg =
    TestArg(kind: Optional, variants: @[name], env: env, delim: delim, cfg: cfg)

  proc specWithConfig(sources: seq[ConfigSource] = @[], args: seq[Arg] = @[]): Spec =
    Spec(settings: SpecSettings(envDelim: ":", configSources: sources), args: args)

  suite "ValueCursor.probe (env tier)":
    test "false when the arg has no env var configured":
      var cursor: ValueCursor
      let arg = newTestArg("--foo")
      let spec = specWithConfig()
      check not cursor.probe(arg, () => resolveEnv(arg, spec))

    test "false when the configured env var isn't set":
      delEnv("ARGUMINT_TEST_UNSET")
      var cursor: ValueCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_UNSET")
      let spec = specWithConfig()
      check not cursor.probe(arg, () => resolveEnv(arg, spec))

    test "hands out a single value once, then reports exhausted":
      putEnv("ARGUMINT_TEST_SINGLE", "hello")
      defer: delEnv("ARGUMINT_TEST_SINGLE")
      var cursor: ValueCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_SINGLE")
      let spec = specWithConfig()
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check not cursor.probe(arg, () => resolveEnv(arg, spec))

    test "hands out each delimiter-split value in order":
      putEnv("ARGUMINT_TEST_MULTI", "a:b:c")
      defer: delEnv("ARGUMINT_TEST_MULTI")
      var cursor: ValueCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_MULTI")
      let spec = specWithConfig()
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check not cursor.probe(arg, () => resolveEnv(arg, spec))

    test "a per-arg delim override is used instead of Spec.settings.envDelim":
      putEnv("ARGUMINT_TEST_OVERRIDE", "a;b;c")
      defer: delEnv("ARGUMINT_TEST_OVERRIDE")
      var cursor: ValueCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_OVERRIDE", some(";"))
      let spec = specWithConfig()
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check not cursor.probe(arg, () => resolveEnv(arg, spec))

    test "an empty per-arg delim override means the whole value is a single element":
      putEnv("ARGUMINT_TEST_NOSPLIT", "a:b")
      defer: delEnv("ARGUMINT_TEST_NOSPLIT")
      var cursor: ValueCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_NOSPLIT", some(""))
      let spec = specWithConfig()
      check cursor.probe(arg, () => resolveEnv(arg, spec))
      check not cursor.probe(arg, () => resolveEnv(arg, spec))

  suite "ValueCursor.probe (config tier)":
    test "false when the arg has no config key configured":
      var cursor: ValueCursor
      let arg = newTestArg("--foo")
      let spec = specWithConfig(@[ConfigSource FakeSource(data: @[(configKey("foo"), @["x"])])])
      check not cursor.probe(arg, () => resolveConfig(arg, spec))

    test "false when no configured source has the key":
      var cursor: ValueCursor
      let arg = newTestArg("--foo", cfg = configKey("foo"))
      let spec = specWithConfig(@[ConfigSource FakeSource(data: @[])])
      check not cursor.probe(arg, () => resolveConfig(arg, spec))

    test "hands out each value in order, then reports exhausted":
      var cursor: ValueCursor
      let arg = newTestArg("--foo", cfg = configKey("foo"))
      let spec = specWithConfig(@[ConfigSource FakeSource(data: @[(configKey("foo"), @["a", "b"])])])
      check cursor.probe(arg, () => resolveConfig(arg, spec))
      check cursor.probe(arg, () => resolveConfig(arg, spec))
      check not cursor.probe(arg, () => resolveConfig(arg, spec))

    test "a later source's hit fully replaces an earlier one's":
      var cursor: ValueCursor
      let arg = newTestArg("--foo", cfg = configKey("foo"))
      let spec = specWithConfig(@[
        ConfigSource FakeSource(data: @[(configKey("foo"), @["a", "b"])]),
        ConfigSource FakeSource(data: @[(configKey("foo"), @["c"])]),
      ])
      check cursor.probe(arg, () => resolveConfig(arg, spec))
      check not cursor.probe(arg, () => resolveConfig(arg, spec))

    test "resolve runs at most once per arg, even across several probes":
      var cursor: ValueCursor
      let arg = newTestArg("--foo", cfg = configKey("foo"))
      let source = CountingSource()
      let spec = specWithConfig(@[ConfigSource source])
      check cursor.probe(arg, () => resolveConfig(arg, spec))
      check not cursor.probe(arg, () => resolveConfig(arg, spec))
      check source.lookups == 1

  suite "applyFallbacks (env tier)":
    test "sets an unconsulted arg's value directly from env":
      putEnv("ARGUMINT_TEST_DIRECT", "hi")
      defer: delEnv("ARGUMINT_TEST_DIRECT")
      let arg = newTestArg("--foo", "ARGUMINT_TEST_DIRECT")
      let spec = specWithConfig(args = @[Arg arg])
      var env, configValues: ValueCursor
      var matches: MatchTable
      var seen: HashSet[Arg]
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, seen, complaints)
      check complaints.len == 0
      check arg.recorded == @["hi"]

    test "applies every split value once the walk fully consumed them":
      putEnv("ARGUMINT_TEST_CONSUMED", "a:b")
      defer: delEnv("ARGUMINT_TEST_CONSUMED")
      let arg = newTestArg("--foo", "ARGUMINT_TEST_CONSUMED")
      let spec = specWithConfig(args = @[Arg arg])
      var env, configValues: ValueCursor
      check env.probe(arg, () => resolveEnv(arg, spec))
      check env.probe(arg, () => resolveEnv(arg, spec))
      var matches: MatchTable
      var seen: HashSet[Arg]
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, seen, complaints)
      check complaints.len == 0
      check arg.recorded == @["a", "b"]

    test "complains about env values the walk didn't consume":
      putEnv("ARGUMINT_TEST_LEFTOVER", "a:b:c")
      defer: delEnv("ARGUMINT_TEST_LEFTOVER")
      let arg = newTestArg("--foo", "ARGUMINT_TEST_LEFTOVER")
      let spec = specWithConfig(args = @[Arg arg])
      var env, configValues: ValueCursor
      discard env.probe(arg, () => resolveEnv(arg, spec)) # consumes only 1 of the 3 available values
      var matches: MatchTable
      var seen: HashSet[Arg]
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, seen, complaints)
      check complaints == @[("unexpected option", arg.name)]

    test "skips an arg already explicitly matched on the command line":
      putEnv("ARGUMINT_TEST_SKIP", "hi")
      defer: delEnv("ARGUMINT_TEST_SKIP")
      let arg = newTestArg("--foo", "ARGUMINT_TEST_SKIP")
      let spec = specWithConfig(args = @[Arg arg])
      var env, configValues: ValueCursor
      var matches: MatchTable
      matches[Arg arg] = @[(variant: "--foo", value: "explicit", spec: spec)]
      var seen: HashSet[Arg]
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, seen, complaints)
      check complaints.len == 0
      check arg.recorded.len == 0

  suite "applyFallbacks (config tier)":
    test "sets an unconsulted arg's value directly from a Config Source":
      let arg = newTestArg("--foo", cfg = configKey("foo"))
      let source = FakeSource(data: @[(configKey("foo"), @["hi"])])
      let spec = specWithConfig(@[ConfigSource source], args = @[Arg arg])
      var env, configValues: ValueCursor
      var matches: MatchTable
      var seen: HashSet[Arg]
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, seen, complaints)
      check complaints.len == 0
      check arg.configRecorded == @["hi"]

    test "complains about config values the walk didn't consume":
      let arg = newTestArg("--foo", cfg = configKey("foo"))
      let source = FakeSource(data: @[(configKey("foo"), @["a", "b", "c"])])
      let spec = specWithConfig(@[ConfigSource source], args = @[Arg arg])
      var env, configValues: ValueCursor
      discard configValues.probe(arg, () => resolveConfig(arg, spec)) # consumes only 1 of 3
      var matches: MatchTable
      var seen: HashSet[Arg]
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, seen, complaints)
      check complaints == @[("unexpected option", arg.name)]

    test "env present takes precedence, config is never consulted":
      putEnv("ARGUMINT_TEST_PRECEDENCE", "from-env")
      defer: delEnv("ARGUMINT_TEST_PRECEDENCE")
      let arg = newTestArg("--foo", "ARGUMINT_TEST_PRECEDENCE", cfg = configKey("foo"))
      let source = FakeSource(data: @[(configKey("foo"), @["from-config"])])
      let spec = specWithConfig(@[ConfigSource source], args = @[Arg arg])
      var env, configValues: ValueCursor
      var matches: MatchTable
      var seen: HashSet[Arg]
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, seen, complaints)
      check arg.recorded == @["from-env"]
      check arg.configRecorded.len == 0

    test "falls through to config when env is unset":
      let arg = newTestArg("--foo", "ARGUMINT_TEST_ABSENT", cfg = configKey("foo"))
      let source = FakeSource(data: @[(configKey("foo"), @["from-config"])])
      let spec = specWithConfig(@[ConfigSource source], args = @[Arg arg])
      var env, configValues: ValueCursor
      var matches: MatchTable
      var seen: HashSet[Arg]
      var complaints: seq[Complaint]
      applyFallbacks(env, configValues, spec, matches, seen, complaints)
      check complaints.len == 0
      check arg.recorded.len == 0
      check arg.configRecorded == @["from-config"]
