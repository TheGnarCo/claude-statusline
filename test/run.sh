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
# cancels out the real clock, COLUMNS is fixed per case, and
# OTEL_RESOURCE_ATTRIBUTES is pinned empty so the telem-tag chip answers to the
# fixture alone — not to whether the session running the suite is itself tagged
# (this repo is, CI isn't, and that would otherwise flip the git goldens).

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

P_AUTOCOMPACT='{'"$DIR"',"context_window":{"used_percentage":82,"total_input_tokens":170000,"context_window_size":200000,"current_usage":{"cache_read_input_tokens":120000}},"exceeds_200k_tokens":true,"model":{"display_name":"Sonnet 5"},"effort":{"level":"medium"},"cost":{"total_cost_usd":0.44,"total_duration_ms":120000},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":12,"resets_at":'"$FAR_FUTURE"'}}}'

P_NEAR_AC='{'"$DIR"',"context_window":{"used_percentage":70,"total_input_tokens":140000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"},"effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":5,"resets_at":'"$FAR_FUTURE"'}}}'

P_FRESH='{"workspace":{"current_dir":"/work/scratch/tmp"},"context_window":{"used_percentage":3,"total_input_tokens":8000,"context_window_size":200000},"model":{"display_name":"Haiku 4.5"}}'

# Rich line-1: agent.name (wins over session_name), vim mode, and the xhigh effort
# tier — exercises the fields folded onto line 1 by the compact layout, and locks
# the concept grouping: agent name joins churn/cost in the session group, vim
# NORMAL -> "N" joins the config group, effort xhigh -> "XHi" (not "Xhigh").
P_RICH='{'"$DIR"',"session_name":"mine","agent":{"name":"reviewer"},"vim":{"mode":"NORMAL"},"context_window":{"used_percentage":42,"total_input_tokens":420000,"context_window_size":1000000,"current_usage":{"cache_read_input_tokens":360000}},"model":{"display_name":"Opus 4.8 (1M context)"},"effort":{"level":"xhigh"},"output_style":{"name":"Explanatory"},"cost":{"total_cost_usd":1.23,"total_duration_ms":600000},"rate_limits":{"five_hour":{"used_percentage":73,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":45,"resets_at":'"$FAR_FUTURE"'}}}'

# ── Cases (non-git) ────────────────────────────────────────────────────────
NONGIT=$(mktemp -d)
# Pre-declared so the trap body is safe under `set -u` from the moment it's armed:
# these are assigned ~100 lines below, and an early `exit 2` before then would
# otherwise abort the trap on an unbound variable and clean up nothing.
GITREPO="" TELEMREPO=""
trap 'rm -rf "$NONGIT" "$GITREPO" "$TELEMREPO"' EXIT
cd "$NONGIT" || exit 2

snapshot normal 120 "$P_NORMAL"
snapshot seven-binding 120 "$P_SEVEN_BINDING"
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
out_256=$(COLUMNS=120 HOME=/home/tester COLORTERM='' TERM=xterm-256color bash "$SCRIPT" <<< "$P_NORMAL")
case "$out_256" in *"${esc}[38;5;"*) c=0 ;; *) c=1 ;; esac
assert "256-color: uses indexed ramp" "$c"
case "$out_256" in *"${esc}[38;2;"*) c=1 ;; *) c=0 ;; esac
assert "256-color: no truecolor escapes" "$c"

# Must always exit 0 — in BOTH 7d states (the trailing conditional is a trap).
run_sl 120 "$P_NORMAL" > /dev/null
assert "exit 0 when 7d hidden" "$?"
run_sl 120 "$P_SEVEN_BINDING" > /dev/null
assert "exit 0 when 7d shown" "$?"

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
# NOT `( ... ) || { ... }`: bash suppresses set -e inside a compound command
# that is the left operand of ||, and without it the subshell's status is just
# its last command's — so that guard could never fire and the asserts below it
# went vacuous. Capture the status instead.
if [ "$fixture_st" -ne 0 ]; then
  printf 'FAIL     git fixture setup (exit %s)\n' "$fixture_st"
  FAIL=$((FAIL + 1))
fi
cd "$GITREPO" || exit 2
# Payload supplies a stable title dir; git supplies the (long) branch.
P_LONGBRANCH='{"workspace":{"current_dir":"/work/proj/claude-statusline"},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"}}'
snapshot longbranch-trunc 100 "$P_LONGBRANCH"

# ── Repo title: owner/name (git) ─────────────────────────────────────────────
# Claude Code's structured workspace.repo payload is the preferred source for the
# title, and it's what makes it owner/name rather than a bare name. Snapshotted
# while the fixture repo is still clean, so the title is the only moving part.
P_REPO='{"workspace":{"current_dir":"/work/proj/claude-statusline","repo":{"host":"github.com","owner":"TheGnarCo","name":"claude-statusline"}},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"}}'
snapshot repo-title 100 "$P_REPO"

