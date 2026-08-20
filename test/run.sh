#!/usr/bin/env bash
# claude-statusline snapshot + invariant tests.
#
#   test/run.sh            # run all cases, diff against golden snapshots
#   test/run.sh --update   # regenerate the golden snapshots
#
# Most cases render in a throwaway NON-git temp dir so the git segments stay
# empty and output is fully determined by the payload + env (the process pwd,
# not the payload, drives git detection). Separate throwaway repos exercise
# branch truncation, the full set of working-tree counters, and telemetry
# detection.
#
# Determinism: HOME is pinned off-tree so dir_display never abbreviates to '~',
# resets_at is a far-future sentinel so "time left" pins to the full window and
# cancels out the real clock, COLUMNS is fixed per case, and
# OTEL_RESOURCE_ATTRIBUTES is pinned empty so the coverage tag answers to the
# fixture alone — not to whether the session running the suite is itself tagged
# (this repo is, CI isn't, and that would otherwise flip every git golden).
#
# THE load-bearing invariant is geometry: the panel is a frame, and a frame whose
# rules and content rows disagree by even one column is visibly broken. Every
# emitted line must be exactly COLUMNS - CHROME_MARGIN wide. That is asserted
# across a sweep of widths and payloads, and it is the check most likely to catch
# a future edit.

set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$(pwd)
SCRIPT="$ROOT/statusline.sh"
GOLDEN_DIR="$ROOT/test/golden"
mkdir -p "$GOLDEN_DIR"

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

FAR_FUTURE=9999999999 # resets_at sentinel (year 2286): always in the future
MARGIN=8              # CHROME_MARGIN in statusline.sh
PASS=0 FAIL=0

strip_ansi() { sed $'s/\033\[[0-9;]*m//g; s/\033\]8;;[^\007]*\007//g'; }

# Visible width per line, locale-independent. Deleting UTF-8 continuation bytes
# leaves exactly one byte per character, so `length` is then the column count —
# `wc -m` and awk's own length would each need a UTF-8 locale to agree, and CI
# and macOS do not ship the same ones.
vislen() { LC_ALL=C awk '{ s = $0; gsub(/[\200-\277]/, "", s); print length(s) }'; }

# run_sl <cols> <payload>  — render in the current directory with pinned env.
run_sl() {
  COLUMNS=$1 HOME=/home/tester COLORTERM=truecolor TERM=xterm-256color \
    NO_COLOR='' CMUX_SURFACE_ID='' CMUX_BUNDLE_ID='' \
    CLAUDE_AUTOCOMPACT_PCT_OVERRIDE='' CLAUDE_STATUSLINE_CHROME_MARGIN='' \
    OTEL_RESOURCE_ATTRIBUTES='' CLAUDE_STATUSLINE_HIDE_TELEM='' \
    bash "$SCRIPT" <<< "$2"
}

# snapshot <name> <cols> <payload> — compare ANSI-stripped output to golden.
snapshot() {
  local name=$1 cols=$2 payload=$3
  local golden="$GOLDEN_DIR/$name.txt" actual
  actual=$(run_sl "$cols" "$payload" | strip_ansi)
  if [ "$UPDATE" -eq 1 ]; then
    printf '%s\n' "$actual" > "$golden"
    printf 'updated  %s\n' "$name"
    return
  fi
  if [ ! -f "$golden" ]; then
    printf 'MISSING  %s (run --update)\n' "$name"
    FAIL=$((FAIL + 1))
    return
  fi
  if diff -u "$golden" <(printf '%s\n' "$actual") > "/tmp/sl_diff.$$" 2>&1; then
    printf 'ok       %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL     %s\n' "$name"
    cat "/tmp/sl_diff.$$"
    FAIL=$((FAIL + 1))
  fi
  rm -f "/tmp/sl_diff.$$"
}

