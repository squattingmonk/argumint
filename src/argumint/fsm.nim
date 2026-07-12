## This module handles the navigation of the FSM based on a set of provided
## command-line arguments.
import std/[editdistance, os, pegs, strformat, strutils, tables]

import ./[backend, parser]
export ParseError, SpecDefect


type
  Match = tuple[variant: string, value: string]
  MatchTable = OrderedTable[Arg, seq[Match]]
  Complaint = tuple[kind: string, subject: string]
    ## A failure reason, e.g. `("missing option", "-v")`. Kept structured
    ## (rather than a pre-formatted string) so same-kind complaints can be
    ## grouped into one message at render time -- see `parse`.

  ParseContext = object
    depth: int            ## The depth of the current fsm path
    maxDepth: int         ## The depth of the deepest fsm path prior to the current one
    spec: Spec            ## The spec for the parsed command (used to generate usage and help messages)
    command: string       ## The command string up to the current subcommand
    messages: seq[Complaint] ## A list of complaints indicating failure reason of the deepest fsm path
    tokens: seq[CmdLineToken]     ## The arguments left to be parsed
    matches: MatchTable   ## A table of processed matches
    envValues: Table[Arg, seq[string]] ## Cache of an env-configured Arg's
      ## raw env value already split via `splitEnvValue`, populated the
      ## first time `match`'s `Option` branch consults it during this walk.
    envConsumed: Table[Arg, int] ## How many of an Arg's `envValues` have
      ## already been handed out as a virtual match in this walk (see
      ## `match`'s `Option` branch) -- a cursor, not a one-shot flag, so an
      ## Arg matched more than once (a real repeat, or simply named more
      ## than once in one Usage Line) can have each occurrence satisfied by
      ## a *different* value from the same env var. Whether an Arg's
      ## position gets consulted once or several times is never decided
      ## here -- it falls out of however many times `walk` actually visits
      ## this matcher, driven entirely by the FSM already built from the
      ## Usage String. See
      ## `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`.

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
    option <- ^ {(shortOption / longOption)} ({sep} {value}) $
    sep <- op? equals
    equals <- '=' / ':'
    op <- (prepend / append / remove / reset)
    prepend <- '^'
    append <- '+'
    remove <- '-'
    reset <- '&'
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

proc push(matches: var MatchTable, arg: Arg, variant: string, value = "") =
  ## Adds a matched arg's seen variant and value to the table of matches.
  if matches.hasKeyOrPut(arg, @[(variant, value)]):
    matches[arg].add (variant, value)

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
        pc.matches.push(m.arg, m.arg.name, token.argVal)
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
          pc.matches.push(m.cmd, token.cmdName)
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
          pc.matches.push(token.opt, token.optName, token.optVal)
          pc.tokens.delete pos
          return true
      of Flag:
        if token.flag == m.opt:
          pc.matches.push(token.flag, token.flagName)
          pc.tokens.delete pos
          return true
      of Command:
        break
      else:
        discard
      pos.inc

    # No CLI token matched. Rather than failing outright, let this Arg's
    # configured env var stand in for a missing value here -- this is what
    # lets a *required* (unbracketed) Option/Flag be satisfied by env: env
    # is a per-Arg declaration, so it shouldn't behave differently depending
    # on whether this particular Usage Line happens to require the Arg or
    # not (see ADR 0004). Consuming no token and not recording into
    # `pc.matches` defers the actual value-setting to `Spec.parse`'s
    # existing post-walk env sweep, which already runs for any Arg that
    # wasn't explicitly matched -- this just stops the walk itself from
    # failing here.
    #
    # The env var's value is always split (`splitEnvValue`) into however
    # many values it supplies; `pc.envConsumed` is a per-Arg cursor into
    # that list rather than a one-shot flag, handing out the next
    # unconsumed value each time this Arg's matcher is consulted, and
    # failing (falling through to "missing option" below) once the list is
    # exhausted -- the same outcome as running out of real CLI tokens for a
    # repeatable position. See
    # `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`.
    let envName = m.opt.envName
    if envName.len > 0 and existsEnv(envName):
      if m.opt notin pc.envValues:
        pc.envValues[m.opt] = splitEnvValue(getEnv(envName), pc.spec.envDelim)
      let consumed = pc.envConsumed.getOrDefault(m.opt, 0)
      if consumed < pc.envValues[m.opt].len:
        pc.envConsumed[m.opt] = consumed + 1
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

proc parse*(spec: Spec, args: seq[string] = commandLineParams(),
    command = extractFilename(getAppFilename())) =
  ## Creates an FSM for `spec` and attempts to navigate it using `args`. If a
  ## terminal state was reached and all args were consumed, the parse was
  ## successful and each match is parsed into its arg. Raises `ParseError`,
  ## `ValidationError`, `HelpError`, or `MessageError` on failure -- use
  ## `parseOrQuit*` (`argumint.nim`) if you want those to print a message and
  ## `quit()` instead.
  var pc = ParseContext(spec: spec, command: command, tokens: spec.tokenizeArgs(args, command))
  if not spec.fsm.walk(pc):
    raiseParseError(formatComplaints(pc.messages), pc.command, pc.spec)

  # Fall back to an environment variable for any arg that has one
  # configured and wasn't explicitly matched on the command line. This is
  # deliberately outside the FSM/backtracking above -- walk() only ever
  # sees typed tokens, and this way an arg only reachable via [options]
  # still picks up its env var even though [options] itself was never
  # explicitly attempted during matching. `arg notin pc.matches` is
  # exactly "wasn't explicitly typed", so an explicit CLI value always
  # wins for free, no extra bookkeeping needed.
  #
  # An Arg whose matcher was actually consulted during the walk
  # (`arg in pc.envConsumed`) gets exactly as many values applied as the
  # walk consumed -- if the env var had more left over than the grammar
  # had positions for, that's a ParseError rather than a silent
  # truncation to a prefix of the values (see
  # `docs/adr/0005-env-supplied-multi-value-options-and-flags.md`). An Arg
  # never consulted at all this walk (reachable only via a different,
  # unmatched Usage Line of this same spec) has no walk-derived count to
  # bound it by, so every available value is applied, generalizing the
  # single-value fallback ADR 0004 already established for that case.
  var envComplaints: seq[Complaint]
  for arg in pc.spec.args:
    let name = arg.envName
    if name.len == 0 or arg in pc.matches or not existsEnv(name):
      continue
    if arg in pc.envConsumed:
      let consumed = pc.envConsumed[arg]
      let total = pc.envValues[arg].len
      if consumed < total:
        let kind = if arg.kind == Flag: "unexpected flag" else: "unexpected option"
        envComplaints.add (kind, arg.name)
      else:
        arg.setFromEnv(pc.envValues[arg])
    else:
      arg.setFromEnv(splitEnvValue(getEnv(name), pc.spec.envDelim))
  if envComplaints.len > 0:
    raiseParseError(formatComplaints(envComplaints), pc.command, pc.spec)

  var commands = newSeq[Arg]()
  for arg, matches in pc.matches.pairs:
    if arg.kind == Command:
      commands.add arg
      continue
    for (variant, value) in matches:
      if arg of HelpArg:
        arg.parse(pc.command, pc.spec, variant)
      else:
        arg.parse(value, variant)
  for command in commands:
    for (variant, value) in pc.matches[command]:
      # echo "Got command: ", variant
      command.parse(value, variant)
