#!/usr/bin/env bash
# Tests for bin/meeting-capture-merge: the collapse rules that turn a split,
# flooded record of one meeting into a single clean transcript.
# Run via tests/run.sh (also run directly).
set -uo pipefail

pass=0
fail=0
check() { # check <description> <expected> <actual>
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
    printf 'ok %d - %s\n' "$((pass + fail))" "$1"
  else
    fail=$((fail + 1))
    printf 'not ok %d - %s\n     want: %s\n     got:  %s\n' "$((pass + fail))" "$1" "$2" "$3"
  fi
}

merge="$(cd "$(dirname "$0")/.." && pwd)/bin/meeting-capture-merge"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Fixture helpers. Timestamps are a fixed date at a chosen second, so the
# window rules can be driven exactly.
day="2026-08-26T11"
meta() { # meta <file> <recorded mm:ss>
  printf '{"type":"metadata","source":"zoom-ax","app":"Zoom","meeting":"Standup","recorded_at":"%s:%s-05:00","timestamps":"elapsed"}\n' \
    "$day" "$1" >> "$2"
}
caption() { # caption <file> <mm:ss> <speaker> <text> [node] [continues]
  local extra=""
  [[ ${5:-} ]] && extra=",\"node_id\":\"$5\""
  [[ ${6:-} == continues ]] && extra="$extra,\"continues\":true"
  printf '{"type":"caption","speaker":"%s","text":"%s","ts":"%s:%s-05:00","elapsed":"00:00:00"%s}\n' \
    "$3" "$4" "$day" "$2" "$extra" >> "$1"
}
chat() { # chat <file> <mm:ss> <speaker> <text>
  printf '{"type":"chat","speaker":"%s","text":"%s","ts":"%s:%s-05:00","message_id":"1"}\n' \
    "$3" "$4" "$day" "$2" >> "$1"
}
people() { # people <file> <mm:ss> <summary>
  printf '{"type":"people","speaker":"","text":"%s","ts":"%s:%s-05:00","count":2,"confirmed":true}\n' \
    "$3" "$day" "$2" >> "$1"
}
stopped() { # stopped <file> <mm:ss> <lost>
  printf '{"type":"metadata","event":"stopped","stopped_at":"%s:%s-05:00","duration":"00:01:00","lost_events":%s}\n' \
    "$day" "$1" "$3" >> "$2"
}
body() { grep -v '^#' "$1" | grep -v '^$'; }

# --- A growth flood collapses to the one utterance it always was ----------

a="$work/a.jsonl"
meta "46:53" "$a"
caption "$a" "48:15" "Alex Teal" "Yeah, I told him"
caption "$a" "48:16" "Alex Teal" "Yeah, I told him about Wilson"
caption "$a" "48:17" "Alex Teal" "Yeah, I told him about Wilson. So"
caption "$a" "48:19" "Alex Teal" "Yeah, I told him about Wilson. So, like, that."
caption "$a" "48:21" "Eric Boehs" "Or no?"
stopped "48:30" "$a" 0

"$merge" -o "$work/one" --quiet "$a"
check "a growth flood becomes one line per utterance" "2" "$(body "$work/one.txt" | wc -l | tr -d ' ')"
check "the surviving line is the fullest form" \
  "[11:48:15] Alex Teal: Yeah, I told him about Wilson. So, like, that." \
  "$(body "$work/one.txt" | head -1)"
check "and keeps the time the utterance STARTED, not when it finished" \
  "1" "$(body "$work/one.txt" | grep -c '11:48:15')"
check "another speaker's line is untouched" \
  "[11:48:21] Eric Boehs: Or no?" "$(body "$work/one.txt" | tail -1)"

# --- The restart seam: the second session re-reads what is still on screen -

b="$work/b.jsonl"
meta "49:00" "$b"
# Re-read of the row a.jsonl already has in full, plus genuinely new speech.
caption "$b" "49:01" "Alex Teal" "Yeah, I told him about Wilson. So, like"
caption "$b" "49:02" "Eric Boehs" "Right, okay."
stopped "49:30" "$b" 2

"$merge" -o "$work/two" --quiet "$a" "$b"
check "a re-read at the seam does not become a second line" \
  "3" "$(body "$work/two.txt" | wc -l | tr -d ' ')"
check "the meeting reads in order across the seam" \
  "[11:49:02] Eric Boehs: Right, okay." "$(body "$work/two.txt" | tail -1)"
check "sources are recorded in the merged header" \
  "1" "$(grep -c '^# merged from a.jsonl, b.jsonl$' "$work/two.txt")"
check "losses are summed across sessions" \
  "1" "$(grep -c '\"lost_events\":2' "$work/two.jsonl")"
check "the merged file is written with the earliest session's metadata" \
  "1" "$(grep -c '\"recorded_at\":\"2026-08-26T11:46:53-05:00\"' "$work/two.jsonl")"

# Argument order must not matter: sessions are ordered by their own clocks.
"$merge" -o "$work/rev" --quiet "$b" "$a"
check "sources given out of order still merge chronologically" \
  "$(body "$work/two.txt")" "$(body "$work/rev.txt")"