# assert <name> <result> — 0 passes.
assert() {
  if [ "$2" -eq 0 ]; then
    printf 'ok       %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf 'FAIL     %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

# ── Payloads ─────────────────────────────────────────────────────────────────
DIR='"workspace":{"current_dir":"/work/DevEnv/claude-statusline"}'
CTX='"context_window":{"used_percentage":42,"total_input_tokens":420000,"context_window_size":1000000}'
RL='"rate_limits":{"five_hour":{"used_percentage":73,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":45,"resets_at":'"$FAR_FUTURE"'}}'

P_NORMAL='{'"$DIR"','"$CTX"',"model":{"display_name":"Opus 4.8"},"effort":{"level":"high"},"output_style":{"name":"Explanatory"},"cost":{"total_cost_usd":1.23,"total_duration_ms":600000},'"$RL"'}'
P_FRESH='{"workspace":{"current_dir":"/work/scratch/tmp"},"context_window":{"used_percentage":3,"total_input_tokens":8000,"context_window_size":200000},"model":{"display_name":"Haiku 4.5"}}'
# Quiet windows: both below WINDOW_LOUD_PCT, so neither prints a percentage.
P_QUIET='{'"$DIR"','"$CTX"',"model":{"display_name":"Opus 4.8"},"rate_limits":{"five_hour":{"used_percentage":22,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":11,"resets_at":'"$FAR_FUTURE"'}}}'
# Loud: both at/above the threshold, so both print one.
P_LOUD='{'"$DIR"','"$CTX"',"model":{"display_name":"Opus 4.8"},"rate_limits":{"five_hour":{"used_percentage":88,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":70,"resets_at":'"$FAR_FUTURE"'}}}'
# Context calm / approaching / past the autocompact threshold (default 80).
P_CTX_CALM='{'"$DIR"',"context_window":{"used_percentage":20,"total_input_tokens":40000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"}}'
P_CTX_NEAR='{'"$DIR"',"context_window":{"used_percentage":70,"total_input_tokens":140000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"}}'
P_CTX_OVER='{'"$DIR"',"context_window":{"used_percentage":88,"total_input_tokens":176000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"}}'
P_COST='{'"$DIR"','"$CTX"',"model":{"display_name":"Opus 4.8"},"cost":{"total_cost_usd":12.34,"total_duration_ms":600000},'"$RL"'}'

NONGIT=$(mktemp -d)
GITREPO="" COUNTERS="" BARE="" CLONE="" TELEMREPO=""
trap 'rm -rf "$NONGIT" "$GITREPO" "$COUNTERS" "$BARE" "$CLONE" "$TELEMREPO"' EXIT
cd "$NONGIT" || exit 2

# ── Snapshots (non-git) ──────────────────────────────────────────────────────
snapshot panel-normal 120 "$P_NORMAL"
snapshot panel-wide 160 "$P_NORMAL"
snapshot panel-narrow 60 "$P_NORMAL"
snapshot panel-fresh 120 "$P_FRESH"
snapshot panel-quiet 120 "$P_QUIET"
snapshot panel-loud 120 "$P_LOUD"

# ── Geometry: the frame must close on every line, at every width ─────────────
# Swept rather than spot-checked because the shed ladder, the space-between join
# and the three-way bar split each round independently, and an off-by-one only
# surfaces at particular widths.
geo_bad=""
for _p in "$P_NORMAL" "$P_FRESH" "$P_QUIET" "$P_LOUD" "$P_COST" "$P_CTX_OVER"; do
  for _w in 60 61 62 63 64 72 80 88 96 100 111 112 120 133 160 200; do
    _want=$((_w - MARGIN))
    while IFS= read -r _len; do
      [ "$_len" -eq "$_want" ] || geo_bad="${geo_bad} ${_w}:${_len}"
    done <<< "$(run_sl "$_w" "$_p" | strip_ansi | vislen)"
  done
done
if [ -n "$geo_bad" ]; then printf 'geometry drift (cols:got):%s\n' "$geo_bad"; fi
assert "geometry: every line is exactly COLUMNS-CHROME_MARGIN wide" \
  "$([ -z "$geo_bad" ] && echo 0 || echo 1)"

# ── The panel is five lines, and framed ─────────────────────────────────────
out=$(run_sl 120 "$P_NORMAL" | strip_ansi)
case "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" in 5) c=0 ;; *) c=1 ;; esac
assert "frame: the panel is exactly five lines" "$c"

l1=$(printf '%s\n' "$out" | sed -n 1p)
l2=$(printf '%s\n' "$out" | sed -n 2p)
l3=$(printf '%s\n' "$out" | sed -n 3p)
l4=$(printf '%s\n' "$out" | sed -n 4p)
l5=$(printf '%s\n' "$out" | sed -n 5p)

case "$l1" in '╭─'*'╮') c=0 ;; *) c=1 ;; esac
assert "frame: the top rule opens and closes its corners" "$c"
case "$l3" in '├─ USAGE '*'┤') c=0 ;; *) c=1 ;; esac
assert "frame: the USAGE label is set into the middle rule" "$c"
case "$l5" in '╰'*'╯') c=0 ;; *) c=1 ;; esac
assert "frame: the bottom rule closes the box" "$c"
c=1
case "$l2" in '│ '*' │') case "$l4" in '│ '*' │') c=0 ;; esac ;; esac
assert "frame: both content rows sit inside verticals" "$c"

# ── The top rule carries identity: the repo, and the coverage verdict ───────
case "$l1" in *'claude-statusline'*) c=0 ;; *) c=1 ;; esac
assert "title: the repo name renders in the top rule" "$c"
# ...and not in the content rows, which would be saying it twice.
case "$l2" in *'claude-statusline'*) c=1 ;; *) c=0 ;; esac
assert "title: the repo is not restated in the text row" "$c"

# ── Meters ───────────────────────────────────────────────────────────────────
case "$l4" in *'CTX '*) c=0 ;; *) c=1 ;; esac
assert "meters: the CTX meter renders" "$c"
c=1
case "$l4" in *'5h '*) case "$l4" in *'7d '*) c=0 ;; esac ;; esac
assert "meters: both rate-limit windows render" "$c"
case "$l4" in *'420k/1M'*) c=0 ;; *) c=1 ;; esac
assert "meters: CTX carries the absolute token readout" "$c"
# The bar is the proportion, so a meter states no percentage of its own...
case "$l4" in *'42%'*) c=1 ;; *) c=0 ;; esac
assert "meters: CTX states no percentage — the bar is the proportion" "$c"