# ── Line 1 hard-bound + wrap (git, dirty, long branch) ───────────────────────
# Dirty the repo so line 1 carries the git group (branch + counters) and the
# session group (lines changed); with the long branch that's wider than a narrow
# pane, this exercises the wrap to a continuation line. Line 1 must never exceed
# COLUMNS at any width, and the 60-col snapshot locks the wrapped layout — plus
# the invariant that branch and counters share ONE bracket.
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

# ── Line 1 must fit the USABLE row, and groups must shed ─────────────────────
# Two gaps the assertion above cannot close:
#
#   1. It bounds line 1 by COLUMNS, but line 1's real budget is COLUMNS minus
#      CHROME_MARGIN (8) — overrunning the margin re-triggers the very wrap that
#      margin exists to prevent, while staying under COLUMNS.
#   2. P_DIRTY is the NARROWEST form of the two groups that got wider when
#      per-field brackets merged into per-concept ones: no session name, no cost,
#      no worktree, and only "?1 !1".
#
# So this bounds the line-1 block by COLUMNS-8 against a worst case: a long
# session name + 5-digit churn + a 6-figure cost sharing ONE bracket, and a long
# branch + worktree + counters sharing another. A group is unsplittable (the
# packer relocates whole segments, it never breaks one open), so gflush has to
# shed members — the same path that sheds counters from an over-wide git group.
# Scoped to the line-1 block (everything before the CTX line) so the
# MIN_PIP_COUNT bar floor at narrow widths can't false-fail it.
# Derived from the script, not restated: hardcoding 8 here would silently check
# the wrong budget if CHROME_MARGIN's default ever changed. run_sl pins
# CLAUDE_STATUSLINE_CHROME_MARGIN='' so the script's own default is what applies.
L1_MARGIN=$(awk -F= '/^CHROME_MARGIN=/ {print $2; exit}' "$SCRIPT")
case "$L1_MARGIN" in '' | *[!0-9]*)
  printf 'FAIL     could not read CHROME_MARGIN default\n'
  FAIL=$((FAIL + 1))
  L1_MARGIN=8
  ;;
esac
line1_block() { awk '/^CTX /{exit} {print}'; }
# worktree.name is set deliberately: without it the git group's first member is
# just "@branch", and the widest form — "@branch/worktree", which gflush can never
# shed because it is the first member — would go unmeasured.
P_L1_MAX='{"workspace":{"current_dir":"/work/proj/claude-statusline"},"worktree":{"name":"a-long-worktree-name-here"},"session_name":"refactor-the-whole-statusline-experiment","context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":1000000},"model":{"display_name":"Opus 4.8 (1M context)"},"effort":{"level":"xhigh"},"output_style":{"name":"Explanatory"},"vim":{"mode":"NORMAL"},"cost":{"total_cost_usd":123456.78,"total_duration_ms":600000,"total_lines_added":98765,"total_lines_removed":43210}}'
#
# The narrow end (24, 26) is load-bearing: branch_max's 14-col floor can exceed
# the row itself there, and it caps every group's FIRST member — the one gflush
# can never shed — so an unclamped floor overran the row on that member alone
# (19 cols into a 14-col budget at COLUMNS=22). Sweeping only 60+ missed it.
#
# P_L1_MAX_NONAME drops session_name, which is the DEFAULT state and shifts the
# session group's first member from the capped name to the untruncated churn/cost
# string — a hole neither other payload reaches (P_L1_MAX always sets the name,
# P_DIRTY's churn is only 10 columns). The cost cell rendered 19 columns into a
# 16-column budget before the per-hour burn learned to drop itself.
# Dropping the name is NOT enough on its own: P_L1_MAX still has churn, which
# becomes the first member and shields the cost behind gflush's shedding. The cost
# has to be ALONE in its group to be the first member, which is the ordinary shape
# of a session that has spent money without editing files.
P_L1_COST_ONLY='{"workspace":{"current_dir":"/work/proj/claude-statusline"},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"},"cost":{"total_cost_usd":12.34,"total_duration_ms":600000}}'
# 6-digit churn with no name: churn leads the group, and digits are the one member
# that cannot be ellipsized (a truncated number reads as a real one), so it
# abbreviates instead. Also guards the marker: at COLUMNS=26 an over-wide first
# member made the best-effort " .." gate suppress the marker on a real drop.
P_L1_CHURN_BIG='{"workspace":{"current_dir":"/work/proj/claude-statusline"},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"},"cost":{"total_cost_usd":1.23,"total_duration_ms":600000,"total_lines_added":123456,"total_lines_removed":654321}}'
l1_budget_overflow=0
for pw in "$P_DIRTY" "$P_L1_MAX" "$P_L1_COST_ONLY" "$P_L1_CHURN_BIG"; do
  for w in 24 26 30 40 60 80 100 120 160 200; do
    max=$(run_sl "$w" "$pw" | strip_ansi | line1_block | widest_line)
    [ "$max" -gt $((w - L1_MARGIN)) ] && l1_budget_overflow=1
  done
