#!/usr/bin/env bash
# subagent-statusline tests.
#
#   test/subagent.sh
#
# The contract under test is narrow and unforgiving, which is exactly why it went
# unnoticed when it broke: Claude Code reads ONE JSON OBJECT PER LINE, each
# `{id: string, content: string}`, and silently falls back to the default row for
# anything it cannot validate. A wrong shape produces no error a user ever sees —
# only a `subagentStatusLine emitted invalid schema` line under `claude --debug`.
#
# So the first assertion here is the one that matters: every emitted line must
# validate. The previous implementation emitted a single `{"tasks":[...]}` object
# and had therefore been a silent no-op since the API changed.
#
# The second rule with teeth: an EMPTY `content` HIDES a row. Every degradation
# path must emit NOTHING rather than an empty string, or a malformed payload would
# blank the whole agent panel instead of leaving it on the default rendering.

set -u
cd "$(dirname "$0")/.." || exit 2
SCRIPT="$(pwd)/subagent-statusline.sh"
PASS=0 FAIL=0

assert() {
  if [ "$2" -eq 0 ]; then
    printf 'ok       %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf 'FAIL     %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

strip_ansi() { sed $'s/\033\[[0-9;]*m//g'; }
run() { printf '%s' "$1" | bash "$SCRIPT" 2> /dev/null; }

NOW=$(date +%s)
ms() { echo $(((NOW - $1) * 1000)); }

FULL='{"columns":140,"tasks":[
 {"id":"t1","name":"Explore","status":"running","startTime":'"$(ms 125)"',"tokenCount":42000,"contextWindowSize":200000,"model":"claude-opus-5","effort":"high"},
 {"id":"t2","name":"Review","status":"failed","startTime":'"$(ms 3700)"',"tokenCount":900000,"contextWindowSize":1000000},
 {"id":"t3","name":"Fresh","status":"running","startTime":'"$(ms 30)"',"tokenCount":500}
]}'

# ── The contract ─────────────────────────────────────────────────────────────
out=$(run "$FULL")
n=$(printf '%s\n' "$out" | grep -c .)
assert "contract: one line per task" "$([ "$n" -eq 3 ] && echo 0 || echo 1)"

bad=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  printf '%s' "$line" | jq -e '
    type == "object"
    and (keys | sort) == ["content","id"]
    and (.id | type) == "string" and (.id | length) > 0
    and (.content | type) == "string" and (.content | length) > 0
  ' > /dev/null 2>&1 || bad=1
done <<< "$out"
assert "contract: every line validates as {id, content}" "$bad"

# The failure this replaces: a single {"tasks":[...]} object, which parses as JSON
# and then fails schema validation, so Claude Code drops it and renders defaults.
case "$out" in *'"tasks"'*) c=1 ;; *) c=0 ;; esac
assert "contract: no legacy {tasks:[...]} envelope is emitted" "$c"

# ── Content ──────────────────────────────────────────────────────────────────
plain=$(printf '%s' "$out" | jq -r '.content' | strip_ansi)
case "$plain" in *'Explore'*) c=0 ;; *) c=1 ;; esac
assert "content: the task name renders" "$c"
case "$plain" in *'42k'*) c=0 ;; *) c=1 ;; esac
assert "content: the token count is abbreviated" "$c"
case "$plain" in *'2m0'[0-9]'s'*) c=0 ;; *) c=1 ;; esac
assert "content: elapsed renders from startTime as MmSSs" "$c"
case "$plain" in *'1h0'[0-9]'m'*) c=0 ;; *) c=1 ;; esac
assert "content: an hour-plus task renders hours and minutes" "$c"
case "$plain" in *'opus-5 high'*) c=0 ;; *) c=1 ;; esac
assert "content: model and effort render on a wide panel" "$c"
case "$plain" in *'▒'*) c=0 ;; *) c=1 ;; esac
assert "content: a context bar renders when the window size is known" "$c"

# A bar drawn against an unknown denominator would be a lie, so a task with no
# contextWindowSize gets a plain token count instead.
t3=$(printf '%s' "$out" | grep '"t3"' | jq -r '.content' | strip_ansi)
case "$t3" in *'▒'*) c=1 ;; *) c=0 ;; esac
assert "content: no context bar without a window size" "$c"
case "$t3" in *'500 tokens'*) c=0 ;; *) c=1 ;; esac
assert "content: ...it falls back to a plain token count" "$c"

# A failed task is coloured, since the row body replaces the status text entirely.
t2raw=$(printf '%s' "$out" | grep '"t2"' | jq -r '.content')
case "$t2raw" in *$'\033[31m'*) c=0 ;; *) c=1 ;; esac
assert "content: a failed task renders its name in red" "$c"

# Narrow panels compact elapsed and drop the model.
narrow=$(run "${FULL/140/80}" | jq -r '.content' | strip_ansi)
# Compact drops the seconds entirely, so the MmSSs form must not appear at all.
case "$narrow" in *'m0'[0-9]'s'*) c=1 ;; *) c=0 ;; esac
assert "width: elapsed compacts on a narrow panel" "$c"
case "$narrow" in *'opus-5'*) c=1 ;; *) c=0 ;; esac
assert "width: the model drops on a narrow panel" "$c"

# ── Degradation: emit NOTHING, never empty content ──────────────────────────
# An empty content string hides a row, so every one of these must produce no
# output at all — which leaves Claude Code's default rendering in place.
for bad_in in '' 'not json at all' '{}' '{"tasks":"nope"}' '{"tasks":[]}' '[]' '{"tasks":[{"name":"no id"}]}'; do
  o=$(run "$bad_in")
  label=${bad_in:-<empty>}
  assert "degrade: '$label' emits nothing" "$([ -z "$o" ] && echo 0 || echo 1)"
done

# ...and never a non-zero exit, which Claude Code logs.
for bad_in in '' 'not json' '{"tasks":"nope"}'; do
  printf '%s' "$bad_in" | bash "$SCRIPT" > /dev/null 2>&1
  assert "degrade: '${bad_in:-<empty>}' exits 0" "$?"
done

# A task with an id but nothing else must still produce a usable row rather than
# an empty content string that would hide it.
minimal=$(run '{"tasks":[{"id":"m1"}]}')
c=1
case "$minimal" in *'"m1"'*) case "$(printf '%s' "$minimal" | jq -r '.content')" in ?*) c=0 ;; esac ;; esac
assert "degrade: a bare id still yields non-empty content" "$c"

# Nothing may reach stderr — Claude Code surfaces it.
err=$(printf '%s' 'not json' | bash "$SCRIPT" 2>&1 > /dev/null)
assert "degrade: nothing is written to stderr" "$([ -z "$err" ] && echo 0 || echo 1)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