# ...except a window at or above WINDOW_LOUD_PCT, where a bar cannot separate 73%
# from 78% and the difference has started to matter.
quiet4=$(run_sl 120 "$P_QUIET" | strip_ansi | sed -n 4p)
case "$quiet4" in *'22%'* | *'11%'*) c=1 ;; *) c=0 ;; esac
assert "meters: a window below the loud threshold shows no percentage" "$c"
loud4=$(run_sl 120 "$P_LOUD" | strip_ansi | sed -n 4p)
c=1
case "$loud4" in *'88%'*) case "$loud4" in *'70%'*) c=0 ;; esac ;; esac
assert "meters: a window at or above the threshold shows its percentage" "$c"

# A meter is never dropped: a missing meter reads as "no data", which is a
# different and wrong statement from "narrow pane".
narrow4=$(run_sl 60 "$P_NORMAL" | strip_ansi | sed -n 4p)
c=1
case "$narrow4" in *'CTX'*) case "$narrow4" in *'5h'*) case "$narrow4" in *'7d'*) c=0 ;; esac ;; esac ;; esac
assert "meters: all three survive a narrow pane" "$c"

# A payload with no rate limits renders CTX alone rather than empty windows.
fresh4=$(run_sl 120 "$P_FRESH" | strip_ansi | sed -n 4p)
c=1
case "$fresh4" in *'CTX'*) case "$fresh4" in *'5h'*) c=1 ;; *) c=0 ;; esac ;; esac
assert "meters: no rate-limit data renders CTX without empty windows" "$c"

# ── The CTX label is the autocompact indicator ──────────────────────────────
# With the percentages gone there is no number left to escalate and a flat bar has
# no boundary to mark, so the label carries the warning. Asserted on the escape
# codes, because the point is entirely colour.
esc=$(printf '\033')
out_color=$(run_sl 120 "$P_NORMAL")
lab_color() { run_sl 120 "$1" | sed -n 4p | sed 's/.*\('"$esc"'\[[0-9;]*m\)CTX.*/\1/'; }
case "$(lab_color "$P_CTX_CALM")" in "${esc}[32m") c=0 ;; *) c=1 ;; esac
assert "autocompact: CTX is green with room to spare" "$c"
case "$(lab_color "$P_CTX_NEAR")" in "${esc}[33m") c=0 ;; *) c=1 ;; esac
assert "autocompact: CTX turns amber approaching the threshold" "$c"
case "$(run_sl 120 "$P_CTX_OVER" | sed -n 4p)" in *"${esc}[1m${esc}[31mCTX"*) c=0 ;; *) c=1 ;; esac
assert "autocompact: CTX goes bold red once past the threshold" "$c"
# The override has to move the escalation, or it is only decorative.
over=$(COLUMNS=120 HOME=/home/tester COLORTERM=truecolor TERM=xterm-256color NO_COLOR='' \
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=30 OTEL_RESOURCE_ATTRIBUTES='' \
  bash "$SCRIPT" <<< "$P_CTX_CALM" | sed -n 4p)
case "$over" in *"${esc}[33mCTX"* | *"${esc}[1m${esc}[31mCTX"*) c=0 ;; *) c=1 ;; esac
assert "autocompact: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE moves the escalation" "$c"

# ── Row 1 spans the full width (space-between, not packed left) ─────────────
# A row ending in a long blank run reads as truncated; one reaching both edges
# reads as laid out.
# Slack is shared between the rules rather than packed hard left, but the share is
# capped: unbounded space-between maroons a rule mid-pane on a sparse row, which
# reads as a rendering fault rather than as layout. The cap is MAX_GROUP_GAP (16)
# plus the rule's own two spaces, so no blank run inside row 1 may exceed 18.
# Trailing pad is stripped first: that run is exactly what the cap creates, so
# measuring it would assert against the feature. Drop the closing rule, then the
# padding, and measure the blank runs that remain BETWEEN groups.
interior() { sed 's/[^ ]*$//' | sed 's/ *$//' | grep -o ' *' | LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'; }
gap_normal=$(printf '%s' "$l2" | interior)
assert "row 1: no interior blank run exceeds the capped gap" \
  "$([ "$gap_normal" -le 18 ] && echo 0 || echo 1)"
# ...and the same on a deliberately sparse row, the case the cap exists for:
# two short groups in a wide pane.
gap_sparse=$(run_sl 160 "$P_CTX_CALM" | strip_ansi | sed -n 2p | interior)
assert "row 1: a sparse row in a wide pane is capped, not stretched" \
  "$([ "$gap_sparse" -le 18 ] && echo 0 || echo 1)"

# Groups really are divided by a rule, and the rule really is Gnar orange — the
# separator and the frame share that colour, so asserting the glyph alone would
# pass on a plain pipe.
row1_inner=$(printf '%s' "$l2" | sed 's/^..//; s/..$//')
case "$row1_inner" in *'│'*) c=0 ;; *) c=1 ;; esac
assert "row 1: groups are divided by a vertical rule" "$c"
case "$(printf '%s' "$out_color" | sed -n 2p)" in *"${esc}[38;2;181;110;58m│"*) c=0 ;; *) c=1 ;; esac
assert "row 1: the dividing rule is burnt Gnar orange" "$c"

