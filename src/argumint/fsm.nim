## This module handles the navigation of the FSM based on a set of provided
## command-line arguments.
import std/[editdistance, os, pegs, sets, strformat, strutils, sugar, tables]

import ./[backend, parser]
export ParseError, SpecDefect, CompletionError


type
  Match = tuple[variant: string, value: string, spec: Spec]
  MatchTable = OrderedTable[Arg, seq[Match]]
  Complaint = tuple[kind: string, subject: string]
    ## A failure reason, e.g. `("missing option", "-v")`. Kept structured
    ## (rather than a pre-formatted string) so same-kind complaints can be
    ## grouped into one message at render time -- see `parse`.

  EnvCursor = object
    ## Owns Value Precedence's environment-variable tier: for each Arg with
    ## an env var configured, the raw value already split via
    ## `splitEnvValue` (cached the first time `probe` consults it during a
    ## walk) and a cursor into how many of those values have already been
    ## handed out as a virtual match -- not a one-shot flag, so an Arg
    ## matched more than once (a real repeat, or simply named more than
    ## once in one Usage Line) can have each occurrence satisfied by a
    ## *different* value from the same env var. Whether an Arg's position
    ## gets consulted once or several times is never decided here -- it
    ## falls out of however many times `walk` actually visits this
    ## matcher, driven entirely by the FSM already built from the Usage
    ## String. See `docs/adr/0005-env-supplied-multi-value-options-and-
    ## flags.md`.
    values: Table[Arg, seq[string]]
    consumed: Table[Arg, int]

  ParseContext = object
    depth: int            ## The depth of the current fsm path
    maxDepth: int         ## The depth of the deepest fsm path prior to the current one
    spec: Spec            ## The spec for the parsed command (used to generate usage and help messages)
    command: string       ## The command string up to the current subcommand
    messages: seq[Complaint] ## A list of complaints indicating failure reason of the deepest fsm path
    tokens: seq[CmdLineToken]     ## The arguments left to be parsed
    matches: MatchTable   ## A table of processed matches
    env: EnvCursor        ## Value Precedence's environment-variable tier -- see `EnvCursor`

  CmdLineToken = object
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