# --- Genuine repetition survives ------------------------------------------
#
# The collapse rule is a heuristic about ONE utterance being recorded twice, so
# it has to stay local. Someone saying the same short thing later in the call
# is a real second line.

c="$work/c.jsonl"
meta "00:00" "$c"
caption "$c" "10:00" "Alex Teal" "All right."
caption "$c" "10:02" "Eric Boehs" "Sure."
caption "$c" "40:00" "Alex Teal" "All right."
stopped "41:00" "$c" 0

"$merge" -o "$work/repeat" --quiet "$c"
check "the same words half an hour later are a real second line" \
  "2" "$(body "$work/repeat.txt" | grep -c 'All right.')"

# ...and a prefix that is far enough back in the SPEAKER's own lines is left
# alone too, even inside the time window.
d="$work/d.jsonl"
meta "00:00" "$d"
caption "$d" "10:00" "Alex Teal" "So"
for second in 01 02 03 04 05; do
  caption "$d" "10:$second" "Alex Teal" "unrelated line $second"
done
caption "$d" "10:06" "Alex Teal" "So the lead side of it is fine."
stopped "11:00" "$d" 0

"$merge" -o "$work/far" --quiet "$d"
check "a prefix beyond the lookback is not collapsed into" \
  "7" "$(body "$work/far.txt" | wc -l | tr -d ' ')"

# --- Continuation tails are rejoined to their row -------------------------
#
# The daemon writes only the words a row added after it was already recorded,
# so a tail is meaningless on its own.

e="$work/e.jsonl"
meta "00:00" "$e"
caption "$e" "20:00" "Eric Boehs" "Oh, I thought you said Kutara." "3570"
caption "$e" "20:09" "Eric Boehs" "Allie is failing geography." "3570" continues
stopped "21:00" "$e" 0

"$merge" -o "$work/tail" --quiet "$e"
check "a continuation is folded back into the row it extends" \
  "[11:20:00] Eric Boehs: Oh, I thought you said Kutara. Allie is failing geography." \
  "$(body "$work/tail.txt")"

# A tail whose row is not in this file must not be silently dropped.
f="$work/f.jsonl"
meta "00:00" "$f"
caption "$f" "20:09" "Eric Boehs" "Allie is failing geography." "3570" continues
stopped "21:00" "$f" 0
"$merge" -o "$work/orphan" --quiet "$f"
check "an orphaned continuation is kept rather than lost" \
  "[11:20:09] Eric Boehs: Allie is failing geography." "$(body "$work/orphan.txt")"

# --- Chat is carried through, tagged as the daemon tags it ----------------

g="$work/g.jsonl"
meta "00:00" "$g"
caption "$g" "30:00" "Alex Teal" "Have a look at the link."
chat "$g" "30:05" "Alex Teal" "https://example.test/thing"
stopped "31:00" "$g" 0

"$merge" -o "$work/withchat" --quiet "$g"
check "chat lines survive the merge and stay marked" \
  "[11:30:05] (chat) Alex Teal: https://example.test/thing" "$(body "$work/withchat.txt" | tail -1)"

# --- A roster survives, and keeps its missing attribution ------------------
#
# The daemon records who was in the meeting as a speakerless "people" event.
# Rendering it like a caption would produce "(people) : 2 in the meeting".

r="$work/r.jsonl"
meta "00:00" "$r"
people "$r" "01:00" "2 in the meeting (confirmed): Ashley, Eric"
caption "$r" "02:00" "Eric Boehs" "Morning."
stopped "03:00" "$r" 0

"$merge" -o "$work/withpeople" --quiet "$r"
check "the roster survives the merge without a dangling attribution" \
  "[11:01:00] (people) 2 in the meeting (confirmed): Ashley, Eric" \
  "$(body "$work/withpeople.txt" | head -1)"

# --- Damaged input --------------------------------------------------------
#
# A killed daemon can leave a torn final line. Everything before it is good.

h="$work/h.jsonl"
meta "00:00" "$h"
caption "$h" "50:00" "Alex Teal" "This line is complete."
printf '{"type":"caption","speaker":"Alex Teal","text":"tor' >> "$h"
"$merge" -o "$work/torn" --quiet "$h" 2>/dev/null
check "a torn last line costs one line, not the meeting" \
  "[11:50:00] Alex Teal: This line is complete." "$(body "$work/torn.txt")"

# --- Inputs are never modified --------------------------------------------

before=$(shasum -a 256 "$a" "$b" | shasum -a 256)
"$merge" -o "$work/again" --quiet "$a" "$b"
check "merging leaves the source transcripts untouched" \
  "$before" "$(shasum -a 256 "$a" "$b" | shasum -a 256)"

# .txt inputs resolve to the .jsonl that carries the structure.
cp "$work/two.txt" "$work/pair.txt"; cp "$work/two.jsonl" "$work/pair.jsonl"
"$merge" -o "$work/frompair" --quiet "$work/pair.txt"
check "naming the .txt half merges its .jsonl" \
  "$(body "$work/two.txt")" "$(body "$work/frompair.txt")"

# --- Summary --------------------------------------------------------------

total=$((pass + fail))
if [[ $fail -eq 0 ]]; then
  echo "all $total assertions passed"
  exit 0
else
  echo "$fail/$total assertions FAILED"
  exit 1
fi