# ── Shed order ───────────────────────────────────────────────────────────────
# Cheapest loss first. The derived burn goes before the total it is derived from;
# invert that and a narrow pane keeps the number you can recompute and drops the
# one you cannot.
seen_shed=0 kept_total=1
for w in 34 36 38 40 42 44 48 52 56 60; do
  line=$(run_sl "$w" "$P_COST" | strip_ansi | sed -n 2p)
  case "$line" in *'/h'*) continue ;; esac
  seen_shed=1
  case "$line" in *'12.34'*) ;; *) kept_total=0 ;; esac
done
assert "shed: a width where the burn sheds was exercised" "$((1 - seen_shed))"
assert "shed: shedding the burn never takes the total with it" "$((1 - kept_total))"

# The output style is the first text cell to go, but the effort tier must outlive
# it: effort changes how the session behaves, a style name only says how it reads.
style_first=1
for w in 60 64 68 72 76 80 84 88; do
  line=$(run_sl "$w" "$P_NORMAL" | strip_ansi | sed -n 2p)
  case "$line" in *'Explanatory'*) continue ;; esac
  case "$line" in *'Hi'*) ;; *) style_first=0 ;; esac
done
assert "shed: effort outlives the output style" "$((1 - style_first))"

# ── Colour behaviour ─────────────────────────────────────────────────────────
case "$out_color" in *"${esc}["*) c=0 ;; *) c=1 ;; esac
assert "color: emits ANSI by default" "$c"

out_nocolor=$(COLUMNS=120 HOME=/home/tester NO_COLOR=1 OTEL_RESOURCE_ATTRIBUTES='' \
  bash "$SCRIPT" <<< "$P_NORMAL")
case "$out_nocolor" in *"${esc}["*) c=1 ;; *) c=0 ;; esac
assert "NO_COLOR: emits no ANSI" "$c"
c=1
case "$out_nocolor" in *'╭─'*) case "$out_nocolor" in *'CTX'*) case "$out_nocolor" in *'420k/1M'*) c=0 ;; esac ;; esac ;; esac
assert "NO_COLOR: the frame and every readout still render" "$c"
nc_bad=""
while IFS= read -r _len; do [ "$_len" -eq 112 ] || nc_bad=1; done <<< "$(printf '%s\n' "$out_nocolor" | vislen)"
assert "NO_COLOR: geometry is unchanged" "$([ -z "$nc_bad" ] && echo 0 || echo 1)"

out_256=$(COLUMNS=120 HOME=/home/tester COLORTERM='' TERM=xterm-256color \
  OTEL_RESOURCE_ATTRIBUTES='' bash "$SCRIPT" <<< "$P_NORMAL")
case "$out_256" in *"${esc}[38;2;"*) c=1 ;; *) c=0 ;; esac
assert "256-color: no truecolor escapes without COLORTERM" "$c"
case "$out_256" in *"${esc}[38;5;"*) c=0 ;; *) c=1 ;; esac
assert "256-color: falls back to the indexed ramp" "$c"

# The three meters must be distinguishable by hue — with one shared texture it is
# the only thing left telling them apart.
hues=$(printf '%s' "$out_color" | sed -n 4p | grep -o "${esc}\[38;2;[0-9;]*m" | sort -u | wc -l | tr -d ' ')
assert "meters: three distinct fill hues on the usage row" "$([ "$hues" -ge 3 ] && echo 0 || echo 1)"

# ── Robustness: a statusline must never fail ────────────────────────────────
COLUMNS=120 bash "$SCRIPT" <<< '{}' > /dev/null 2>&1
assert "exit: an empty payload still exits 0" "$?"
COLUMNS=120 bash "$SCRIPT" <<< 'not json at all' > /dev/null 2>&1
assert "exit: malformed input still exits 0" "$?"
COLUMNS=120 bash "$SCRIPT" < /dev/null > /dev/null 2>&1
assert "exit: empty stdin still exits 0" "$?"
err=$(COLUMNS=120 bash "$SCRIPT" <<< 'not json' 2>&1 > /dev/null)
assert "exit: nothing is written to stderr" "$([ -z "$err" ] && echo 0 || echo 1)"

# ── Git fixture: the branch and its truncation ──────────────────────────────
GITREPO=$(mktemp -d)
(
  set -e
  cd "$GITREPO"
  git init -q
  git checkout -q -b feature/some-really-long-branch-name-goes-here 2> /dev/null
  : > f.txt
  git add f.txt
  git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q --no-verify -m init
) > /dev/null 2>&1
fixture_st=$?
# NOT `( ... ) || { ... }`: bash suppresses set -e inside a compound command that
# is the left operand of ||, so that guard could never fire and the asserts below
# would go vacuous. Capture the status instead.
if [ "$fixture_st" -ne 0 ]; then
  printf 'FAIL     git fixture setup (exit %s)\n' "$fixture_st"
  FAIL=$((FAIL + 1))