done
assert "width: line 1 fits COLUMNS-CHROME_MARGIN (worst-case groups)" "$l1_budget_overflow"

# ...and the elision is visible rather than a silent drop: locks the '..' marker.
snapshot line1-shed 60 "$P_L1_MAX"

# ── All seven counters: the git group's squeeze path ────────────────────────
# The fixtures above carry only "?1 !1", so ct_width stays 6 and the name-squeeze
# block never runs — the git group's core logic had ZERO coverage, which is how a
# silent counter drop shipped. This fixture carries all seven at once, which needs
# a real upstream (ahead/behind), a stash, and a conflicted merge:
#
#   x conflict  ^ ahead  v behind  ! modified  + staged  ? untracked  *stash
#
# That order is the invariant the assertions below enforce: it is most-urgent
# first, and since gflush sheds from the tail it is also least-urgent-lost-first.
#
# The invariant under test is priority, not just width: inside one unsplittable
# bracket a counter is atomic data while the names ellipsize, so EVERY counter
# must survive at every width — the branch shrinks, then the worktree suffix is
# dropped, before a counter is ever shed. A dropped ^N/vN reads as "in sync with
# upstream" when you are not, which is worse than a truncated name.
COUNTERS=$(mktemp -d) BARE=$(mktemp -d) CLONE=$(mktemp -d)
trap 'rm -rf "$NONGIT" "$GITREPO" "$COUNTERS" "$BARE" "$CLONE" "$TELEMREPO"' EXIT
tg() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
(
  set -e # without this the subshell's status is its LAST command's, so the
  # `|| { FAIL ... }` guard below never fires and the asserts go vacuous
  git init -q --bare "$BARE/claude-statusline.git"
  cd "$COUNTERS" || exit 2
  git init -q
  git checkout -q -b feature/some-really-long-branch-name
  for i in 1 2 3 4; do echo "l$i" > "f$i.txt"; done
  tg add .
  tg commit -q --no-verify -m init
  tg remote add origin "$BARE/claude-statusline.git"
  tg push -q -u origin HEAD
  # ahead: local commits the remote hasn't seen
  for i in 1 2 3; do
    echo "a$i" >> f1.txt
    tg commit -q --no-verify -am "ahead$i"
  done
  # behind: a second clone pushes, then we fetch (never merge those)
  git clone -q "$BARE/claude-statusline.git" "$CLONE/c"
  cd "$CLONE/c" || exit 2
  git checkout -q feature/some-really-long-branch-name
  for i in 1 2; do
    echo "r$i" >> f4.txt
    tg commit -q --no-verify -am "remote$i"
  done
  tg push -q origin HEAD
  cd "$COUNTERS" || exit 2
  tg fetch -q origin
  # stash x2
  echo s1 > f2.txt && tg stash push -q -m s1
  echo s2 > f2.txt && tg stash push -q -m s2
  # conflict: merge the diverged upstream and leave the UU in the index
  echo mine >> f4.txt
  tg commit -q --no-verify -am mine
  # Expected to exit non-zero — the conflict IS the point, and under set -e it
  # would otherwise abort the fixture before the staged/modified/untracked steps.
  tg merge -q origin/feature/some-really-long-branch-name || true
  # staged, modified, untracked
  echo st > f2.txt && tg add f2.txt
  echo mo >> f3.txt
  : > untracked1.txt
  : > untracked2.txt
) > /dev/null 2>&1
fixture_st=$?
# NOT `( ... ) || { ... }`: bash suppresses set -e inside a compound command
# that is the left operand of ||, and without it the subshell's status is just
# its last command's — so that guard could never fire and the asserts below it
# went vacuous. Capture the status instead.
if [ "$fixture_st" -ne 0 ]; then
  printf 'FAIL     all-counters git fixture setup (exit %s)\n' "$fixture_st"
  FAIL=$((FAIL + 1))
fi
cd "$COUNTERS" || exit 2

# Sanity-check the fixture itself: if it stopped producing all seven counters the
# assertions below would pass vacuously (the bug this suite exists to catch).
P_CT='{"workspace":{"current_dir":"/work/proj/claude-statusline"},"worktree":{"name":"a-long-worktree-name"},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"}}'
ct_line=$(run_sl 200 "$P_CT" | strip_ansi | line1_block)
missing=""
for sig in '*' x '?' '!' + '^' v; do
  case "$ct_line" in *"$sig"[0-9]*) ;; *) missing="$missing$sig" ;; esac
done
[ -n "$missing" ] && printf 'note: fixture missing counters: %s\n' "$missing"
assert "fixture: all seven counters present at full width" "$([ -z "$missing" ] && echo 0 || echo 1)"