proc tokenizeArgs(spec: Spec, args: seq[string], command: string, start = 0): seq[CmdLineToken] =
  ## Parses `args` into a series of `CmdLineToken`s that can be acted on by the
  ## FSM navigator. In the case of an unrecognized command or option or a
  ## non-flag option that is missing a value, a `ParseError` is thrown.
  var
    pos = start
    optsEnd = false

  while pos < args.len:
    # `--` signals the end of options and commands; everything else will be
    # treated as an argument.
    if args[pos] == "--" and not optsEnd:
      optsEnd = true
    elif optsEnd:
      result.add CmdLineToken(kind: Positional, argVal: args[pos])
    # Check if it's a known command
    elif args[pos] in spec.commands:
      let
        variant = args[pos]
        cmd = spec.commands[variant]
      result.add CmdLineToken(kind: Command, cmd: cmd, cmdName: variant)
      for token in tokenizeArgs(cmd.spec, args, fmt"{command} {variant}", pos + 1):
        result.add token
      return
    # Check for `-o` or `--option`
    elif args[pos] =~ OptionFormat:
      let variant = args[pos]
      if variant in spec.options:
        let option = spec.options[variant]
        case option.kind
        of Flag:
          result.add CmdLineToken(kind: Flag, flag: option, flagName: variant)
        of Optional:
          pos.inc
          if pos >= args.len:
            raiseParseError(unknownOptionMsg(variant, spec), command, spec)
          result.add CmdLineToken(kind: Optional, opt: option, optName: variant, optVal: args[pos])
        else:
          assert false
      else:
        raiseParseError(unknownOptionMsg(variant, spec), command, spec)
    # Check for `-o=val` or `--option=value`
    elif args[pos] =~ OptionValueFormat:
      let
        variant = matches[0]
        sep = matches[1]
        value = matches[2]
      if variant notin spec.options:
        raiseParseError(unknownOptionMsg(variant, spec), command, spec)
      if spec.options[variant].kind != Optional:
        raiseParseError(fmt"{variant} cannot take a value", command, spec)
      result.add CmdLineToken(kind: Optional, opt: spec.options[variant], optName: variant, optVal: value, optSep: sep)
    # A leading `-` followed by more than one character that isn't itself a
    # long option is a cluster of short options (`-abc`), possibly folding a
    # value onto the last one (`-abo=value`, `-abovalue`).
    elif args[pos].len > 2 and args[pos][0] == '-' and args[pos][1] != '-':
      let cluster = args[pos]
      var idx = 1
      while idx < cluster.len:
        let variant = "-" & cluster[idx]
        if variant notin spec.options:
          raiseParseError(unknownOptionMsg(variant, spec), command, spec)
        let option = spec.options[variant]
        case option.kind
        of Flag:
          result.add CmdLineToken(kind: Flag, flag: option, flagName: variant)
          idx.inc
        of Optional:
          let folded = cluster.substr(idx + 1)
          if folded.len == 0:
            pos.inc
            if pos >= args.len:
              raiseParseError(fmt"missing value for {variant}", command, spec)
            result.add CmdLineToken(kind: Optional, opt: option, optName: variant, optVal: args[pos])
          elif fmt"{variant}{folded}" =~ OptionValueFormat:
            result.add CmdLineToken(kind: Optional, opt: option, optName: variant, optSep: matches[1], optVal: matches[2])
          else:
            result.add CmdLineToken(kind: Optional, opt: option, optName: variant, optVal: folded)
          break
        else: assert false
    # It must be a positional argument
    else:
      if spec.arguments.len == 0:
        raiseParseError(fmt"unexpected argument {args[pos]}", command, spec)
      result.add CmdLineToken(kind: Positional, argVal: args[pos])

    pos.inc

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