else
  cd "$GITREPO" || exit 2
  P_GIT='{"workspace":{"current_dir":"/work/proj/claude-statusline"},'"$CTX"',"model":{"display_name":"Opus 4.8"}}'
  snapshot panel-git 120 "$P_GIT"

  g2=$(run_sl 120 "$P_GIT" | strip_ansi | sed -n 2p)
  case "$g2" in *'@feature/some-really-long-branch-name-goes-here'*) c=0 ;; *) c=1 ;; esac
  assert "git: the branch renders whole, with its @ sigil, when it fits" "$c"
  bw=$(printf '%s' "$g2" | tr -cd '@' | wc -c | tr -d ' ')
  assert "git: exactly one branch sigil renders" "$([ "$bw" -eq 1 ] && echo 0 || echo 1)"

  # Truncation is a last resort and proportionate: the name gives back the
  # overflow and no more, so a pane holding most of a branch shows most of it
  # rather than jumping to a fixed stub.
  mid=$(run_sl 64 "$P_GIT" | strip_ansi | sed -n 2p)
  case "$mid" in *'..'*) c=0 ;; *) c=1 ;; esac
  assert "git: a branch too long for the pane is middle-ellipsized" "$c"
  lw=$(printf '%s' "$g2" | sed 's/ .*//' | vislen)
  lm=$(printf '%s' "$mid" | sed 's/ .*//' | vislen)
  assert "git: branch length is monotonic in pane width" "$([ "$lw" -ge "$lm" ] && echo 0 || echo 1)"
fi

cd "$NONGIT" || exit 2

# ── Counters: every working-tree sigil, in its own colour ──────────────────
COUNTERS=$(mktemp -d) BARE=$(mktemp -d) CLONE=$(mktemp -d)
tg() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
(
  set -e
  git init -q --bare "$BARE/claude-statusline.git"
  cd "$COUNTERS" || exit 2
  git init -q
  git checkout -q -b work
  for i in 1 2 3 4; do echo "l$i" > "f$i.txt"; done
  tg add .
  tg commit -q --no-verify -m init
  tg remote add origin "$BARE/claude-statusline.git"
  tg push -q -u origin HEAD
  for i in 1 2 3; do
    echo "a$i" >> f1.txt
    tg commit -q --no-verify -am "ahead$i"
  done
  git clone -q "$BARE/claude-statusline.git" "$CLONE/c"
  cd "$CLONE/c" || exit 2
  git checkout -q work
  for i in 1 2; do
    echo "r$i" >> f4.txt
    tg commit -q --no-verify -am "remote$i"
  done
  tg push -q origin HEAD
  cd "$COUNTERS" || exit 2
  tg fetch -q origin
  echo s > f1.txt
  tg stash -q
  echo mod >> f2.txt
  echo stg >> f3.txt
  tg add f3.txt
  : > untracked.txt
) > /dev/null 2>&1
ct_st=$?
if [ "$ct_st" -ne 0 ]; then
  printf 'FAIL     counters fixture setup (exit %s)\n' "$ct_st"
  FAIL=$((FAIL + 1))
else
  cd "$COUNTERS" || exit 2
  P_CT='{"workspace":{"current_dir":"/work/proj/x"},'"$CTX"',"model":{"display_name":"Opus 4.8"},"cost":{"total_lines_added":120,"total_lines_removed":45}}'
  snapshot panel-counters 140 "$P_CT"
  # Everything at once. THE README'S EXAMPLE PANEL IS THIS FILE, verbatim — so a
  # docs drift becomes a test failure instead of something nobody notices.
  P_FULL='{"workspace":{"current_dir":"/work/proj/claude-statusline","repo":{"host":"github.com","owner":"TheGnarCo","name":"claude-statusline"}},'"$CTX"',"model":{"display_name":"Opus 4.8"},"effort":{"level":"high"},"output_style":{"name":"Explanatory"},"cost":{"total_cost_usd":1.23,"total_duration_ms":600000,"total_lines_added":120,"total_lines_removed":45},'"$RL"'}'
  snapshot panel-full 120 "$P_FULL"
  ct=$(run_sl 140 "$P_CT" | strip_ansi | sed -n 2p)
  miss=""
  for sig in '^3' 'v2' '!1' '+1' '?1' '*1'; do
    case "$ct" in *"$sig"*) ;; *) miss="$miss $sig" ;; esac
  done
  if [ -n "$miss" ]; then printf 'missing sigils:%s\n' "$miss"; fi
  assert "counters: ahead/behind/unstaged/staged/untracked/stash all render" \
    "$([ -z "$miss" ] && echo 0 || echo 1)"
  case "$ct" in *'+120/-45'*) c=0 ;; *) c=1 ;; esac
  assert "counters: this session's churn renders beside the tree state" "$c"
  # Per-sigil colour is the whole reason they are separate cells.
  raw=$(run_sl 140 "$P_CT" | sed -n 2p)
  c=1
  case "$raw" in *"${esc}[33m!1"*) case "$raw" in *"${esc}[36m?1"*) c=0 ;; esac ;; esac
  assert "counters: unstaged is yellow and untracked is cyan" "$c"
  case "$raw" in *"${esc}[32m${esc}[1m+120"*) c=0 ;; *) c=1 ;; esac
  assert "counters: churn additions render bold green" "$c"
fi

cd "$NONGIT" || exit 2