# Two assertions, because "no counter is ever shed" is not achievable at every
# width and claiming it would be a lie: seven counters are 21 columns on their
# own, so at COLUMNS=30 (22 usable) they cannot fit beside even a floored branch
# — something must go. What IS invariant is the ORDER things go in.
#
#   1. Down to COLUMNS=40, every counter survives (the names absorb it).
#   2. At ANY width, a counter is shed only AFTER the names have already given up
#      everything they can: no worktree suffix, and the branch at its 5-char
#      floor. That is the priority rule itself, and it holds where (1) can't.
ct_dropped=0 ct_overflow=0
for w in 40 44 48 57 60 80 120; do
  out=$(run_sl "$w" "$P_CT" | strip_ansi | line1_block)
  for sig in '*' x '?' '!' + '^' v; do
    case "$out" in *"$sig"[0-9]*) ;; *) ct_dropped=1 ;; esac
  done
  max=$(printf '%s\n' "$out" | widest_line)
  [ "$max" -gt $((w - L1_MARGIN)) ] && ct_overflow=1
done
assert "git group: no counter shed down to COLUMNS=40 (all 7)" "$ct_dropped"
assert "git group: line 1 fits its budget with all 7 counters" "$ct_overflow"

# Priority rule at the widths where shedding IS forced: the names must be spent
# first. Extract the branch member "@<branch>[/<wt>]" and require no "/" (the
# worktree suffix dropped) and a branch at the 5-char floor whenever a counter
# went missing.
ct_priority=0 ct_forced=0
for w in 24 26 30 34 36 38; do
  out=$(run_sl "$w" "$P_CT" | strip_ansi | line1_block)
  shed=0
  for sig in '*' x '?' '!' + '^' v; do
    case "$out" in *"$sig"[0-9]*) ;; *) shed=1 ;; esac
  done
  [ "$shed" -eq 0 ] && continue
  ct_forced=1
  bmem=$(printf '%s\n' "$out" | sed -n 's/.*\[@\([^] ]*\).*/\1/p' | head -1)
  case "$bmem" in
    *'/'*) ct_priority=1 ;; # worktree still shown while a counter was dropped
  esac
  [ "${#bmem}" -gt 5 ] && ct_priority=1 # branch not squeezed to its floor
done
assert "git group: names are spent before any counter is shed" "$ct_priority"
assert "git group: the forced-shed widths are actually exercised" "$((1 - ct_forced))"

# Locks the squeeze: at 40 the worktree suffix is gone but every counter remains.
snapshot line1-counters 40 "$P_CT"

# A SHORT worktree name must never be dropped while it still fits. The payload
# above carries a 20-char name, so the budget maths was only ever exercised where
# dropping was correct; sizing from the 5-col floor instead of the actual length
# threw away a 2-char suffix with room to spare. Also asserts monotonicity: a
# wider pane must never show LESS than a narrower one.
P_CT_SHORTWT=${P_CT/\"name\":\"a-long-worktree-name\"/\"name\":\"wt\"}
shortwt_dropped=0
for w in 26 30 34 38 42 44 48 60 80; do
  out=$(run_sl "$w" "$P_CT_SHORTWT" | strip_ansi | line1_block)
  # Slack is measured on the GIT GROUP'S OWN line, not the widest line of the
  # block: another group's continuation line is wider and would under-report the
  # room actually available to this one.
  gline=$(printf '%s\n' "$out" | grep '\[@' || true)
  used=$(printf '%s\n' "$gline" | widest_line)
  has=0
  case "$out" in *'/wt'*) has=1 ;; esac
  if [ "$has" -eq 0 ] && [ $((used + 3)) -le $((w - L1_MARGIN)) ]; then
    shortwt_dropped=1
    printf 'note: /wt dropped at COLUMNS=%s with %s cols used of %s\n' \
      "$w" "$used" "$((w - L1_MARGIN))"
  fi
done
assert "git group: a short worktree name is kept whenever it fits" "$shortwt_dropped"

# Worktree visibility is NOT strictly monotonic, and asserting that it is would be
# asserting something false. `need` is want_b + 1 + want_w, capped by branch_max
# (cols/3) and wt_max (cols/5); at cols divisible by 15 BOTH caps step, so need
# grows by 2 while avail grows by 1, and the suffix drops out for exactly one
# column (shown at COLUMNS 52, gone at 53, back at 54 with a long branch + a
# >=9-char worktree). Two progressions of period 3 and 5 collide every 15 columns,
# so no choice of independent proportional caps avoids it; the alternatives trade
# it for a 1-column dip in BRANCH length instead, which is the worse of the two
# (the branch is the more informative cell, and its monotonicity is relied on
# above).
#
# So assert the invariant that is true and still catches a real regression: the
# suffix never vanishes for more than one consecutive column, and once the pane is
# wide enough it stays. A permanent disappearance — the actual bug class — fails
# here. Swept every column with a LONG worktree name, since a short one never lets
# wt_max bind and so never reaches this path at all.
# Runs of "not shown" at the narrow end are legitimate (it genuinely does not
# fit), so only a gap appearing AFTER the suffix has started showing counts.
P_CT_LONGWT=${P_CT/'"name":"a-long-worktree-name"'/'"name":"wt-abcd-ch"'}
seen=0 gap=0 run=0
# cols 36-58: consecutive columns, spanning the mod-15 point at cols 45.
for w in $(seq 44 1 66); do
  out=$(run_sl "$w" "$P_CT_LONGWT" | strip_ansi | line1_block)
  if case "$out" in *'/wt'*) true ;; *) false ;; esac then
    seen=1 run=0
  elif [ "$seen" -eq 1 ]; then
    run=$((run + 1))
    [ "$run" -gt 1 ] && gap=1 && printf 'note: /wt missing for %s consecutive columns at COLUMNS=%s\n' "$run" "$w"
  fi
