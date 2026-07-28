#!/usr/bin/env bash
# claude-statusline snapshot tests.
#
#   test/run.sh            # run all cases, diff against golden snapshots
#   test/run.sh --update   # regenerate the golden snapshots
#
# Most cases render in a throwaway NON-git temp dir so the git segments stay
# empty and output is fully determined by the payload + env (the process pwd,
# not the payload, drives git detection). One case renders in a throwaway git
# repo to exercise long-branch truncation. Content snapshots are ANSI-stripped
# (layout/content regressions — the class this suite exists to catch); color
# behavior is checked separately by presence/absence assertions.
#
# Determinism: HOME is pinned off-tree so dir_display never abbreviates to '~',
# resets_at is a far-future sentinel so "time left" pins to the full window and
# cancels out the real clock, and COLUMNS is fixed per case.

set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$(pwd)
SCRIPT="$ROOT/statusline.sh"
GOLDEN_DIR="$ROOT/test/golden"
mkdir -p "$GOLDEN_DIR"

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

FAR_FUTURE=9999999999 # resets_at sentinel (year 2286): always in the future
PASS=0 FAIL=0

strip_ansi() { sed $'s/\033\[[0-9;]*m//g; s/\033\]8;;[^\007]*\007//g'; }

# run_sl <cols> <payload>  — render in the current directory with pinned env.
run_sl() {
  COLUMNS=$1 HOME=/home/tester COLORTERM=truecolor TERM=xterm-256color \
    NO_COLOR='' CMUX_SURFACE_ID='' CMUX_BUNDLE_ID='' \
    CLAUDE_AUTOCOMPACT_PCT_OVERRIDE='' CLAUDE_STATUSLINE_CHROME_MARGIN='' \
    bash "$SCRIPT" <<< "$2"
}

# run_sl_256 <cols> <payload> — run_sl with COLORTERM cleared, to exercise the
# indexed-ramp path. Same pinned env, which is the point: an ambient NO_COLOR in
# the developer's shell must not make a *color* assertion fail for the wrong
# reason (NO_COLOR is one this repo's own users plausibly export).
run_sl_256() {
  COLUMNS=$1 HOME=/home/tester COLORTERM='' TERM=xterm-256color \
    NO_COLOR='' CMUX_SURFACE_ID='' CMUX_BUNDLE_ID='' \
    CLAUDE_AUTOCOMPACT_PCT_OVERRIDE='' CLAUDE_STATUSLINE_CHROME_MARGIN='' \
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
  if diff -u "$golden" <(printf '%s\n' "$actual") > /tmp/sl_diff.$$ 2>&1; then
    printf 'ok       %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL     %s\n' "$name"
    cat /tmp/sl_diff.$$
    FAIL=$((FAIL + 1))
  fi
  rm -f /tmp/sl_diff.$$
}

# assert <name> <cond-desc> — bump counters from an externally evaluated result.
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

P_NORMAL='{'"$DIR"',"context_window":{"used_percentage":42,"total_input_tokens":420000,"context_window_size":1000000,"current_usage":{"cache_read_input_tokens":360000}},"model":{"display_name":"Opus 4.8 (1M context)"},"effort":{"level":"high"},"output_style":{"name":"Explanatory"},"cost":{"total_cost_usd":1.23,"total_duration_ms":600000},"pr":{"number":3,"review_state":"changes_requested"},"rate_limits":{"five_hour":{"used_percentage":73,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":45,"resets_at":'"$FAR_FUTURE"'}}}'

P_SEVEN_BINDING='{'"$DIR"',"context_window":{"used_percentage":20,"total_input_tokens":40000,"context_window_size":200000},"model":{"display_name":"Sonnet 5"},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":60,"resets_at":'"$FAR_FUTURE"'}}}'

# 7d binding but BELOW the Fable weekly cap (40% used, still busier than 5h): the
# 'f' landmark sits ahead of the fill, in the track. Pairs with seven-binding
# (60%, past the cap) where it sits inside the filled run.
P_SEVEN_BELOW_CAP='{'"$DIR"',"context_window":{"used_percentage":20,"total_input_tokens":40000,"context_window_size":200000},"model":{"display_name":"Sonnet 5"},"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":40,"resets_at":'"$FAR_FUTURE"'}}}'