# ── Coverage tag ─────────────────────────────────────────────────────────────
# The chip reads "tagged" when the repo carries a project.name OTEL attribute and
# "untagged" when it doesn't (so its usage lands in the dashboard as "(untagged)").
# Detection mirrors the toolkit SessionStart hook, and every input it reads is
# asserted here — live env, the repo's checked-in settings, its local override, a
# settings file that exists but carries no tag (the one path that actually forks
# jq), the opt-out, and the non-git case.
#
# Both states are asserted POSITIVELY on purpose: an inverted test would pass on a
# chip that never renders at all, and this chip has to stay in agreement with a
# hook in another repo — exactly the kind of agreement that rots quietly.
TELEMREPO=$(mktemp -d)
(cd "$TELEMREPO" && git init -q) > /dev/null 2>&1 || {
  printf 'FAIL     telem fixture setup\n'
  FAIL=$((FAIL + 1))
}
cd "$TELEMREPO" || exit 2
P_TELEM='{"workspace":{"current_dir":"/work/proj/claude-statusline"},'"$CTX"',"model":{"display_name":"Opus 4.8"}}'

# The tag lives in the TOP RULE, so that is where it is looked for.
chip_is() {
  local rule
  rule=$(run_sl 120 "$P_TELEM" | strip_ansi | sed -n 1p)
  case "$1:$rule" in
    'tagged:'*' tagged '*) return 0 ;;
    'untagged:'*' untagged '*) return 0 ;;
    'none:'*'tagged'*) return 1 ;;
    'none:'*) return 0 ;;
  esac
  return 1
}

chip_is untagged
assert "telem: untagged in a git repo with no attribute" "$?"

mkdir -p "$TELEMREPO/.claude"
TAG='{"env":{"OTEL_RESOURCE_ATTRIBUTES":"project.name=org/repo"}}'
printf '%s\n' "$TAG" > "$TELEMREPO/.claude/settings.json"
chip_is tagged
assert "telem: tagged when .claude/settings.json carries project.name" "$?"

printf '%s\n' '{"env":{"SOMETHING_ELSE":"1"}}' > "$TELEMREPO/.claude/settings.json"
chip_is untagged
assert "telem: settings.json without project.name still counts as untagged" "$?"

printf '%s\n' "$TAG" > "$TELEMREPO/.claude/settings.local.json"
chip_is tagged
assert "telem: tagged when settings.local.json carries project.name" "$?"

# Claude Code merges settings.local.json OVER settings.json, so a local override
# that replaces the attribute without a project.name really is untagged.
printf '%s\n' "$TAG" > "$TELEMREPO/.claude/settings.json"
printf '%s\n' '{"env":{"OTEL_RESOURCE_ATTRIBUTES":"service.name=x"}}' > "$TELEMREPO/.claude/settings.local.json"
chip_is untagged
assert "telem: settings.local.json overrides the repo attribute" "$?"

printf '%s\n' '{"env":{"SOMETHING_ELSE":"1"}}' > "$TELEMREPO/.claude/settings.local.json"
chip_is tagged
assert "telem: an unrelated local override leaves the repo tag standing" "$?"

# An EXPLICITLY emptied override is defined-but-empty, which clears the tag.
printf '%s\n' '{"env":{"OTEL_RESOURCE_ATTRIBUTES":""}}' > "$TELEMREPO/.claude/settings.local.json"
chip_is untagged
assert "telem: an explicitly-emptied local override clears the tag" "$?"

# A malformed settings.json must not mask a valid tag in the local override.
printf '%s\n' "$TAG" > "$TELEMREPO/.claude/settings.local.json"
printf '%s\n' '{ not json' > "$TELEMREPO/.claude/settings.json"
chip_is tagged
assert "telem: malformed settings.json doesn't mask settings.local.json" "$?"

rm -f "$TELEMREPO/.claude/settings.local.json"
chip_is untagged
assert "telem: malformed settings.json alone reads as untagged" "$?"
rm -f "$TELEMREPO/.claude/settings.json"

# Live env, no settings file — how a tagged repo actually renders under Claude
# Code, which exports the merged attribute into the statusline's environment.
out_tagged=$(COLUMNS=120 HOME=/home/tester CLAUDE_STATUSLINE_HIDE_TELEM='' \
  OTEL_RESOURCE_ATTRIBUTES='project.name=org/repo' bash "$SCRIPT" <<< "$P_TELEM" | strip_ansi | sed -n 1p)
case "$out_tagged" in *' tagged '*) c=0 ;; *) c=1 ;; esac
assert "telem: tagged when OTEL_RESOURCE_ATTRIBUTES is set in the env" "$c"

# Both states link to the dashboard, so the OSC8 target must survive on each.
for _st in '' 'project.name=org/repo'; do
  out_link=$(COLUMNS=120 HOME=/home/tester CLAUDE_STATUSLINE_HIDE_TELEM='' \
    CMUX_SURFACE_ID='' CMUX_BUNDLE_ID='' OTEL_RESOURCE_ATTRIBUTES="$_st" \
    bash "$SCRIPT" <<< "$P_TELEM")
  case "$out_link" in *'telem.thegnar.info'*) c=0 ;; *) c=1 ;; esac
  [ "$c" -ne 0 ] && break
done
assert "telem: the chip links to the dashboard in both states" "$c"

out_optout=$(COLUMNS=120 HOME=/home/tester OTEL_RESOURCE_ATTRIBUTES='' \
  CLAUDE_STATUSLINE_HIDE_TELEM=1 bash "$SCRIPT" <<< "$P_TELEM" | strip_ansi)