done
assert "git group: worktree suffix never vanishes for >1 consecutive column" "$gap"
assert "git group: the worktree suffix does appear at some swept width" "$((1 - seen))"

# ── Repo title: owner from the origin remote (git, fallback path) ─────────────
# Back to the long-branch fixture: the all-counters repo above already has an
# origin (its bare upstream), so `git remote add` there would fail and these would
# assert against the wrong repo.
cd "$GITREPO" || exit 2
# With no workspace.repo in the payload the owner comes from parsing origin, so the
# two sources must agree. And the parse must stay conservative: a remote whose path
# has no owner segment must not promote the *host* into that slot.
git remote add origin https://github.com/TheGnarCo/claude-statusline.git 2> /dev/null
case "$(run_sl 100 "$P_DIRTY" | strip_ansi)" in *'TheGnarCo/claude-statusline'*) c=0 ;; *) c=1 ;; esac
assert "title: owner parsed from the origin remote" "$c"

git remote set-url origin https://example.com/toplevel 2> /dev/null
out_noowner=$(run_sl 100 "$P_DIRTY" | strip_ansi)
case "$out_noowner" in *'example.com/'*) c=1 ;; *'toplevel'*) c=0 ;; *) c=1 ;; esac
assert "title: ownerless remote falls back to the bare repo name" "$c"

# Paths deeper than <owner>/<repo> are common (GitLab subgroups, Bitbucket's
# /scm/<project>/<repo>). The owner is the segment immediately before the repo —
# taking the first one promoted a prefix into the owner slot ("scm/myrepo").
git remote set-url origin https://bitbucket.example.com/scm/PROJ/myrepo.git 2> /dev/null
case "$(run_sl 100 "$P_DIRTY" | strip_ansi)" in *'PROJ/myrepo'*) c=0 ;; *) c=1 ;; esac
assert "title: deep remote path takes the segment before the repo" "$c"

git remote set-url origin https://gitlab.example.com/group/subgroup/proj.git 2> /dev/null
case "$(run_sl 100 "$P_DIRTY" | strip_ansi)" in *'subgroup/proj'*) c=0 ;; *) c=1 ;; esac
assert "title: subgroup remote uses the immediate namespace" "$c"

# A trailing slash must not make the repo its own owner ("claude-statusline/
# claude-statusline"): basename tolerates it, the segment parse would not.
git remote set-url origin https://github.com/TheGnarCo/claude-statusline/ 2> /dev/null
case "$(run_sl 100 "$P_DIRTY" | strip_ansi)" in *'TheGnarCo/claude-statusline'*) c=0 ;; *) c=1 ;; esac
assert "title: trailing-slash remote still resolves the real owner" "$c"

# Only an http(s) URL has a host segment to strip. A local-path remote (a sibling
# clone) must not have a parent directory promoted into the owner slot.
git remote set-url origin /Users/me/src/upstream 2> /dev/null
out_localpath=$(run_sl 100 "$P_DIRTY" | strip_ansi)
case "$out_localpath" in *'src/upstream'*) c=1 ;; *'upstream'*) c=0 ;; *) c=1 ;; esac
assert "title: local-path remote yields no owner" "$c"

# Same for a non-GitHub SSH remote, which the github.com rewrite leaves as git@host:path.
git remote set-url origin git@gitlab.example.com:group/proj.git 2> /dev/null
out_ssh=$(run_sl 100 "$P_DIRTY" | strip_ansi)
case "$out_ssh" in *'group/proj'* | *':'*) c=1 ;; *'proj'*) c=0 ;; *) c=1 ;; esac
assert "title: non-GitHub SSH remote yields no owner" "$c"
git remote remove origin 2> /dev/null