P_AUTOCOMPACT='{'"$DIR"',"context_window":{"used_percentage":82,"total_input_tokens":170000,"context_window_size":200000,"current_usage":{"cache_read_input_tokens":120000}},"exceeds_200k_tokens":true,"model":{"display_name":"Sonnet 5"},"effort":{"level":"medium"},"cost":{"total_cost_usd":0.44,"total_duration_ms":120000},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":12,"resets_at":'"$FAR_FUTURE"'}}}'

P_NEAR_AC='{'"$DIR"',"context_window":{"used_percentage":70,"total_input_tokens":140000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"},"effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":5,"resets_at":'"$FAR_FUTURE"'}}}'

P_FRESH='{"workspace":{"current_dir":"/work/scratch/tmp"},"context_window":{"used_percentage":3,"total_input_tokens":8000,"context_window_size":200000},"model":{"display_name":"Haiku 4.5"}}'

# Rich line-1: agent.name (wins over session_name), vim mode, and the xhigh effort
# tier — exercises the fields folded onto line 1 by the compact layout. agent name
# -> [name] chip; vim NORMAL -> [N]; effort xhigh -> "XHi" (not "Xhigh").
P_RICH='{'"$DIR"',"session_name":"mine","agent":{"name":"reviewer"},"vim":{"mode":"NORMAL"},"context_window":{"used_percentage":42,"total_input_tokens":420000,"context_window_size":1000000,"current_usage":{"cache_read_input_tokens":360000}},"model":{"display_name":"Opus 4.8 (1M context)"},"effort":{"level":"xhigh"},"output_style":{"name":"Explanatory"},"cost":{"total_cost_usd":1.23,"total_duration_ms":600000},"rate_limits":{"five_hour":{"used_percentage":73,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":45,"resets_at":'"$FAR_FUTURE"'}}}'

# ── Cases (non-git) ────────────────────────────────────────────────────────
NONGIT=$(mktemp -d)
trap 'rm -rf "$NONGIT" "$GITREPO"' EXIT
cd "$NONGIT" || exit 2

snapshot normal 120 "$P_NORMAL"
snapshot seven-binding 120 "$P_SEVEN_BINDING"
snapshot seven-below-cap 120 "$P_SEVEN_BELOW_CAP"
snapshot autocompact 120 "$P_AUTOCOMPACT"
snapshot near-ac 120 "$P_NEAR_AC"
snapshot fresh-no-rate 120 "$P_FRESH"
snapshot narrow 60 "$P_NORMAL"
snapshot rich-line1 120 "$P_RICH"

# ── Color-mode assertions (non-git) ─────────────────────────────────────────
esc=$(printf '\033')

out_color=$(run_sl 120 "$P_NORMAL")
case "$out_color" in *"${esc}["*) c=0 ;; *) c=1 ;; esac
assert "color: emits ANSI by default" "$c"

out_nocolor=$(COLUMNS=120 HOME=/home/tester NO_COLOR=1 bash "$SCRIPT" <<< "$P_NORMAL")
case "$out_nocolor" in *"${esc}["*) c=1 ;; *) c=0 ;; esac
assert "NO_COLOR: emits no ANSI" "$c"
# ...and the plain content still renders (bar fill + a known token present).
case "$out_nocolor" in *"420k/1M"*) c=0 ;; *) c=1 ;; esac
assert "NO_COLOR: content intact" "$c"

# Non-truecolor terminals get the 256-color ramp (38;5;) not truecolor (38;2;).
out_256=$(run_sl_256 120 "$P_NORMAL")
case "$out_256" in *"${esc}[38;5;"*) c=0 ;; *) c=1 ;; esac
assert "256-color: uses indexed ramp" "$c"
case "$out_256" in *"${esc}[38;2;"*) c=1 ;; *) c=0 ;; esac
assert "256-color: no truecolor escapes" "$c"

# Must always exit 0 — in BOTH 7d states (the trailing conditional is a trap).
run_sl 120 "$P_NORMAL" > /dev/null
assert "exit 0 when 7d hidden" "$?"
run_sl 120 "$P_SEVEN_BINDING" > /dev/null
assert "exit 0 when 7d shown" "$?"