case "$out_optout" in *'tagged'*) c=1 ;; *) c=0 ;; esac
assert "telem: CLAUDE_STATUSLINE_HIDE_TELEM=1 suppresses the chip" "$c"

# Unset and 0 both mean "show" — a bare -n test would invert the 0 case.
out_hide0=$(COLUMNS=120 HOME=/home/tester OTEL_RESOURCE_ATTRIBUTES='' \
  CLAUDE_STATUSLINE_HIDE_TELEM=0 bash "$SCRIPT" <<< "$P_TELEM" | strip_ansi)
case "$out_hide0" in *'untagged'*) c=0 ;; *) c=1 ;; esac
assert "telem: CLAUDE_STATUSLINE_HIDE_TELEM=0 still shows the chip" "$c"

# Suppressing the chip must not disturb the frame.
hide_bad=""
while IFS= read -r _len; do [ "$_len" -eq 112 ] || hide_bad=1; done <<< "$(printf '%s\n' "$out_optout" | vislen)"
assert "telem: suppressing the chip leaves the geometry intact" "$([ -z "$hide_bad" ] && echo 0 || echo 1)"

cd "$NONGIT" || exit 2
out_nongit=$(run_sl 120 "$P_NORMAL" | strip_ansi | sed -n 1p)
case "$out_nongit" in *'tagged'*) c=1 ;; *) c=0 ;; esac
assert "telem: no chip at all outside a git repo" "$c"

# ── Links ────────────────────────────────────────────────────────────────────
# Inside a repo: the remote (and therefore every link target) is only resolved
# when the process pwd is a working tree, so these cannot run from NONGIT.
cd "$TELEMREPO" || exit 2
P_LINK='{"workspace":{"current_dir":"/work/proj/x","repo":{"host":"github.com","owner":"TheGnarCo","name":"claude-statusline"}},'"$CTX"',"model":{"display_name":"Opus 4.8"}}'
linked=$(run_sl 120 "$P_LINK")
case "$linked" in *"${esc}]8;;https://github.com/TheGnarCo/claude-statusline"*) c=0 ;; *) c=1 ;; esac
assert "links: the repo title is an OSC8 hyperlink" "$c"
# Every link opens with an underline, so you can tell what is clickable.
case "$linked" in *"${esc}]8;;http"*"${esc}[4m"*) c=0 ;; *) c=1 ;; esac
assert "links: a hyperlink opens with an underline (SGR 4)" "$c"
case "$linked" in *"${esc}[24m"*) c=0 ;; *) c=1 ;; esac
assert "links: the underline is closed with SGR 24" "$c"

cmuxed=$(COLUMNS=120 HOME=/home/tester CMUX_SURFACE_ID=surface-1 \
  OTEL_RESOURCE_ATTRIBUTES='' bash "$SCRIPT" <<< "$P_LINK")
case "$cmuxed" in *"${esc}]8;;"*) c=1 ;; *) c=0 ;; esac
assert "links: cmux gets no OSC8 escape" "$c"
case "$cmuxed" in *'claude-statusline'*) c=0 ;; *) c=1 ;; esac
assert "links: cmux keeps the link text" "$c"
# The escape is zero-width, so dropping it must not move the frame.
cm_bad=""
while IFS= read -r _len; do [ "$_len" -eq 112 ] || cm_bad=1; done <<< "$(printf '%s\n' "$cmuxed" | strip_ansi | vislen)"
assert "links: cmux output keeps the same geometry" "$([ -z "$cm_bad" ] && echo 0 || echo 1)"

cd "$NONGIT" || exit 2

# ── Cache ────────────────────────────────────────────────────────────────────
# Keyed on session_id, so every case here supplies one AND its own TMPDIR — the
# suite must never read or write a real session's cache, and two cases must not
# see each other's entries.
CACHEDIR=$(mktemp -d)
P_SESS='{"session_id":"test-session-abc","workspace":{"current_dir":"/work/proj/x"},'"$CTX"',"model":{"display_name":"Opus 4.8"}}'

run_cached() { # run_cached <tmpdir> <session-payload> [extra-env-assignments...]
  local td=$1 payload=$2
  shift 2
  env TMPDIR="$td" COLUMNS=120 HOME=/home/tester COLORTERM=truecolor \
    NO_COLOR='' CMUX_SURFACE_ID='' OTEL_RESOURCE_ATTRIBUTES='' \
    CLAUDE_STATUSLINE_HIDE_TELEM='' "$@" bash "$SCRIPT" <<< "$payload"
}

# A render inside a repo writes exactly one entry, named for the session.
cd "$TELEMREPO" || exit 2
rm -rf "${CACHEDIR:?}/claude-statusline"
run_cached "$CACHEDIR" "$P_SESS" > /dev/null 2>&1
entries=$(find "$CACHEDIR/claude-statusline" -type f 2> /dev/null | wc -l | tr -d ' ')
assert "cache: a render writes one entry" "$([ "$entries" -eq 1 ] && echo 0 || echo 1)"
case "$(find "$CACHEDIR/claude-statusline" -type f 2> /dev/null)" in
  *test-session-abc-git) c=0 ;;
  *) c=1 ;;
esac
assert "cache: the entry is keyed on the session id" "$c"