# ── Telemetry-tag chip (git) ─────────────────────────────────────────────────
# The chip reads [telem tag] when the repo carries a project.name OTEL attribute and
# [no telem tag] when it doesn't (so its usage lands in the dashboard as
# "(untagged)"). Detection mirrors the toolkit SessionStart hook, and every input it
# reads is asserted here — live env, the repo's checked-in settings, its local
# override, a settings file that exists but carries no tag (the one path that
# actually forks jq), the opt-out, and the non-git case. Both states are asserted
# positively: an inverted test would pass on a chip that never renders at all. Its
# own throwaway repo, so writing settings files can't perturb the untracked counts
# the snapshot cases above pin.
TELEMREPO=$(mktemp -d)
(cd "$TELEMREPO" && git init -q) > /dev/null 2>&1 || {
  printf 'FAIL     telem fixture setup\n'
  FAIL=$((FAIL + 1))
}
cd "$TELEMREPO" || exit 2
P_TELEM='{"workspace":{"current_dir":"/work/proj/claude-statusline"},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"}}'
# chip_is <expected> — 0 when the rendered chip matches, 1 otherwise. "none" asserts
# neither state rendered.
chip_is() {
  local out
  out=$(run_sl 120 "$P_TELEM" | strip_ansi)
  case "$1:$out" in
    'tagged:'*'[telem tag]'*) return 0 ;;
    'untagged:'*'[no telem tag]'*) return 0 ;;
    'none:'*'telem tag'*) return 1 ;;
    'none:'*) return 0 ;;
  esac
  return 1
}

chip_is untagged
assert "telem: [no telem tag] in a git repo with no attribute" "$?"

mkdir -p "$TELEMREPO/.claude"
TAG='{"env":{"OTEL_RESOURCE_ATTRIBUTES":"project.name=org/repo"}}'
printf '%s\n' "$TAG" > "$TELEMREPO/.claude/settings.json"
chip_is tagged
assert "telem: [telem tag] when .claude/settings.json carries project.name" "$?"

printf '%s\n' '{"env":{"SOMETHING_ELSE":"1"}}' > "$TELEMREPO/.claude/settings.json"
chip_is untagged
assert "telem: settings.json without project.name still counts as untagged" "$?"

printf '%s\n' "$TAG" > "$TELEMREPO/.claude/settings.local.json"
chip_is tagged
assert "telem: [telem tag] when settings.local.json carries project.name" "$?"

# Claude Code merges settings.local.json OVER settings.json, so a local override
# that replaces the attribute without a project.name really is untagged — the chip
# must not keep reporting the repo file's tag.
printf '%s\n' "$TAG" > "$TELEMREPO/.claude/settings.json"
printf '%s\n' '{"env":{"OTEL_RESOURCE_ATTRIBUTES":"service.name=x"}}' > "$TELEMREPO/.claude/settings.local.json"
chip_is untagged
assert "telem: settings.local.json overrides the repo attribute" "$?"

# ...but a local file that doesn't define the attribute must not clobber it either.
printf '%s\n' '{"env":{"SOMETHING_ELSE":"1"}}' > "$TELEMREPO/.claude/settings.local.json"
chip_is tagged
assert "telem: an unrelated local override leaves the repo tag standing" "$?"

# An EXPLICITLY emptied override is defined-but-empty, which clears the repo's tag.
# `// ""` can't tell that from absent, and the chip stayed falsely green.
printf '%s\n' '{"env":{"OTEL_RESOURCE_ATTRIBUTES":""}}' > "$TELEMREPO/.claude/settings.local.json"
chip_is untagged
assert "telem: an explicitly-emptied local override clears the tag" "$?"

# A malformed settings.json must not mask a valid tag in the local override — one
# jq run over both files aborts on the parse error and reports untagged, which is
# why the detection reads them one at a time (as the hook does).
printf '%s\n' "$TAG" > "$TELEMREPO/.claude/settings.local.json"
printf '%s\n' '{ not json' > "$TELEMREPO/.claude/settings.json"
chip_is tagged
assert "telem: malformed settings.json doesn't mask settings.local.json" "$?"

# ...and a malformed file on its own is untagged, not a crash.
rm -f "$TELEMREPO/.claude/settings.local.json"
chip_is untagged
assert "telem: malformed settings.json alone reads as untagged" "$?"
rm -f "$TELEMREPO/.claude/settings.json"

# Both states link to the dashboard, so the OSC8 target must survive on each.
for _st in '' 'project.name=org/repo'; do
  out_link=$(COLUMNS=120 HOME=/home/tester CLAUDE_STATUSLINE_HIDE_TELEM='' \
    CMUX_SURFACE_ID='' CMUX_BUNDLE_ID='' OTEL_RESOURCE_ATTRIBUTES="$_st" \
    bash "$SCRIPT" <<< "$P_TELEM")
  case "$out_link" in *'telem.thegnar.info'*) c=0 ;; *) c=1 ;; esac
  [ "$c" -ne 0 ] && break
done
assert "telem: chip links to the dashboard in both states" "$c"

# Live env, no settings file at all — how a tagged repo actually renders under
# Claude Code, which exports the attribute from settings into the statusline's env.
out_tagged=$(COLUMNS=120 HOME=/home/tester CLAUDE_STATUSLINE_HIDE_TELEM='' \
  OTEL_RESOURCE_ATTRIBUTES='project.name=org/repo' bash "$SCRIPT" <<< "$P_TELEM" | strip_ansi)