# ── Fable weekly-cap landmark: 7d bar only ──────────────────────────────────
# The cap is weekly, so the 'f' cell belongs to the 7d bar and must never leak
# onto the 5h or CTX one. Asserted directly (not just via the goldens) because
# the regression this guards is a leak into a bar that shouldn't carry it.
#
# Scope the match to the BAR field, not the line: the trailing text contains an
# 'f' of its own ("N left"), so a whole-line grep reports a false leak. The bar
# is whitespace-delimited field 2 on every bar line, and contains no spaces.
bar_of() { printf '%s\n' "$1" | awk -v l="$2" '$1 == l { print $2 }'; }

# An ABSENCE check must not pass vacuously: `case "" in *f*)` falls through to
# "no f", so a bar_of that extracts nothing (label rename, an extra leading
# field) would silently disable these checks and read as "no leak". Require a
# bar-shaped field first — every bar has track or fill pips — so a broken
# extraction fails loudly instead of going quietly green.
fable_absent() {
  case "$1" in *[-#]*) ;; *) return 1 ;; esac # nothing bar-shaped extracted
  case "$1" in *f*) return 1 ;; esac
  return 0
}
sb_out=$(run_sl 120 "$P_SEVEN_BINDING" | strip_ansi)
case "$(bar_of "$sb_out" 7d)" in *f*) c=0 ;; *) c=1 ;; esac
assert "fable: landmark present on the 7d bar" "$c"
fable_absent "$(bar_of "$sb_out" 5h)"
assert "fable: landmark absent from the 5h bar" "$?"
fable_absent "$(bar_of "$sb_out" CTX)"
assert "fable: landmark absent from the CTX bar" "$?"
# ...and it's actually colored (a stripped snapshot can't tell FABLE="" apart).
# Both color paths need their own assertion: FABLE is defined once per branch, so
# a truecolor-only check leaves the 256 entry free to be deleted with the suite
# still green — the same one-of-two-paths gap as the priority rule below.
case "$(run_sl 120 "$P_SEVEN_BINDING")" in *"${esc}[38;2;214;122;255m"*) c=0 ;; *) c=1 ;; esac
assert "fable: landmark colored on the truecolor path" "$c"
fable_256=$(run_sl_256 120 "$P_SEVEN_BINDING")
case "$fable_256" in *"${esc}[38;5;177m"*) c=0 ;; *) c=1 ;; esac
assert "fable: landmark colored on the 256 ramp" "$c"

# Cell-collision priority: clock > projection > Fable landmark. The clock and the
# landmark both index as pct*N/100, so a clock at 50% lands on exactly the
# landmark cell for ANY bar width — this collision is guaranteed, not width-luck.
# Needs a live resets_at (half a 7d window out) because the FAR_FUTURE sentinel
# pins the clock to 0%; that makes "time left" wall-clock-dependent, so this is
# an assertion rather than a snapshot.
HALF_7D=$(($(date +%s) + 5040 * 60))
P_CLOCK_COLLIDE='{'"$DIR"',"context_window":{"used_percentage":20,"total_input_tokens":40000,"context_window_size":200000},"model":{"display_name":"Sonnet 5"},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":60,"resets_at":'"$HALF_7D"'}}}'
collide_bar=$(bar_of "$(run_sl 120 "$P_CLOCK_COLLIDE" | strip_ansi)" 7d)
fable_absent "$collide_bar"
assert "fable: yields its cell to the clock pip" "$?"
case "$collide_bar" in *'|'*) c=0 ;; *) c=1 ;; esac
assert "fable: ...and the clock pip renders there instead" "$c"

# ...and the other half of the priority rule: projection also outranks the
# landmark. Needs its own payload, since the clock case above pins proj to 120%
# (overflow, last cell) and never contends for cell 50. At 20% used with 60% of
# the window left the clock is 40% and the projection is 20*100/40 = 50 — landing
# the '*' exactly on the landmark cell, again for any bar width.
SIXTY_PCT_7D=$(($(date +%s) + 6048 * 60))
P_PROJ_COLLIDE='{'"$DIR"',"context_window":{"used_percentage":20,"total_input_tokens":40000,"context_window_size":200000},"model":{"display_name":"Sonnet 5"},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":20,"resets_at":'"$SIXTY_PCT_7D"'}}}'
proj_bar=$(bar_of "$(run_sl 120 "$P_PROJ_COLLIDE" | strip_ansi)" 7d)
fable_absent "$proj_bar"
assert "fable: yields its cell to the projection pip" "$?"
case "$proj_bar" in *'*'*) c=0 ;; *) c=1 ;; esac
assert "fable: ...and the projection pip renders there instead" "$c"