proc probe(cursor: var EnvCursor, arg: Arg, spec: Spec): bool =
  ## Lets `arg`'s configured env var stand in for a missing command-line
  ## value -- this is what lets a *required* (unbracketed) Option/Flag be
  ## satisfied by env: env is a per-Arg declaration, so it shouldn't behave
  ## differently depending on whether this particular Usage Line happens
  ## to require the Arg or not (see ADR 0004). Returning `false` and
  ## recording no match here just stops the walk itself from failing --
  ## the actual value-setting happens later, in `apply`'s post-walk sweep.
  ##
  ## The env var's value is always split (`splitEnvValue`) into however
  ## many values it supplies; `cursor.consumed` is a per-Arg cursor into
  ## that list rather than a one-shot flag, handing out the next
  ## unconsumed value each time this Arg's matcher is consulted here, and
  ## returning `false` (so the caller falls through to its own "missing
  ## option" complaint) once the list is exhausted -- the same outcome as
  ## running out of real CLI tokens for a repeatable position. See
  ## `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`.
  let envName = arg.envName
  if envName.len == 0 or not existsEnv(envName):
    return false
  if arg notin cursor.values:
    cursor.values[arg] = splitEnvValue(getEnv(envName), spec.envDelim)
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
  of Argument:
    # Iterate over tokens until either a Command token or a Positional token is
    # found. If a Positional token is found, consume it and return true. If a
    # Command token is found, set an error message and return false. All other
    # token types are skipped. This allows us to ignore option/argument order.
    var pos = 0
    while pos < pc.tokens.len:
      let token = pc.tokens[pos]
      case token.kind
      of Positional:
        pc.matches.push(m.arg, pc.spec, m.arg.name, token.argVal)
        pc.tokens.delete pos
        result = true
        break
      of Command:
        break
      else:
        discard
      pos.inc
    if not result and pc.matches.getOrDefault(m.arg).len == 0:
      # Only report a genuinely-unmatched arg -- if this arg already matched
      # at least once (a satisfied `<arg>...` repeat), a failed attempt at
      # *another* repeat isn't a real deficiency worth reporting.
      pc.messages.add ("missing argument", m.arg.name)
  of Command:
    # If the next token is a matching command token, consume it and return true.
    # Otherwise return false.
    if pc.tokens.len > 0:
      let token = pc.tokens[0]
      case token.kind
      of Command:
        if token.cmd == m.cmd:
          pc.matches.push(m.cmd, pc.spec, token.cmdName)
          pc.command = fmt"{pc.command} {token.cmdName}"
          pc.spec = m.cmd.spec
          pc.tokens.delete 0
          result = true
      else:
        discard
    if not result:
      pc.messages.add ("missing command", m.cmd.name)
  of Option:
    # Iterate over tokens until a matching Optional or Flag token is found,
    # consuming a matching token and returning true. If a Command token is found
    # before a matching Optional or Flag token, consume nothing and return
    # false. Positional tokens or non-matching Optional or Flag tokens are
    # skipped, allowing us to ignore the order of options and args.
    var pos = 0
    while pos < pc.tokens.len:
      let token = pc.tokens[pos]
      case token.kind
      of Optional:
        if token.opt == m.opt:
          pc.matches.push(token.opt, pc.spec, token.optName, token.optVal)
          pc.tokens.delete pos
          return true
      of Flag:
        if token.flag == m.opt:
          pc.matches.push(token.flag, pc.spec, token.flagName)
          pc.tokens.delete pos
          return true
      of Command:
        break
      else:
        discard
      pos.inc

    # No CLI token matched. Rather than failing outright, let this Arg's
    # configured env var stand in for a missing value here (see `probe`) --
    # consuming no token and not recording into `pc.matches` defers the
    # actual value-setting to `apply`'s post-walk sweep, which already runs
    # for any Arg that wasn't explicitly matched.
    if pc.env.probe(m.opt, pc.spec):
      return true

    pc.messages.add ("missing option", m.opt.name)
  of Options:
    # Iterate over all the matcher's options and try to match each of them using
    # the algorithm described above. Consume a token and return true when a
    # matching Optional or Flag token is found.
    # A repeated `[options]...` re-tries every option in `m.opts` on each
    # pass with no memory of prior matches -- so any option reachable only
    # through the catch-all can be matched more than once, governed purely
    # by whether the catch-all itself carries `...`. An author who wants a
    # specific option to stay single-match mentions it explicitly in `usage`
    # instead (without its own `...`); `collectExplicitOptions` then excludes
    # it from `m.opts` entirely, reverting it to the default one-shot rule.
    for opt in m.opts:
      # newOptMatcher(opt).match(pc) is used purely to probe this candidate;
      # a failed probe's own "missing option" complaint isn't meant to be
      # user-facing on its own, so roll pc.messages back to before the probe
      # and add our own complaint for it instead.
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
        let token = fresh.tokens[0]
        case token.kind
        of Command:
          fresh.messages.add ("unexpected command", token.cmdName)
        of Positional:
          fresh.messages.add ("unexpected argument", token.argVal)
        of Optional:
          fresh.messages.add ("unexpected option", fmt"{token.optName}{token.optSep}{token.optVal}")
        of Flag:
          fresh.messages.add ("unexpected flag", token.flagName)

    # a usage message to send to the parent's scope
    # echo fmt"{tr.matcher.name=}, {fresh.depth=}, {fresh.message=}, {pc.maxDepth=}"
    if fresh.depth >= pc.maxDepth or pc.messages.len == 0:
      pc.maxDepth = fresh.depth
      pc.spec = fresh.spec
      pc.messages = fresh.messages
      pc.command = fresh.command

type
  Frontier = seq[tuple[state: State, pc: ParseContext]]
    ## Every `State` simultaneously still reachable after consuming a given
    ## prefix of tokens, paired with the `ParseContext` that reached it --
    ## see `collectFrontier`.