case "$out_tagged" in *'[telem tag]'*) c=0 ;; *) c=1 ;; esac
assert "telem: [telem tag] when OTEL_RESOURCE_ATTRIBUTES is set in the env" "$c"

out_optout=$(COLUMNS=120 HOME=/home/tester OTEL_RESOURCE_ATTRIBUTES='' \
  CLAUDE_STATUSLINE_HIDE_TELEM=1 bash "$SCRIPT" <<< "$P_TELEM" | strip_ansi)
case "$out_optout" in *'telem tag'*) c=1 ;; *) c=0 ;; esac
assert "telem: CLAUDE_STATUSLINE_HIDE_TELEM=1 suppresses the chip" "$c"

# ...and =0 means SHOW. A bare -n test read any value as "hide", so the one spelling
# that unambiguously means "don't hide" hid it.
out_hide0=$(COLUMNS=120 HOME=/home/tester OTEL_RESOURCE_ATTRIBUTES='' \
  CLAUDE_STATUSLINE_HIDE_TELEM=0 bash "$SCRIPT" <<< "$P_TELEM" | strip_ansi)
case "$out_hide0" in *'no telem tag'*) c=0 ;; *) c=1 ;; esac
assert "telem: CLAUDE_STATUSLINE_HIDE_TELEM=0 still shows the chip" "$c"

# Outside a git repo there's no project to tag (the hook's first exit, mirrored).
cd "$NONGIT" || exit 2
chip_is none
assert "telem: no chip at all outside a git repo" "$?"

# Widening the pane must never make any cell SHORTER — the previous check covered
# worktree visibility but not branch length, and an all-or-nothing worktree drop
# let COLUMNS 42->44 shorten the branch (10 chars -> the 5-char floor) as the
# suffix reappeared. Total member length can't detect that (it GREW in that case,
# 11 -> 15, while the branch halved), so the branch has to be isolated from the
# "/worktree" suffix — which needs a branch carrying no slash of its own, or a
# truncated "feature/..name" is indistinguishable from "branch/worktree".
SLASHLESS=$(mktemp -d)
trap 'rm -rf "$NONGIT" "$GITREPO" "$COUNTERS" "$BARE" "$CLONE" "$SLASHLESS"' EXIT
(
  set -e # see the note on the COUNTERS fixture: without it a failed git step
  # leaves every render in a non-git dir, blen stays 0, and the monotonicity
  # assert below reports ok while measuring nothing
  cd "$SLASHLESS"
  git init -q
  git checkout -q -b averyveryverylongbranchnamewithnoslashes
  : > f.txt
  tg add f.txt
  tg commit -q --no-verify -m init
  : > untracked.txt
  echo change >> f.txt
) > /dev/null 2>&1
fixture_st=$?
# NOT `( ... ) || { ... }`: bash suppresses set -e inside a compound command
# that is the left operand of ||, and without it the subshell's status is just
# its last command's — so that guard could never fire and the asserts below it
# went vacuous. Capture the status instead.
if [ "$fixture_st" -ne 0 ]; then
  printf 'FAIL     slashless-branch fixture setup (exit %s)\n' "$fixture_st"
  FAIL=$((FAIL + 1))
fi
cd "$SLASHLESS" || exit 2

# Prove the fixture renders a branch at all before measuring its length — the
# COUNTERS fixture has its "all seven counters" assert for this; this one had
# nothing, so a broken fixture would sweep 0-length branches and report ok.
sane=$(run_sl 100 '{"workspace":{"current_dir":"/work/proj/x"},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"}}' | strip_ansi | line1_block | sed -n 's/.*\[@\([^]]*\)\].*/\1/p' | head -1)
assert "fixture: slashless-branch fixture renders a branch" "$([ ${#sane} -ge 20 ] && echo 0 || echo 1)"