# ── Width discipline: no line may exceed COLUMNS ─────────────────────────────
# The bars stretch to fill the row, so the width math must reserve room for each
# line's *trailing* text (the CTX token/cache/AC/200k+ readout is the widest and
# once ran the bar off the right edge). This is the regression guard for that:
# render at many widths, incl. a worst-case CTX payload, and fail if the visible
# (ANSI-stripped) width of ANY line exceeds COLUMNS. Runs in the non-git temp dir
# so line 1 stays short and the bar lines are what's under test.
#
# Floor at 60 cols: MIN_PIP_COUNT keeps the bar readable (>=12 pips) rather than
# collapsing it, so a very narrow pane whose fixed readout is itself wider than
# the pane will still overflow by design — that's the readable-bar backstop, not
# a width-math bug. 60 is the narrowest width the snapshot cases exercise.
P_WIDE='{'"$DIR"',"context_window":{"used_percentage":92,"total_input_tokens":185000,"context_window_size":200000,"current_usage":{"cache_read_input_tokens":185000}},"exceeds_200k_tokens":true,"model":{"display_name":"Opus 4.8"},"effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":63,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":80,"resets_at":'"$FAR_FUTURE"'}}}'
widest_line() { awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'; }
overflow=0
for pw in "$P_NORMAL" "$P_AUTOCOMPACT" "$P_WIDE"; do
  for w in 60 80 100 120 160 200; do
    max=$(run_sl "$w" "$pw" | strip_ansi | widest_line)
    [ "$max" -gt "$w" ] && overflow=1
  done
done
assert "width: no line exceeds COLUMNS (all payloads/widths)" "$overflow"

# ── Long-branch truncation (git) ────────────────────────────────────────────
GITREPO=$(mktemp -d)
# core.hooksPath=/dev/null + --no-verify keep any globally-configured hooks
# (e.g. gitleaks) from firing and leaking output into the test run.
(
  cd "$GITREPO" || exit 2
  git init -q
  git checkout -q -b feature/some-really-long-branch-name-goes-here 2> /dev/null
  : > f.txt
  git add f.txt
  git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q --no-verify -m init
) > /dev/null 2>&1 || {
  printf 'FAIL     git fixture setup\n'
  FAIL=$((FAIL + 1))
}
cd "$GITREPO" || exit 2
# Payload supplies a stable title dir; git supplies the (long) branch.
P_LONGBRANCH='{"workspace":{"current_dir":"/work/proj/claude-statusline"},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"}}'
snapshot longbranch-trunc 100 "$P_LONGBRANCH"

# ── Line 1 hard-bound + wrap (git, dirty, long branch) ───────────────────────
# Dirty the repo so line 1 carries branch + counters + lines-changed groups;
# with the long branch that's wider than a narrow pane, this exercises the wrap
# to a continuation line. Line 1 must never exceed COLUMNS at any width, and the
# 60-col snapshot locks the wrapped layout.
: > untracked.txt    # -> "1 untracked"
echo change >> f.txt # -> "1 modified" (unstaged)
P_DIRTY='{"workspace":{"current_dir":"/work/proj/claude-statusline"},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"},"cost":{"total_lines_added":120,"total_lines_removed":45}}'
l1_overflow=0
for w in 60 80 100 120 160; do
  max=$(run_sl "$w" "$P_DIRTY" | strip_ansi | widest_line)
  [ "$max" -gt "$w" ] && l1_overflow=1
done
assert "width: line 1 hard-bounds (git dirty, long branch)" "$l1_overflow"
snapshot line1-wrap 60 "$P_DIRTY"

# ── Summary ──────────────────────────────────────────────────────────────────
cd "$ROOT" || exit 2
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