proc collectFrontier(s: State, pc: ParseContext, acc: var Frontier, seen: var HashSet[State]) =
  ## Generalizes `walk`'s single-winner backtracking into "every live
  ## branch, not just the first to succeed" -- needed for shell completion,
  ## where several Usage Lines (or `choice` alternatives) can all still be
  ## viable at once for a command line that isn't finished yet. Reuses
  ## `Matcher.match` unmodified, so env-var fallback (`docs/adr/0004`,
  ## `docs/adr/0005`) applies here exactly as it would to a real parse.
  ##
  ## `seen` bounds the traversal of this otherwise-cyclic graph (`...`
  ## repetition, `[options]...`): it's only consulted/populated while
  ## consuming zero tokens (a `Shortcut`, or an env-satisfied `Option`) --
  ## any transition that actually consumes a real token recurses with a
  ## *fresh* `seen`, since that sub-problem is strictly smaller (bounded by
  ## how many tokens are left) and can't loop back into this one. Revisiting
  ## the same `State` within one zero-token layer can't discover anything
  ## new -- its own transitions are static, and matching them again against
  ## the same (unchanged, since nothing was consumed) `pc.tokens` reproduces
  ## the same outcome -- so it's safe to skip, not just an optimization.
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
  ## `spec.options`, the same canonical bare-name -> Arg map `tokenizeArgs`
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
  ## prefix simply yields no candidates, leaving the shell's own
  ## file-completion fallback to take over. See
  ## `docs/adr/0012-fsm-driven-shell-completion.md`.
  let wordBeingCompleted = if words.len > 0: words[^1] else: ""
  let priorWords = if words.len > 0: words[0 ..< words.high] else: newSeq[string]()

  # Case (b): is the last already-complete word itself a bare Optional-kind
  # option name still awaiting its value (`--log-level`, not
  # `--log-level=info`)? If so, don't try to tokenize it as a complete
  # token at all -- `tokenizeArgs` requires the *next* raw arg to already
  # supply that option's value, which isn't true here since this word is
  # the last one typed. Short-circuit straight to that Arg's own
  # `completions()` instead.
  if priorWords.len > 0:
    let committed = priorWords[0 ..< priorWords.high]
    var frontier: Frontier
    var seen: HashSet[State]
    try:
      var pc = ParseContext(spec: spec, command: command,
        tokens: spec.tokenizeArgs(committed, command))
      collectFrontier(spec.fsm, pc, frontier, seen)
    except ParseError:
      return @[]
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
  try:
    var pc = ParseContext(spec: spec, command: command,
      tokens: spec.tokenizeArgs(priorWords, command))
    collectFrontier(spec.fsm, pc, frontier, seen)
  except ParseError:
    return @[]
  result = frontier.candidateWords(wordBeingCompleted)

proc parseOwnValues(spec: Spec, matches: MatchTable, command: string) =
  ## Parses every non-Command match belonging to `spec`'s own level (per
  ## `Match.spec` provenance -- see `push`), leaving any Command matched
  ## at this level for `dispatch` to handle.
  for arg in spec.args:
    if arg.kind == Command:
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
  ## At most one Command can ever be matched per spec level: `tokenizeArgs`
  ## hands off every remaining token to a matched command's own nested
  ## spec permanently, so a sibling command word can never be recognized
  ## afterward.
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