branch_shrank=0
# Step 4 rather than 1: a decrease anywhere shows up between whichever two sampled
# widths bracket it, so subsampling still catches the regression this guards
# (branch 10 -> 5 as the suffix reappeared) without paying for 77 renders, each of
# which forks git several times. Sweeping every column here took the whole suite
# from ~13s to ~86s. It now sits near 55s, most of it the all-counters fixture
# setup and its renders rather than this sweep: the worktree-suffix check below does
# need consecutive columns (a 1-column gap is legitimate, 2 is a bug), so it pays
# for a bounded range rather than a step.
for wtname in a-long-worktree-name wt; do
  prev_len=0
  for w in $(seq 24 4 84); do
    out=$(run_sl "$w" "{\"workspace\":{\"current_dir\":\"/work/proj/x\"},\"worktree\":{\"name\":\"$wtname\"},\"context_window\":{\"used_percentage\":10,\"total_input_tokens\":20000,\"context_window_size\":200000},\"model\":{\"display_name\":\"Opus 4.8\"}}" |
      strip_ansi | line1_block)
    bmem=$(printf '%s\n' "$out" | sed -n 's/.*\[@\([^]]*\)\].*/\1/p' | head -1)
    bmem=${bmem%% *}  # strip the counters, keep "branch[/wt]"
    bonly=${bmem%%/*} # branch portion (the branch itself has no slash here)
    blen=${#bonly}
    if [ "$blen" -lt "$prev_len" ]; then
      branch_shrank=1
      printf 'note: branch shrank %s -> %s at COLUMNS=%s (wt=%s)\n' \
        "$prev_len" "$blen" "$w" "$wtname"
    fi
    prev_len=$blen
  done
done
assert "git group: branch length is monotonic in width" "$branch_shrank"
cd "$COUNTERS" || exit 2

# The vim chip is live state and must outlive a long output-style name when the
# config group has to shed (display order is shed order, so it is ordered ahead).
P_VIM_SHED='{"workspace":{"current_dir":"/work/proj/claude-statusline"},"vim":{"mode":"INSERT"},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":1000000},"model":{"display_name":"Claude Opus 4.8 (1M context)"},"effort":{"level":"xhigh"},"output_style":{"name":"Explanatory"}}'
# The guard must key on the CONFIG group's own elision, not on '..' anywhere in
# the block: trunc_mid's ellipsis sits inside a truncated name and this fixture's
# branch is always truncated, so a bare *'..'* matched every width and filtered
# nothing. The shed marker is distinguishable — always a standalone " .." member
# at the end of its bracket — so isolate the config bracket (the one carrying the
# model name) and test that.
vim_lost=0 vim_shed_seen=0
for w in 40 44 48 52 56 60; do
  out=$(run_sl "$w" "$P_VIM_SHED" | strip_ansi | line1_block)
  cfg=$(printf '%s\n' "$out" | tr ']' '\n' | grep 'Claude' | tail -1)
  case "$cfg" in *' ..') ;; *) continue ;; esac # only widths where CONFIG sheds
  vim_shed_seen=1
  # " I" covers the chip both mid-group (" I ") and before the marker (" I ..").
  case "$cfg" in *' I'*) ;; *) vim_lost=1 ;; esac
done
assert "config group: vim mode outlives output style when shedding" "$vim_lost"
assert "config group: a real config-group shed was exercised" "$((1 - vim_shed_seen))"

# The session group must still be ABLE to mark an elision. The line1-shed golden
# used to lock this, but now that the cost sheds its burn rate instead of the whole
# cell, that snapshot legitimately shows no marker — so assert the marker directly
# rather than lose the coverage.
sess_marked=0
for w in 24 26 30; do
  sgroup=$(run_sl "$w" "$P_L1_CHURN_BIG" | strip_ansi | line1_block |
    tr ']' '\n' | grep -E '^\[?\+' | tail -1)
  case "$sgroup" in *' ..') sess_marked=1 ;; esac
done
assert "session group: an elision is marked, not silent" "$((1 - sess_marked))"

# A cap is only justified for a member that LEADS its group (gflush can never shed
# a first member). Capping unconditionally is a regression against main: these two
# both fit with room to spare and must render whole.
#
# Floor, stated rather than asserted: below ~COLUMNS 24 line 1 cannot be bounded at
# all. A single atomic member (6-digit abbreviated churn is 13 columns) exceeds the
# whole budget, and no shedding helps because it leads its group. That is the same
# regime where MIN_PIP_COUNT already renders the CTX bar at 38 columns regardless,
# so the pane is overrun by design well before line 1 contributes; the sweeps above
# therefore start at 24.
P_STYLE_LONG='{"workspace":{"current_dir":"/work/proj/x"},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"},"output_style":{"name":"Deep Research Mode"}}'
out=$(run_sl 48 "$P_STYLE_LONG" | strip_ansi | line1_block)
case "$out" in *'Deep Research Mode'*) c=0 ;; *) c=1 ;; esac
assert "config group: a style that fits is not ellipsized" "$c"

# Cost-only at a width where the full cell fits EXACTLY: the burn rate must survive.
# An unconditional separator in the fit check made this strip the burn at 19-of-19.
P_COST_EXACT='{"workspace":{"current_dir":"/work/proj/x"},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":200000},"cost":{"total_cost_usd":12.34,"total_duration_ms":600000}}'
out=$(run_sl 27 "$P_COST_EXACT" | strip_ansi | line1_block)
# Match on the burn-rate suffix, not the figure — a literal '$7...' trips SC2016.
case "$out" in *'/h)'*) c=0 ;; *) c=1 ;; esac
assert "session group: an exactly-fitting cost keeps its burn rate" "$c"

# ── Summary ──────────────────────────────────────────────────────────────────
cd "$ROOT" || exit 2
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