# The cached render must equal the uncached one. A cache that changes what you
# see is worse than no cache, and this is the assertion that would catch a
# serialisation bug in the git state round-trip.
warm=$(run_cached "$CACHEDIR" "$P_SESS" | strip_ansi)
cold=$(run_cached "$CACHEDIR" "$P_SESS" CLAUDE_STATUSLINE_NO_CACHE=1 | strip_ansi)
assert "cache: a warm read renders identically to a cold gather" \
  "$([ "$warm" = "$cold" ] && echo 0 || echo 1)"

# TTL 0 means every render re-gathers, so the entry's timestamp keeps moving.
before=$(head -1 "$CACHEDIR/claude-statusline/test-session-abc-git")
run_cached "$CACHEDIR" "$P_SESS" CLAUDE_STATUSLINE_GIT_CACHE_TTL=0 > /dev/null 2>&1
after=$(head -1 "$CACHEDIR/claude-statusline/test-session-abc-git")
assert "cache: TTL 0 re-gathers rather than serving a hit" \
  "$([ -n "$after" ] && [ "$after" -ge "$before" ] && echo 0 || echo 1)"

# A hit must NOT refresh its own timestamp: if it did, a busy session would keep
# the entry alive forever and never re-read the working tree.
stamped=$(head -1 "$CACHEDIR/claude-statusline/test-session-abc-git")
run_cached "$CACHEDIR" "$P_SESS" CLAUDE_STATUSLINE_GIT_CACHE_TTL=600 > /dev/null 2>&1
still=$(head -1 "$CACHEDIR/claude-statusline/test-session-abc-git")
assert "cache: a hit does not refresh its own timestamp" \
  "$([ "$stamped" = "$still" ] && echo 0 || echo 1)"

# Opting out writes nothing at all.
OPTOUT=$(mktemp -d)
run_cached "$OPTOUT" "$P_SESS" CLAUDE_STATUSLINE_NO_CACHE=1 > /dev/null 2>&1
n=$(find "$OPTOUT/claude-statusline" -type f 2> /dev/null | wc -l | tr -d ' ')
assert "cache: CLAUDE_STATUSLINE_NO_CACHE=1 writes nothing" "$([ "$n" -eq 0 ] && echo 0 || echo 1)"
rm -rf "$OPTOUT"

# No session_id, no cache — the key would have to be guessed, so it is disabled.
NOSESS=$(mktemp -d)
P_NOSESS='{"workspace":{"current_dir":"/work/proj/x"},'"$CTX"',"model":{"display_name":"Opus 4.8"}}'
run_cached "$NOSESS" "$P_NOSESS" > /dev/null 2>&1
n=$(find "$NOSESS/claude-statusline" -type f 2> /dev/null | wc -l | tr -d ' ')
assert "cache: a payload without session_id writes nothing" "$([ "$n" -eq 0 ] && echo 0 || echo 1)"
rm -rf "$NOSESS"

# Concurrent sessions must not read each other's state.
P_SESS2=${P_SESS/test-session-abc/test-session-xyz}
run_cached "$CACHEDIR" "$P_SESS2" > /dev/null 2>&1
n=$(find "$CACHEDIR/claude-statusline" -type f 2> /dev/null | wc -l | tr -d ' ')
assert "cache: a second session gets its own entry" "$([ "$n" -eq 2 ] && echo 0 || echo 1)"

# A corrupt entry must degrade to a gather, not to a broken panel. This is the
# path a truncated write or a half-cleaned temp dir would take.
printf 'not-a-timestamp\ngarbage\n' > "$CACHEDIR/claude-statusline/test-session-abc-git"
corrupt=$(run_cached "$CACHEDIR" "$P_SESS" | strip_ansi)
c=1
case "$corrupt" in *'╭─'*) case "$corrupt" in *'CTX'*) c=0 ;; esac ;; esac
assert "cache: a corrupt entry falls back to a live gather" "$c"
cb=""
while IFS= read -r _len; do [ "$_len" -eq 112 ] || cb=1; done <<< "$(printf '%s\n' "$corrupt" | vislen)"
assert "cache: a corrupt entry leaves the geometry intact" "$([ -z "$cb" ] && echo 0 || echo 1)"

# An unwritable cache dir must not fail the render either.
RO=$(mktemp -d)
mkdir -p "$RO/claude-statusline"
chmod 500 "$RO/claude-statusline"
ro_out=$(run_cached "$RO" "$P_SESS" 2>&1)
case "$ro_out" in *'╭─'*) c=0 ;; *) c=1 ;; esac
assert "cache: an unwritable cache dir still renders" "$c"
chmod 700 "$RO/claude-statusline"
rm -rf "$RO"

rm -rf "$CACHEDIR"
cd "$NONGIT" || exit 2

# ── Chrome margin ────────────────────────────────────────────────────────────
wide_margin=$(COLUMNS=120 HOME=/home/tester CLAUDE_STATUSLINE_CHROME_MARGIN=0 \
  OTEL_RESOURCE_ATTRIBUTES='' bash "$SCRIPT" <<< "$P_NORMAL" | strip_ansi | sed -n 1p | vislen)
assert "margin: CHROME_MARGIN=0 fills the pane edge to edge" \
  "$([ "$wide_margin" -eq 120 ] && echo 0 || echo 1)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