proc apply(cursor: EnvCursor, spec: Spec, matches: MatchTable, seen: var HashSet[Arg],
    complaints: var seq[Complaint]) =
  ## Falls back to an environment variable for any of `spec`'s own args
  ## that has one configured and wasn't explicitly matched on the command
  ## line, then recurses into whichever nested spec was actually matched
  ## at this level (mirroring `parseOwnValues`/`matchedCommand` above) --
  ## so this reaches every spec level actually entered during this parse,
  ## not just the deepest one `walk` leaves `pc.spec` pointed at. See
  ## `docs/adr/0009-command-before-action-after-hooks.md` for the same
  ## per-level problem already solved for value-dispatch.
  ##
  ## This is deliberately outside the FSM/backtracking in `walk` -- it only
  ## ever sees typed tokens, and this way an arg only reachable via
  ## [options] still picks up its env var even though [options] itself was
  ## never explicitly attempted during matching. `arg notin matches` is
  ## exactly "wasn't explicitly typed", so an explicit CLI value always
  ## wins for free, no extra bookkeeping needed.
  ##
  ## `seen` guards against processing the same Arg twice: an Arg can
  ## deliberately be reachable from more than one spec level's grammar
  ## (see "the same Arg reachable at both an ancestor and a nested
  ## command's grammar..." below) -- unlike a real CLI match (tagged
  ## per-level via `push`'s `Match.spec`), an env-driven `setFromEnv` call
  ## has no such tagging, so without this guard a shared Arg's env var
  ## would be applied once per level it appears in.
  ##
  ## An Arg whose matcher was actually consulted during the walk
  ## (`arg in cursor.consumed`) gets exactly as many values applied as the
  ## walk consumed -- if the env var had more left over than the grammar
  ## had positions for, that's a ParseError rather than a silent
  ## truncation to a prefix of the values (see
  ## `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`). An Arg
  ## never consulted at all this walk (reachable only via a different,
  ## unmatched Usage Line of this same spec) has no walk-derived count to
  ## bound it by, so every available value is applied, generalizing the
  ## single-value fallback ADR 0004 already established for that case.
  ##
  ## This runs to completion (or raises) entirely before `dispatch` is
  ## ever called -- so no `before`/`action`/`after` hook anywhere fires
  ## until every level's env fallback is resolved. If an env problem
  ## exists at any level, no level's hooks fire at all (not even an
  ## ancestor's `before`, and thus not its `after` either), since no level
  ## ever gets far enough to run its own `before` in the first place --
  ## unlike a CLI- or validator-driven error occurring *during* dispatch,
  ## which unwinds through already-entered ancestors' `finally` blocks and
  ## so still runs their `after`.
  for arg in spec.args:
    let name = arg.envName
    if name.len == 0 or arg in seen or arg in matches or not existsEnv(name):
      continue
    seen.incl(arg)
    if arg in cursor.consumed:
      let consumed = cursor.consumed[arg]
      let total = cursor.values[arg].len
      if consumed < total:
        let kind = if arg.kind == Flag: "unexpected flag" else: "unexpected option"
        complaints.add (kind, arg.name)
      else:
        arg.setFromEnv(cursor.values[arg])
    else:
      arg.setFromEnv(splitEnvValue(getEnv(name), spec.envDelim))

  let (cmd, _) = matchedCommand(spec, matches)
  if not cmd.isNil:
    cursor.apply(cmd.spec, matches, seen, complaints)

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

  var pc = ParseContext(spec: spec, command: command, tokens: spec.tokenizeArgs(args, command))
  if not spec.fsm.walk(pc):
    raiseParseError(formatComplaints(pc.messages), pc.command, pc.spec)

  var envComplaints: seq[Complaint]
  var envSeen: HashSet[Arg]
  pc.env.apply(spec, pc.matches, envSeen, envComplaints)
  if envComplaints.len > 0:
    raiseParseError(formatComplaints(envComplaints), pc.command, pc.spec)

  dispatch(spec, pc.matches, command)

