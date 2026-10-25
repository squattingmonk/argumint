## Did-You-Mean Suggestions: which declared names a mistyped one is close
## enough to suggest, and the `"; did you mean --port?"` text that offers
## them. Below `values` and `walk` so both a walk's complaint and a Flag's
## `accept` can suggest by one rule. See ADR 0035 and `docs/architecture.md`,
## "Wording and raising".

import std/[algorithm, sequtils, strutils, unicode]

import ./style

proc osaDistance(a, b: seq[Rune]): int =
  ## Damerau-Levenshtein, optimal string alignment: an adjacent transposition
  ## costs 1. Hand-rolled over `Rune`s because `std/editdistance` has no
  ## transposition variant and its ASCII one splits multi-byte characters. See
  ## ADR 0035.
  var d = newSeq[seq[int]](a.len + 1)
  for i in 0 .. a.len:
    d[i] = newSeq[int](b.len + 1)
    d[i][0] = i
  for j in 0 .. b.len:
    d[0][j] = j
  for i in 1 .. a.len:
    for j in 1 .. b.len:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      d[i][j] = min(min(d[i - 1][j] + 1, d[i][j - 1] + 1), d[i - 1][j - 1] + cost)
      if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
        d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
  d[a.len][b.len]

proc bareName(variant: string): string =
  ## `variant` with its leading dashes stripped -- measuring the full spelling
  ## inflates every threshold. See ADR 0035.
  variant.strip(trailing = false, chars = {'-'})

proc isShortForm*(variant: string): bool =
  ## Whether `variant` is written as a short option -- exactly one leading
  ## dash. A Command name (no dash at all) is never short-form.
  variant.len > 1 and variant[0] == '-' and variant[1] != '-'

proc didYouMean*(typed: string, candidates: seq[string],
    role: StyleRole): StyledText =
  ## `"; did you mean --port?"`, each suggestion styled as `role`, for whichever
  ## of `candidates` sit within `min(2, max(1, n div 4))` of `typed`, `n` being
  ## the candidate's own dash-stripped length; all tied at the best distance,
  ## sorted. The cap is load-bearing. Eligibility of `typed` is
  ## `unknownOption`'s call, not this one's. See ADR 0035.
  if typed.isShortForm:
    return
  var
    best = high(int)
    hits: seq[string]

  let word = typed.bareName.toRunes
  for candidate in candidates.sorted:
    if candidate == typed or candidate.isShortForm:
      continue
    let
      name = candidate.bareName.toRunes
      distance = osaDistance(word, name)
    if distance > min(2, max(1, name.len div 4)):
      continue
    if distance < best:
      (best, hits) = (distance, @[candidate])
    elif distance == best:
      hits.add candidate

  let names = hits.mapIt(styled(role, it))
  case names.len
  of 0: StyledText()
  of 1: styled("; did you mean ") & names[0] & styled("?")
  of 2: styled("; did you mean ") & names.join(styled(" or ")) & styled("?")
  else:
    styled("; did you mean ") & names[0 ..^ 2].join(styled(", ")) &
      styled(", or ") & names[^1] & styled("?")

when isMainModule:
  import std/unittest

  suite "osaDistance":
    test "empty strings are distance 0":
      check osaDistance("".toRunes, "".toRunes) == 0

    test "identical strings are distance 0":
      check osaDistance("abc".toRunes, "abc".toRunes) == 0

    test "substitution costs 1":
      check osaDistance("ab".toRunes, "ac".toRunes) == 1

    test "insertion or deletion costs 1":
      check osaDistance("ab".toRunes, "abc".toRunes) == 1
      check osaDistance("abc".toRunes, "ab".toRunes) == 1

    test "adjacent transposition costs 1, not 2":
      check osaDistance("ab".toRunes, "ba".toRunes) == 1

    test "a multi-byte rune counts as one character, not one per byte":
      # "café" vs "cafe" differ by a single rune (é vs e) -- a byte-wise
      # distance would be larger, since é is two UTF-8 bytes.
      check osaDistance("café".toRunes, "cafe".toRunes) == 1

  suite "didYouMean":
    test "an empty candidate list returns no suggestions":
      check didYouMean("foo", @[], srOption).plain == ""

    test "a candidate equal to the typed string is never offered":
      check didYouMean("foo", @["foo"], srOption).plain == ""
      check didYouMean("foo", @["foo", "fox"], srOption).plain == "; did you mean fox?"

    test "equality check is based on non-dash-stripped forms":
      check didYouMean("foo", @["--foo"], srOption).plain == "; did you mean --foo?"
      check didYouMean("---foo", @["--foo"], srOption).plain == "; did you mean --foo?"

    test "suggestions are never offered for short options":
      # Every short option is 1 editdistance away from every other short option,
      # so any suggestions would be useless. This must be based on the shape of
      # the typed word rather than its dash-stripped length, since commands
      # could be one-character long and thus making suggestions for them makes
      # sense.
      check didYouMean("-a", @["b", "-b"], srOption).plain == ""
      check didYouMean("a", @["b"], srOption).plain == "; did you mean b?"

    test "short options are never offered as suggestions":
      # Same reasoning as above.
      check didYouMean("a", @["-b"], srOption).plain == ""

    test "the distance threshold is keyed on the candidate's length, not the typed word's":
      # "abcdefg" (7, dash-stripped) has threshold min(2, max(1, 7 div 4)) == 1.
      # "abcdxfgh" (8) is distance 2 from it -- over that candidate's own
      # threshold, so no suggestion. Were the threshold wrongly keyed on the
      # *typed* word's length instead (8 -> threshold 2), this would wrongly
      # suggest.
      check didYouMean("abcdxfgh", @["abcdefg"], srOption).plain == ""

    test "offered once inside the candidate's own threshold":
      check didYouMean("porta", @["port"], srOption).plain == "; did you mean port?"

    test "declined once outside the candidate's own threshold":
      check didYouMean("portla", @["port"], srOption).plain == ""

    test "the closest candidates are suggested":
      check didYouMean("--longoption", @["--long-options"], srOption).plain == "; did you mean --long-options?"
      check didYouMean("--longoption", @["--long-options", "--long-option"], srOption).plain == "; did you mean --long-option?"

    test "multiple suggestions are joined by commas, with the final pair being joined by \"or\"":
      check didYouMean("foo", @["fox", "poo"], srOption).plain == "; did you mean fox or poo?"
      check didYouMean("foo", @["foot", "fox", "poo"], srOption).plain == "; did you mean foot, fox, or poo?"

    test "all best-distance ties are offered, sorted, never by declaration order":
      check didYouMean("cab", @["cat", "car"], srOption).plain == "; did you mean car or cat?"

