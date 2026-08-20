#!/usr/bin/env bash
# subagent-statusline — Claude Code subagent status line.
#
# Reads the agent-panel JSON on stdin and writes ONE JSON LINE PER ROW to stdout:
#
#   {"id": "<task id>", "content": "<row body>"}
#
# `content` replaces the whole row body — name, description and status — and is
# rendered as-is, so it may carry ANSI. Omitting a task's id keeps Claude Code's
# default rendering for that row; emitting an empty `content` HIDES the row, which
# is why every failure path here writes NOTHING rather than an empty string.
#
# Configured via ~/.claude/settings.json:
#   "subagentStatusLine": { "type": "command", "command": ".../subagent-statusline.sh" }
#
# ── Why this was rewritten ──────────────────────────────────────────────────
# The previous version emitted a single `{"tasks":[{id,state,elapsed,tokenText,
# queuedText,queuedCount,tokenSamples}]}` object. Claude Code validates each line
# against `{id: string, content: string}` and logs `subagentStatusLine emitted
# invalid schema` — visible only under `claude --debug` — then falls back to the
# default row. So the old script was a silent no-op: it had been dead since the
# API changed, and nothing surfaced that. Those key names match the client's own
# internal row model, so it presumably worked against an earlier contract.
#
# ── What each row shows ─────────────────────────────────────────────────────
#   <name>  <ctx bar> <tokens>  <model> <effort>  <elapsed>
#
# The context bar uses the same marks as the main statusline (mid shade over a
# light track), so a subagent's context pressure reads the same way as the
# session's. `contextWindowSize` and `model` need Claude Code v2.1.205+, `effort`
# v2.1.214+; each cell is simply absent on older builds rather than guessed at.
#
# One jq pass does the whole transform — no per-task subshell, awk or date fork.

set -euo pipefail

# No jq, or input that isn't an object: emit nothing, which leaves every row on
# Claude Code's default rendering. Emitting empty content would hide them all.
command -v jq > /dev/null 2>&1 || exit 0

input=$(cat)
printf '%s' "$input" | jq -e 'type == "object"' > /dev/null 2>&1 || exit 0

printf '%s' "$input" | jq -c -r --arg esc "$(printf '\033')" '
  def rst: $esc + "[0m";
  def bold: $esc + "[1m";
  def muted: $esc + "[90m";
  def purple: $esc + "[38;5;141m";
  def red: $esc + "[31m";

  def pad2: tostring | if length < 2 then "0" + . else . end;

  # Integer abbreviation, no float math: 42 / 12k / 1M.
  def abbrev($n):
    if   $n < 1000    then ($n | tostring)
    elif $n < 1000000 then (($n / 1000) | floor | tostring) + "k"
    else                   (($n / 1000000) | floor | tostring) + "M"
    end;

  def elapsed($secs; $compact):
    if $compact then
      if   $secs < 60   then "\($secs)s"
      elif $secs < 3600 then "\(($secs / 60) | floor)m"
      else                   "\(($secs / 3600) | floor)h"
      end
    else
      if   $secs < 60   then "\($secs)s"
      elif $secs < 3600 then "\(($secs / 60) | floor)m\((($secs % 60) | floor) | pad2)s"
      else                   "\(($secs / 3600) | floor)h\(((($secs % 3600) / 60) | floor) | pad2)m"
      end
    end;

  # Mid shade over a light track, matching the main statusline.
  def bar($pct; $w):
    (($pct * $w / 100) | floor | if . > $w then $w elif . < 0 then 0 else . end) as $f
    | purple + ("▒" * $f | if . == null then "" else . end)
      + muted + ("░" * ($w - $f) | if . == null then "" else . end) + rst;

  # Model ids are long and mostly boilerplate; the distinguishing part is enough.
  def short_model($m):
    ($m // "") | sub("^claude-"; "") | sub("-[0-9]{8}$"; "") | sub("\\[1m\\]$"; "");

  (now * 1000) as $now
  | ((.columns // 200) | (tonumber? // 200)) as $cols
  | ($cols < 100) as $compact
  | (if $compact then 6 else 10 end) as $barw

  | (.tasks // [] | if type == "array" then . else [] end)[]
  | select((.id // "") != "")
  | . as $t
  | (($t.tokenCount // 0) | if type == "number" then . else 0 end) as $tok
  | (($t.contextWindowSize // 0) | if type == "number" then . else 0 end) as $win
  | (($t.startTime // 0) | if type == "number" then . else 0 end) as $st
  | (((($now - $st) / 1000) | floor) | if . < 0 then 0 else . end) as $secs
  | (($t.status // "") | ascii_downcase) as $status
  | (if ($status == "failed" or $status == "error" or $status == "killed")
     then red else bold end) as $namecol

  | [
      ($namecol + (($t.name // $t.type // "agent") | tostring) + rst),

      # Context pressure, but only when the window size is actually known —
      # a bar drawn against a guessed denominator would be a lie.
      (if $win > 0 and $tok > 0
       then bar(($tok * 100 / $win); $barw) + " " + muted + abbrev($tok) + rst
       elif $tok > 0 then muted + abbrev($tok) + " tokens" + rst
       else empty end),

      (if ($t.model // "") != "" and (($cols) > 120)
       then muted + short_model($t.model)
            + (if ($t.effort // "") != "" then " " + ($t.effort | tostring) else "" end)
            + rst
       else empty end),

      (if $st > 0 then muted + elapsed($secs; $compact) + rst else empty end)
    ]
  | join("  ")
  | { id: $t.id, content: . }
' 2> /dev/null || exit 0