when isMainModule:
  import std/unittest

  type
    TestArg = ref object of Arg
      ## A minimal concrete Arg for exercising EnvCursor.probe/apply
      ## directly, without going through argumint.nim's ValueArg/FlagArg
      ## (which import this module, so the reverse import isn't available
      ## here).
      env: string
      recorded: seq[string]

  method envName(self: TestArg): string = self.env
  method setFromEnv(self: TestArg, values: seq[string]) =
    self.recorded = values

  proc newTestArg(name: string, env = ""): TestArg =
    TestArg(kind: Optional, variants: @[name], env: env)

  suite "EnvCursor.probe":
    test "false when the arg has no env var configured":
      var cursor: EnvCursor
      check not cursor.probe(newTestArg("--foo"), Spec(envDelim: ":"))

    test "false when the configured env var isn't set":
      delEnv("ARGUMINT_TEST_UNSET")
      var cursor: EnvCursor
      check not cursor.probe(newTestArg("--foo", "ARGUMINT_TEST_UNSET"), Spec(envDelim: ":"))

    test "hands out a single value once, then reports exhausted":
      putEnv("ARGUMINT_TEST_SINGLE", "hello")
      defer: delEnv("ARGUMINT_TEST_SINGLE")
      var cursor: EnvCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_SINGLE")
      let spec = Spec(envDelim: ":")
      check cursor.probe(arg, spec)
      check not cursor.probe(arg, spec)

    test "hands out each delimiter-split value in order":
      putEnv("ARGUMINT_TEST_MULTI", "a:b:c")
      defer: delEnv("ARGUMINT_TEST_MULTI")
      var cursor: EnvCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_MULTI")
      let spec = Spec(envDelim: ":")
      check cursor.probe(arg, spec)
      check cursor.probe(arg, spec)
      check cursor.probe(arg, spec)
      check not cursor.probe(arg, spec)

  suite "EnvCursor.apply":
    test "sets an unconsulted arg's value directly from env":
      putEnv("ARGUMINT_TEST_DIRECT", "hi")
      defer: delEnv("ARGUMINT_TEST_DIRECT")
      var cursor: EnvCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_DIRECT")
      let spec = Spec(envDelim: ":", args: @[Arg arg])
      var matches: MatchTable
      var seen: HashSet[Arg]
      var complaints: seq[Complaint]
      cursor.apply(spec, matches, seen, complaints)
      check complaints.len == 0
      check arg.recorded == @["hi"]

    test "applies every split value once the walk fully consumed them":
      putEnv("ARGUMINT_TEST_CONSUMED", "a:b")
      defer: delEnv("ARGUMINT_TEST_CONSUMED")
      var cursor: EnvCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_CONSUMED")
      let spec = Spec(envDelim: ":", args: @[Arg arg])
      check cursor.probe(arg, spec)
      check cursor.probe(arg, spec)
      var matches: MatchTable
      var seen: HashSet[Arg]
      var complaints: seq[Complaint]
      cursor.apply(spec, matches, seen, complaints)
      check complaints.len == 0
      check arg.recorded == @["a", "b"]

    test "complains about env values the walk didn't consume":
      putEnv("ARGUMINT_TEST_LEFTOVER", "a:b:c")
      defer: delEnv("ARGUMINT_TEST_LEFTOVER")
      var cursor: EnvCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_LEFTOVER")
      let spec = Spec(envDelim: ":", args: @[Arg arg])
      discard cursor.probe(arg, spec) # consumes only 1 of the 3 available values
      var matches: MatchTable
      var seen: HashSet[Arg]
      var complaints: seq[Complaint]
      cursor.apply(spec, matches, seen, complaints)
      check complaints == @[("unexpected option", arg.name)]

    test "skips an arg already explicitly matched on the command line":
      putEnv("ARGUMINT_TEST_SKIP", "hi")
      defer: delEnv("ARGUMINT_TEST_SKIP")
      var cursor: EnvCursor
      let arg = newTestArg("--foo", "ARGUMINT_TEST_SKIP")
      let spec = Spec(envDelim: ":", args: @[Arg arg])
      var matches: MatchTable
      matches[Arg arg] = @[(variant: "--foo", value: "explicit", spec: spec)]
      var seen: HashSet[Arg]
      var complaints: seq[Complaint]
      cursor.apply(spec, matches, seen, complaints)
      check complaints.len == 0
      check arg.recorded.len == 0
