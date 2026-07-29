#!/usr/bin/env bash
# claude-statusline — a self-contained Claude Code statusline.
#
# Drop-in: needs only `git` and `jq` on PATH. No extra binaries.
# Point Claude Code at it in ~/.claude/settings.json:
#
#   "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }
#
# Reads the Claude Code statusline JSON on stdin and emits 2-4 colored lines:
#   Line 1: owner/repo [@branch(/wt) counters +N/-M]
#           [name model ctx eff style $cost][telem tag]
#           — identity + config folded onto one row of colored [] groups, ONE
#           GROUP PER CONCEPT: git state, then this session, then this config,
#           then whether this repo's usage is attributed in telemetry.
#           Groups pack left-to-right and wrap to a continuation line only when
#           they won't fit the pane. No PR chip — Claude Code surfaces the PR.
#           Members are space-separated inside their []; git counters are colored
#           ASCII sigils:
#           x conflict  ^ ahead  v behind  ! modified  + staged  ? untracked  *stash
#   Line 2: CTX <bar w/ amber autocompact cell> N% Nk/Nk cache N% N%->AC [200k+]
#   Line 3: 5h  <bar> N% Xh Ym left [delta]   (+ inline "7d N%" when 7d hidden)
#   Line 4: 7d  <bar> N% Xd Yh left [delta]   (shown only when 7d is binding)
#
# Pure ASCII; no Nerd Font required. Colors honor NO_COLOR and degrade on
# non-truecolor terminals. Everything degrades gracefully: missing fields just
# drop their segment.
#
# Bash 3.2 compatible (macOS system bash).

# ── Primitives ────────────────────────────────────────────────────────────
# Bars + sigils are pure ASCII: width-deterministic on every terminal (incl.
# cmux's re-emulated grid) and no Nerd Font dependency.
ESC=$(printf '\033')
BEL=$(printf '\007')
# Each bar cell type is a distinct SHAPE (not just a distinct color), so the
# marker / projection / fill stay legible in mono terminals and colorblind view.
PIP_FILL='#'     # bar fill            (gradient)
PIP_EMPTY='-'    # bar track           (muted)
PIP_MARKER='|'   # clock / threshold   (marker color)
PIP_PROJ='*'     # burn projection     (yellow)
PIP_OVERFLOW='!' # projection overflow (bold red)
SIG_BRANCH='@'   # branch    (evokes git @/HEAD)

# ── Color capability ────────────────────────────────────────────────────────
# Honor NO_COLOR (https://no-color.org) and dumb terminals; detect truecolor so
# the 24-bit gradient can degrade to a 256-color ramp elsewhere. The ASCII pip
# shapes already carry meaning without color, so mono output stays legible.
USE_COLOR=1
[ -n "${NO_COLOR:-}" ] && USE_COLOR=0
[ "${TERM:-}" = "dumb" ] && USE_COLOR=0
TRUECOLOR=0
case "${COLORTERM:-}" in *truecolor* | *24bit*) TRUECOLOR=1 ;; esac

# ── Style primitives ──────────────────────────────────────────────────────
if [ "$USE_COLOR" -eq 0 ]; then
  UNDIM="" BOLD="" RST="" MUTED="" RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN=""
  NEAR_WHITE="" MARKER="" PROJ="" AUTOCOMPACT="" UL="" UL_OFF=""
  TELEM_ON="" TELEM_OFF=""
else
  UNDIM="${ESC}[22m"
  BOLD="${ESC}[1m"
  UL="${ESC}[4m"
  UL_OFF="${ESC}[24m"
  RST="${ESC}[0m"
  MUTED="${ESC}[90m"
  RED="${ESC}[31m"
  GREEN="${ESC}[32m"
  YELLOW="${ESC}[33m"
  BLUE="${ESC}[34m"
  MAGENTA="${ESC}[35m"
  CYAN="${ESC}[36m"
  if [ "$TRUECOLOR" -eq 1 ]; then
    NEAR_WHITE="${ESC}[38;2;235;235;235m"
    MARKER="${ESC}[38;2;96;200;255m"     # rate-window clock pip (blue)
    PROJ="${ESC}[38;2;255;210;80m"       # burn projection pip (yellow)
    AUTOCOMPACT="${ESC}[38;2;255;128;0m" # autocompact threshold cell (amber)
    TELEM_ON="${ESC}[38;2;181;110;58m"   # telem chip, covered   (dim burnt orange)
    TELEM_OFF="${ESC}[38;2;255;160;60m"  # telem chip, untagged  (bright orange)
  else
    # 256-color approximations for terminals without truecolor.
    NEAR_WHITE="${ESC}[38;5;255m"
    MARKER="${ESC}[38;5;39m"
    PROJ="${ESC}[38;5;221m"
    AUTOCOMPACT="${ESC}[38;5;208m"
    TELEM_ON="${ESC}[38;5;130m"
    TELEM_OFF="${ESC}[38;5;214m"
  fi
fi

DEFAULT_PIP_COUNT=30 # fallback when the terminal width is unknown

# Bars stretch to fill the row: pip_count = cols - reserve, where `reserve` is
# the widest fixed (non-bar) overhead among the bar lines this render. All bars
# share that one pip_count, so they render at equal width and their % columns
# line up vertically.
#
# The reserve is computed at runtime (not a fixed constant) because a bar line's
# trailing text is variable-width: the CTX line carries token counts, a cache%,
# and headroom / AC / 200k+ chips; the 5h/7d lines carry a time-left + delta (+
# an inline "7d N%" badge). A constant tuned only to the window line let the
# often-wider CTX detail run off the right edge. Each line's overhead is
# <fixed prefix> + <measured trailing text>:
#   CTX line: CTX_FIXED + len(detail) + len(warn)
#   5h/7d   : WIN_FIXED + len(time) + len(delta) + len(inline 7d badge)
# where the *_FIXED constants count the non-bar, non-trailing cols — the label,
# the spaces around the bar, the pct field + '%', and each line's fixed literals
# (" left [ ]" on the window lines).
CTX_FIXED=9
WIN_FIXED=18
BAR_SAFETY=1     # leave one blank col at the right edge of the widest bar line
MIN_PIP_COUNT=12 # keep the bar readable on a narrow pane (and >1 for the gradient divisor)

# Claude Code reports the *full* terminal width via COLUMNS, but it renders the
# statusline inside its own chrome — a left indent plus a right-edge reservation
# for its UI hints. Filling a bar line to exactly COLUMNS therefore overruns that
# usable region: the row auto-wraps and shoves Claude's chrome off-screen. Hold
# back a fixed margin so the bars still stretch to fill the row but stop short of
# the chrome ("as wide as possible without losing Claude's UI"). Fixed, not
# proportional: the chrome is a constant column cost regardless of terminal width.
# Override with CLAUDE_STATUSLINE_CHROME_MARGIN when a build's chrome differs.
CHROME_MARGIN=8

# ── Helpers ────────────────────────────────────────────────────────────────

# Integer prefix of a string ("42.7" → 42, "" / garbage → 0).
int_prefix() {
  local s=${1%%.*}
  case "$s" in
    '' | *[!0-9-]*) echo 0 ;;
    *) echo "$s" ;;
  esac
}

# Abbreviate a token count: 42 / 12k / 1M (integer math, no decimals).
abbrev_num() {
  local n=$1
  if [ "$n" -lt 1000 ]; then
    echo "$n"
  elif [ "$n" -lt 1000000 ]; then
    echo "$((n / 1000))k"
  else
    echo "$((n / 1000000))M"
  fi
}

# Middle-ellipsize a string to <=max visible chars ("longbranchname" → "long..name").
# Pure ASCII ".." ellipsis. Leaves short strings and tiny budgets untouched.
trunc_mid() {
  local s=$1 max=$2 len=${#1}
  if [ "$max" -lt 5 ] || [ "$len" -le "$max" ]; then
    printf '%s' "$s"
    return
  fi
  local keep=$((max - 2)) head tail
  head=$(((keep + 1) / 2))
  tail=$((keep / 2))
  printf '%s..%s' "${s:0:head}" "${s:len-tail}"
}

# Build an OSC8 hyperlink: osc8 <url> <text>
#
# The text is underlined (SGR 4, closed with 24 rather than a full reset so the
# caller's color survives). The OSC 8 escape is zero-width, so without it a
# clickable cell is visually identical to every other cell on the row and nothing
# tells you it can be ⌘-clicked; the underline is the one link affordance every
# terminal renders, and it costs no columns. Callers must not put a full reset
# (RST) mid-text — it would clear the underline before the link ends.
osc8() { printf '%s]8;;%s%s%s%s%s%s]8;;%s' "$ESC" "$1" "$BEL" "$UL" "$2" "$UL_OFF" "$ESC" "$BEL"; }

# ── cmux compatibility shim ─────────────────────────────────────────────────
# The bars and sigils above are already pure ASCII, so the only thing that still
# garbles under cmux (the libghostty agent multiplexer, which re-emulates the
# grid and freezes frames into per-tab scrollback) is OSC 8 hyperlinks: a
# variable-length zero-width payload cmux miscounts, wrapping an unbudgeted row
# and desyncing the scroll region. Detect cmux via its launch env (CMUX_SURFACE_ID
# = the render surface, always set; CMUX_BUNDLE_ID as backstop) and emit link
# text without the escape. Real Ghostty.app sets neither, so links stay clickable.
# The underline goes with it: under cmux there is no link to advertise, and an
# underlined cell that does nothing when clicked is worse than a plain one.
if [ -n "${CMUX_SURFACE_ID:-}${CMUX_BUNDLE_ID:-}" ]; then
  osc8() { printf '%s' "$2"; }
fi

# Bar width: fill the row edge-to-edge, holding back `reserve` cols for the
# widest bar line's fixed + trailing text, with a MIN_PIP_COUNT floor (no
# ceiling). Falls back to DEFAULT_PIP_COUNT when the width is unknown.
pip_count_for_width() {
  local c=$1 reserve=$2
  if [ -z "$c" ]; then
    echo "$DEFAULT_PIP_COUNT"
    return
  fi
  local n=$((c - reserve))
  [ "$n" -lt "$MIN_PIP_COUNT" ] && n=$MIN_PIP_COUNT
  echo "$n"
}

# Blackbody-style gradient at t (0..10000); sets globals _GR/_GG/_GB.
gradient_at() {
  local t=$1 u
  if [ "$t" -le 3500 ]; then
    u=$((t * 10000 / 3500))
    _GR=$((74 + (176 - 74) * u / 10000))
    _GG=$((79 + (74 - 79) * u / 10000))
    _GB=$((92 + (58 - 92) * u / 10000))
  elif [ "$t" -le 7000 ]; then
    u=$(((t - 3500) * 10000 / 3500))
    _GR=$((176 + (240 - 176) * u / 10000))
    _GG=$((74 + (160 - 74) * u / 10000))
    _GB=$((58 + (64 - 58) * u / 10000))
  elif [ "$t" -le 9000 ]; then
    u=$(((t - 7000) * 10000 / 2000))
    _GR=$((240 + (255 - 240) * u / 10000))
    _GG=$((160 + (232 - 160) * u / 10000))
    _GB=$((64 + (144 - 64) * u / 10000))
  else
    u=$(((t - 9000) * 10000 / 1000))
    _GR=255
    _GG=$((232 + (255 - 232) * u / 10000))
    _GB=$((144 + (255 - 144) * u / 10000))
  fi
}

# Precompute the fill gradient once as a small palette of SGR-open strings, so
# render_bar is a table lookup per cell rather than a fresh gradient computation
# per cell (a wide, now-uncapped bar can be 150+ cells across three bars every
# refresh). Index a cell by gi = i*(GRAD_N-1)/(pip_count-1). Non-truecolor uses a
# cool→warm 256-color ramp; NO_COLOR leaves the entries empty (bare '#' fill).
GRAD_N=24
_grad_palette=()
_grad256_ramp=(60 66 96 132 168 203 202 208 214 220 228)
build_palette() {
  local i t
  for ((i = 0; i < GRAD_N; i++)); do
    t=$((i * 10000 / (GRAD_N - 1)))
    if [ "$USE_COLOR" -eq 0 ]; then
      _grad_palette[i]=""
    elif [ "$TRUECOLOR" -eq 1 ]; then
      gradient_at "$t"
      _grad_palette[i]="${ESC}[38;2;${_GR};${_GG};${_GB}m"
    else
      _grad_palette[i]="${ESC}[38;5;${_grad256_ramp[$((t * (${#_grad256_ramp[@]} - 1) / 10000))]}m"
    fi
  done
}
build_palette

# render_bar <pct> <marker_pct|""> <proj_pct|""> <pip_count> <marker_color>
render_bar() {
  local pct=$1 marker_pct=$2 proj_pct=$3 pip_count=$4 marker_color=$5
  [ "$pct" -lt 0 ] && pct=0
  local filled=$((pct * pip_count / 100))
  [ "$filled" -gt "$pip_count" ] && filled=$pip_count
  if [ "$pct" -gt 0 ] && [ "$filled" -eq 0 ]; then filled=1; fi

  local marker_idx=-1 marker_expired=0
  if [ -n "$marker_pct" ]; then
    if [ "$marker_pct" -ge 100 ]; then
      marker_idx=$((pip_count - 1))
      marker_expired=1
    else
      local m=$marker_pct
      [ "$m" -lt 0 ] && m=0
      marker_idx=$((m * pip_count / 100))
      [ "$marker_idx" -gt $((pip_count - 1)) ] && marker_idx=$((pip_count - 1))
    fi
  fi
  local proj_idx=-1 proj_overflow=0
  if [ -n "$proj_pct" ] && [ "$proj_pct" -ge 0 ]; then
    if [ "$proj_pct" -gt 100 ]; then
      # Projection runs off the right edge: pin to the last cell, flag overflow.
      proj_idx=$((pip_count - 1))
      proj_overflow=1
    else
      proj_idx=$((proj_pct * pip_count / 100))
      [ "$proj_idx" -gt $((pip_count - 1)) ] && proj_idx=$((pip_count - 1))
    fi
  fi

  local out="" i pip gi
  for ((i = 0; i < pip_count; i++)); do
    if [ "$i" -lt "$filled" ]; then pip=$PIP_FILL; else pip=$PIP_EMPTY; fi
    if [ "$i" -eq "$marker_idx" ]; then
      if [ "$marker_expired" -eq 1 ]; then
        out="${out}${UNDIM}${RED}${PIP_MARKER}"
      else
        out="${out}${UNDIM}${marker_color}${PIP_MARKER}"
      fi
    elif [ "$i" -eq "$proj_idx" ]; then
      if [ "$proj_overflow" -eq 1 ]; then
        out="${out}${UNDIM}${BOLD}${RED}${PIP_OVERFLOW}"
      else
        out="${out}${UNDIM}${PROJ}${PIP_PROJ}"
      fi
    elif [ "$i" -lt "$filled" ]; then
      gi=$((i * (GRAD_N - 1) / (pip_count - 1)))
      out="${out}${UNDIM}${_grad_palette[gi]}${pip}"
    else
      out="${out}${MUTED}${pip}"
    fi
  done
  printf '%s%s' "$out" "$RST"
}

# Last two path components, with $HOME → ~ (mirrors last_two_components).
dir_display() {
  local p=$1 home=$HOME shown rel
  if [ -n "$home" ] && [ "${p#"$home"}" != "$p" ]; then
    rel=${p#"$home"}
    if [ -z "$rel" ]; then shown="~"; else shown="~$rel"; fi
  else
    shown=$p
  fi
  local IFS='/' x
  local -a parts clean
  read -ra parts <<< "$shown"
  clean=()
  for x in "${parts[@]}"; do [ -n "$x" ] && clean+=("$x"); done
  local n=${#clean[@]}
  case "$shown" in
    '~'*)
      if [ "$n" -ge 3 ]; then printf '%s/%s' "${clean[n - 2]}" "${clean[n - 1]}"; else printf '%s' "$shown"; fi
      ;;
    *)
      if [ "$n" -ge 2 ]; then printf '%s/%s' "${clean[n - 2]}" "${clean[n - 1]}"; else printf '%s' "$shown"; fi
      ;;
  esac
}

# ── Read stdin payload ──────────────────────────────────────────────────────
input=$(cat)

if ! command -v jq > /dev/null 2>&1; then
  printf '%sclaude-statusline: jq not found on PATH%s\n' "$RED" "$RST"
  exit 0
fi

# Pull every field in one jq pass as name-keyed key=value lines, parsed by
# `case` (bash 3.2 safe). Name-keyed beats positional: a Claude Code schema
# addition or a local reorder can't silently shift every field — unknown keys
# are ignored, missing keys keep their default.
fields=$(printf '%s' "$input" | jq -r '
  "used_pct=\(.context_window.used_percentage // "" | tostring)",
  "ctx_input_tokens=\(.context_window.total_input_tokens // 0 | tostring)",
  "ctx_window_size=\(.context_window.context_window_size // 0 | tostring)",
  "cache_read_tokens=\(.context_window.current_usage.cache_read_input_tokens // 0 | tostring)",
  "worktree_name=\(.worktree.name // "")",
  "project_dir=\(.workspace.project_dir // "")",
  "cwd=\(.workspace.current_dir // "")",
  "repo_host=\(.workspace.repo.host // "")",
  "repo_owner=\(.workspace.repo.owner // "")",
  "repo_name=\(.workspace.repo.name // "")",
  "model_name=\(.model.display_name // "")",
  "effort_level=\(.effort.level // "")",
  "output_style=\(.output_style.name // "")",
  "cost_usd=\(.cost.total_cost_usd // "" | tostring)",
  "duration_ms=\(.cost.total_duration_ms // 0 | tostring)",
  "lines_added=\(.cost.total_lines_added // 0 | tostring)",
  "lines_removed=\(.cost.total_lines_removed // 0 | tostring)",
  "exceeds_200k=\(if .exceeds_200k_tokens == true then "1" else "" end)",
  "five_pct=\(.rate_limits.five_hour.used_percentage // "" | tostring)",
  "five_resets_at=\(.rate_limits.five_hour.resets_at // "" | tostring)",
  "seven_pct=\(.rate_limits.seven_day.used_percentage // "" | tostring)",
  "seven_resets_at=\(.rate_limits.seven_day.resets_at // "" | tostring)",
  "cols=\((.columns // .terminal.columns) // "" | tostring)"
' 2> /dev/null)

used_pct="" ctx_input_tokens=0 ctx_window_size=0 cache_read_tokens=0
worktree_name_input="" project_dir="" cwd_input=""
repo_host="" repo_owner="" repo_name_input=""
model_name="" effort_level="" output_style="" cost_usd="" duration_ms=0
lines_added=0
lines_removed=0 exceeds_200k="" five_pct=""
five_resets_at="" seven_pct="" seven_resets_at="" cols=""

while IFS= read -r _kv || [ -n "$_kv" ]; do
  case "$_kv" in *=*) ;; *) continue ;; esac
  _k=${_kv%%=*}
  _v=${_kv#*=}
  case "$_k" in
    used_pct) used_pct=$_v ;;
    ctx_input_tokens) ctx_input_tokens=$_v ;;
    ctx_window_size) ctx_window_size=$_v ;;
    cache_read_tokens) cache_read_tokens=$_v ;;
    worktree_name) worktree_name_input=$_v ;;
    project_dir) project_dir=$_v ;;
    cwd) cwd_input=$_v ;;
    repo_host) repo_host=$_v ;;
    repo_owner) repo_owner=$_v ;;
    repo_name) repo_name_input=$_v ;;
    model_name) model_name=$_v ;;
    effort_level) effort_level=$_v ;;
    output_style) output_style=$_v ;;
    cost_usd) cost_usd=$_v ;;
    duration_ms) duration_ms=$_v ;;
    lines_added) lines_added=$_v ;;
    lines_removed) lines_removed=$_v ;;
    exceeds_200k) exceeds_200k=$_v ;;
    five_pct) five_pct=$_v ;;
    five_resets_at) five_resets_at=$_v ;;
    seven_pct) seven_pct=$_v ;;
    seven_resets_at) seven_resets_at=$_v ;;
    cols) cols=$_v ;;
  esac
done <<< "$fields"

# Output style: drop the built-in one. Claude Code reports the default style by
# name ("claude"; older builds "default"), so the cell rendered on every session
# that had never touched /output-style — a permanent magenta word that told you
# nothing. It only earns a column when a NON-default style is active, which is
# exactly when "why is Claude answering like this?" is a question worth an answer.
case "$(printf '%s' "$output_style" | tr '[:upper:]' '[:lower:]')" in
  claude | default) output_style="" ;;
esac

# Normalize numeric-ish fields.
duration_ms=$(int_prefix "$duration_ms")
lines_added=$(int_prefix "$lines_added")
lines_removed=$(int_prefix "$lines_removed")
ctx_input_tokens=$(int_prefix "$ctx_input_tokens")
ctx_window_size=$(int_prefix "$ctx_window_size")
cache_read_tokens=$(int_prefix "$cache_read_tokens")

# Terminal width: as of Claude Code v2.1.153 it arrives via the COLUMNS env var
# (statusline stdout is captured, so `tput cols` can't see the tty). Prefer a
# numeric COLUMNS; a set-but-non-numeric value falls through to any JSON-provided
# width rather than clobbering it, then to the fixed default in render_bar.
case "${COLUMNS:-}" in
  '' | *[!0-9]*) : ;;
  *) cols=$COLUMNS ;;
esac
case "$cols" in '' | *[!0-9]*) cols="" ;; esac

# Reserve chrome margin from the usable width (see CHROME_MARGIN above). Env
# override wins when set to a non-negative integer; otherwise use the default.
margin=$CHROME_MARGIN
case "${CLAUDE_STATUSLINE_CHROME_MARGIN:-}" in
  '' | *[!0-9]*) : ;;
  *) margin=$CLAUDE_STATUSLINE_CHROME_MARGIN ;;
esac
if [ -n "$cols" ]; then
  cols=$((cols - margin))
  [ "$cols" -lt 1 ] && cols=1
fi

# ── Gather git state (self-contained; deliberately not the git-data cache) ──
# GIT_OPTIONAL_LOCKS=0: this runs on every refresh in the background — it must
# never contend for index.lock with the session's own git rebase/add.
export GIT_OPTIONAL_LOCKS=0
git_is_repo=0 branch="" repo_https="" repo_name="" repo_slug="" git_worktree_name=""
ahead=0 behind=0 staged=0 unstaged=0 untracked=0 conflict=0 stash=0

if topl=$(git rev-parse --show-toplevel 2> /dev/null) && [ -n "$topl" ]; then
  git_is_repo=1
  gdir=$(git rev-parse --git-dir 2> /dev/null)
  cdir=$(git rev-parse --git-common-dir 2> /dev/null)
  [ "$gdir" != "$cdir" ] && git_worktree_name=$(basename "$topl")

  while IFS= read -r line; do
    case "$line" in
      '# branch.head '*) branch=${line#\# branch.head } ;;
      '# branch.ab '*)
        ab=${line#\# branch.ab }
        a=${ab%% *}
        b=${ab#* }
        a=${a#+}
        b=${b#-}
        [ -n "$a" ] && ahead=$a
        [ -n "$b" ] && behind=$b
        ;;
      '? '*) untracked=$((untracked + 1)) ;;
      '1 '* | '2 '* | 'u '*)
        # Second whitespace token is the XY status pair.
        # shellcheck disable=SC2086  # intentional word-split into positional params
        set -- $line
        xy=$2
        x=${xy:0:1}
        y=${xy:1:1}
        case "$xy" in
          UU | AA | DD | AU | UA | DU | UD)
            conflict=$((conflict + 1))
            continue
            ;;
        esac
        case "$x" in M | A | D | R | C) staged=$((staged + 1)) ;; esac
        case "$y" in M | D) unstaged=$((unstaged + 1)) ;; esac
        ;;
    esac
  done < <(git status --porcelain=v2 --branch 2> /dev/null)

  # Detached HEAD fallback.
  if [ -z "$branch" ] || [ "$branch" = "(detached)" ]; then
    branch=$(git rev-parse --short HEAD 2> /dev/null)
  fi

  # Remote identity → HTTPS + repo name. Prefer Claude Code's structured
  # workspace.repo payload (correct for any host, and saves a git subprocess);
  # fall back to parsing the origin remote ourselves when it's absent.
  if [ -n "$repo_host" ] && [ -n "$repo_owner" ] && [ -n "$repo_name_input" ]; then
    repo_https="https://${repo_host}/${repo_owner}/${repo_name_input}"
    repo_name=$repo_name_input
    repo_slug="${repo_owner}/${repo_name_input}"
  else
    remote=$(git remote get-url origin 2> /dev/null)
    if [ -n "$remote" ]; then
      repo_https=${remote/git@github.com:/https:\/\/github.com\/}
      # Trailing slashes first, then `.git`, so `…/repo.git/` reduces to `…/repo`
      # (basename tolerates a trailing slash but the owner parse below would read it
      # as an empty last segment and call the repo its own owner).
      while [ "${repo_https%/}" != "$repo_https" ]; do repo_https=${repo_https%/}; done
      repo_https=${repo_https%.git}
      repo_name=$(basename "$repo_https")
      # Owner from the URL path: the segment immediately BEFORE the repo, not the
      # first one — a path deeper than <owner>/<repo> is common (GitLab subgroups,
      # Bitbucket's /scm/<project>/<repo>) and taking the first segment there
      # promotes a prefix into the owner slot ("scm/myrepo"). Strip the host, then
      # the last segment is the repo and the one before it is the owner. A path with
      # nothing before the repo — a top-level repo — yields no owner, and the title
      # falls back to the bare repo name rather than labelling something else as one.
      #
      # Gated on an http(s) URL: only there does the first segment denote a host that
      # must be stripped. A local-path remote (`/Users/me/src/upstream`, a sibling
      # clone) or a non-GitHub SSH remote (`git@host:path`, which the rewrite above
      # leaves alone) has no host segment to drop, so the same parse would promote a
      # parent directory into the owner slot — the exact failure this guard prevents.
      case "$repo_https" in
        http://*/*/* | https://*/*/*)
          _path=${repo_https#*://}
          _path=${_path#*/}
          case "$_path" in
            */*)
              _owner=${_path%/*}
              _owner=${_owner##*/}
              [ -n "$_owner" ] && repo_slug="${_owner}/${repo_name}"
              ;;
          esac
          ;;
      esac
    fi
  fi

  stash=$(git stash list 2> /dev/null | grep -c .)
fi

# ── Telemetry tag (project.name OTEL attribute) ─────────────────────────────
# Gnar attributes Claude Code usage per project through a `project.name=` entry in
# OTEL_RESOURCE_ATTRIBUTES, set in the repo's own .claude/settings.json (that's what
# the toolkit plugin's /toolkit:project-telem-tag writes). A repo without it lands
# in the dashboard as "(untagged)" — a silent gap nobody notices until they go
# looking for that project's spend — so line 1 reports which side of that this repo
# is on: `telem_state` is "tagged", "untagged", or "" for don't-render.
#
# Detection mirrors the toolkit SessionStart hook (project-telem-tag-check.sh) so
# the chip and the nudge can never disagree: live env first, then the repo's
# checked-in settings, then its local override. Only inside a git repo — outside
# one there's no project to tag, so the cell has nothing to say.
#
# Cheap by construction, because this runs on every refresh: when the repo IS
# tagged Claude Code exports the attribute into our env, so the common case
# answers from a `case` with zero I/O; when it's untagged there's usually no
# settings file to read; a jq read happens only for a file that exists (0 files ->
# 0 forks, the usual 1 -> 1). A jq failure (unreadable or malformed settings) yields
# no value and so reads as untagged — the same fail-toward-nudging choice the hook
# makes. Read per-file rather than one jq over both, because jq aborts the whole run
# on the first parse error: a malformed settings.json would otherwise mask a valid
# tag in settings.local.json.
#
# Later file wins, but only when it actually defines the attribute — that's Claude
# Code's own env merge (settings.local.json over settings.json), so a local override
# that replaces the attribute without a project.name correctly reads as untagged.
# The hook takes the first match instead; the two can't disagree in practice, since
# whenever any settings file defines the attribute Claude Code exports the merged
# value and the env branch above answers before either file is read.
TELEM_URL='https://telem.thegnar.info'
# Opt-out: unset and 0 both mean "show". A bare -n test would make
# CLAUDE_STATUSLINE_HIDE_TELEM=0 hide the chip, which is the opposite of what
# anyone writing that means, and unlike the script's other knobs, which read values.
telem_hidden=0
case "$CLAUDE_STATUSLINE_HIDE_TELEM" in '' | 0) ;; *) telem_hidden=1 ;; esac
telem_state=""
if [ "$git_is_repo" -eq 1 ] && [ "$telem_hidden" -eq 0 ]; then
  case "$OTEL_RESOURCE_ATTRIBUTES" in
    *project.name=*) telem_state=tagged ;;
    *)
      telem_state=untagged
      _attrs=""
      for _settings in "$topl/.claude/settings.json" "$topl/.claude/settings.local.json"; do
        [ -f "$_settings" ] || continue
        # jq answers "is it defined, and to what" in one string: "=<value>" when the
        # key is present (so an explicit "" comes back as a bare "="), and empty when
        # it's absent or the file won't parse. A bare `// ""` couldn't tell those
        # apart, and an explicitly-emptied local override then failed to clear the
        # repo's tag — the chip stayed green on a session reported as untagged.
        _v=$(jq -r '(.env // {}) as $e
          | if ($e | has("OTEL_RESOURCE_ATTRIBUTES"))
            then "=" + ($e.OTEL_RESOURCE_ATTRIBUTES | tostring) else "" end' \
          "$_settings" 2> /dev/null)
        [ -n "$_v" ] && _attrs=${_v#=}
      done
      case "$_attrs" in *project.name=*) telem_state=tagged ;; esac
      ;;
  esac
fi

# Autocompact threshold (env override, else 80).
ac=80
case "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" in
  '' | *[!0-9]*) : ;;
  *) if [ "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" -ge 1 ] && [ "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" -le 100 ]; then
    ac=$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  fi ;;
esac

# CWD: prefer project_dir when in a worktree.
if [ -n "$worktree_name_input" ] && [ -n "$project_dir" ]; then
  cwd=$project_dir
elif [ -n "$cwd_input" ]; then
  cwd=$cwd_input
else
  cwd=$(pwd)
fi
dir_disp=$(dir_display "$cwd")

# Line-1 name budgets: keep long branch / worktree names from blowing line 1 past
# the pane and re-triggering the very wrap CHROME_MARGIN guards against. Scale
# with width when known, with sane floors; be generous when width is unknown.
if [ -n "$cols" ]; then
  branch_max=$((cols / 3))
  [ "$branch_max" -lt 14 ] && branch_max=14
  wt_max=$((cols / 5))
  [ "$wt_max" -lt 8 ] && wt_max=8
  # The 14-col floor above can exceed the row itself on a very narrow pane, and
  # branch_max is the cap on every group's FIRST member — the one gflush can never
  # shed. Unclamped, a group could overrun the row on its first member alone
  # (a session name rendered 19 cols into a 14-col budget at COLUMNS=22). Hold
  # back 5: 2 for the brackets and 3 for the " .." a shed group appends. Only
  # binds below ~COLUMNS 27, where cols/3 is under the floor anyway.
  if [ $((cols - 5)) -lt "$branch_max" ]; then
    branch_max=$((cols - 5))
    [ "$branch_max" -lt 5 ] && branch_max=5
  fi
else
  branch_max=40
  wt_max=24
fi

# ── Line 1 (identity + config, packed onto one row; wraps when it won't fit) ─
# Everything Claude Code reports about "where am I / how am I configured" folds
# onto a single row of colored [] groups. A group is a CONCEPT, not a field: one
# bracket for git state (branch/worktree, counters, this session's churn), one for
# this session's config (name, model, ctx flag, effort, output style, cost), and
# one for telemetry coverage. The groups pack left-to-right and spill to a
# continuation line only when they exceed the pane, so the common case is one row (a
# row saved vs. the old title+model split), and related cells read as one cell
# instead of a bracket run.
# Title: the repo as owner/name (linked), else the bare repo name, else the cwd's
# last two components — truncated to the pane so an enormous name can't overflow on
# its own. owner/name because a bare name is ambiguous across orgs (this repo and
# the one it was seeded from are both "claude-statusline"), and because it's the
# same identity the telemetry tag uses: project.name=owner/repo.
if [ -n "$repo_slug" ]; then
  title_txt=$repo_slug
elif [ -n "$repo_name" ]; then
  title_txt=$repo_name
else
  title_txt=$dir_disp
fi
[ -n "$cols" ] && title_txt=$(trunc_mid "$title_txt" "$cols")
# The owner renders muted so the repo name stays the row's visual anchor and the
# extra columns don't shout. Once the slug has been ellipsized that split no longer
# holds (the ".." can land anywhere in it), so a truncated title renders as one run.
# No reset between the two runs: NEAR_WHITE already overrides MUTED, and a full
# reset there would close the link underline halfway through the slug.
if [ -n "$repo_slug" ] && [ "$title_txt" = "$repo_slug" ]; then
  title_disp="${MUTED}${repo_slug%/*}/${BOLD}${NEAR_WHITE}${repo_slug##*/}${RST}"
else
  title_disp="${BOLD}${NEAR_WHITE}${title_txt}${RST}"
fi
if [ -n "$repo_https" ]; then
  id_part=$(osc8 "$repo_https" "$title_disp")
else
  id_part=$title_disp
fi

# Bracket groups are assembled as (display, visible-length) segments, then packed
# onto lines below — the length twin lets the packer measure width without the
# ANSI/OSC8 noise in the display string.
seg_disp=() seg_len=()
add_seg() {
  seg_disp[${#seg_disp[@]}]=$1
  seg_len[${#seg_len[@]}]=$2
}

# Group builder: members accumulate into one open group, then gflush emits them
# space-separated inside a single bracketed segment. Each member carries its own
# color, so a group stays multi-colored inside one []; the plain twin tracks the
# visible width (the display string is full of ANSI/OSC8 noise). A group whose
# every member was empty flushes to nothing — no empty [] on the row.
#
# Members are held as parallel (display, plain) arrays rather than concatenated
# eagerly, because gflush has to be able to DROP members — see its comment.
_gm_disp=() _gm_plain=()
# gadd <colored> <plain> — append a member; a member with no plain text is a
# no-op. Add members in priority order: gflush sheds from the tail.
gadd() {
  [ -z "$2" ] && return
  _gm_disp[${#_gm_disp[@]}]=$1
  _gm_plain[${#_gm_plain[@]}]=$2
}

# gflush — emit the open group as one bracketed segment.
#
# A group is UNSPLITTABLE: the packer below relocates a whole segment to a
# continuation line but never breaks one open, so a group wider than the row
# overruns the pane and forces the wrap CHROME_MARGIN exists to prevent. With one
# bracket per field that was unreachable — every field carried its own budget —
# but grouping sums them (a long session name + big churn + a big cost now share
# a bracket), so the ceiling has to be enforced here: an over-wide group sheds
# its lowest-priority members and marks the elision with '..'. The first member
# is always kept, so it carries its own cap: branch_max/wt_max clamped to `avail`
# for git, branch_max for the session name and the model — and branch_max is
# itself clamped to cols-5 (see its floor), without which a group could overrun
# the row on its unsheddable first member alone.
gflush() {
  local n=${#_gm_plain[@]}
  [ "$n" -eq 0 ] && return
  local i budget=-1 full=0

  # Measure the group whole; only an over-wide one is re-packed against a budget
  # (which also holds room for " .."), so the common case is untouched.
  if [ -n "$cols" ]; then
    for ((i = 0; i < n; i++)); do
      [ "$i" -gt 0 ] && full=$((full + 1))
      full=$((full + ${#_gm_plain[i]}))
    done
    if [ $((full + 2)) -gt "$cols" ]; then
      budget=$((cols - 5))
      [ "$budget" -lt 1 ] && budget=1
    fi
  fi

  local disp="" plain="" sep elided=0
  for ((i = 0; i < n; i++)); do
    sep=0
    [ -n "$plain" ] && sep=1
    # break, not continue: members were added in priority order, so once one
    # doesn't fit, everything after it goes too. Skipping ahead to whatever
    # happens to be shorter would drop a higher-priority member while keeping a
    # lower-priority one, and would put the trailing '..' after a member that was
    # never elided — the marker has to mean "everything past here is missing".
    #
    # The cost of that is real and accepted: a short low-priority member can be
    # dropped while columns sit unused, because including it would mean skipping
    # the longer higher-priority member in front of it. A predictable prefix and a
    # marker that means one thing beat packing 1 more char into the row.
    if [ "$budget" -ge 0 ] && [ -n "$plain" ] &&
      [ $((${#plain} + sep + ${#_gm_plain[i]})) -gt "$budget" ]; then
      elided=1
      break
    fi
    if [ "$sep" -eq 1 ]; then disp="${disp} " plain="${plain} "; fi
    disp="${disp}${_gm_disp[i]}" plain="${plain}${_gm_plain[i]}"
  done
  if [ "$elided" -eq 1 ]; then
    # Best-effort: an unmarked elision is bad, but overrunning the row is worse
    # (that is the wrap CHROME_MARGIN exists to prevent). Only reachable when the
    # unsheddable first member already fills the row.
    if [ -z "$cols" ] || [ $((${#plain} + 5)) -le "$cols" ]; then
      disp="${disp} ${MUTED}..${RST}" plain="${plain} .."
    fi
  fi

  add_seg "${MUTED}[${RST}${disp}${MUTED}]${RST}" $((2 + ${#plain}))
  _gm_disp=() _gm_plain=()
}

# ── Group 1: git ────────────────────────────────────────────────────────────
# [@<branch>(/<worktree>) <counters>] — everything git knows about this checkout
# in one cell: branch (blue, linked to the tree), worktree (magenta), then the
# working-tree counters. They were three brackets; they're one concept, so the
# eye stops once instead of parsing a bracket run to reassemble "git state".
#
# Counters are colored ASCII sigils (untracked cyan, modified yellow, staged
# green, conflict bold-red, stash magenta, ahead green, behind red) — the glyph +
# count is ~4x denser than "N untracked, N modified, …". Sigils:
#   x conflict  ^ ahead  v behind  ! modified  + staged  ? untracked  *stash

# Worktree name (Claude's payload first, else the git worktree dir basename).
wt=$worktree_name_input
[ -z "$wt" ] && wt=$git_worktree_name

# Collect the counters BEFORE the branch, so their width is known while the
# branch/worktree budgets are still being chosen. Inside one bracket the two
# compete for the row, and they are not equally sheddable: a counter is atomic
# data (dropping x1 or *3 misreports the tree as conflict-free or stash-free)
# while a branch name is designed to be ellipsized. So the NAMES yield to the
# counters, never the reverse — with separate brackets the packer used to wrap
# the counters onto a continuation line, and shedding them instead would lose
# state the split layout kept.
# Order is MOST URGENT FIRST, and that is load-bearing rather than cosmetic:
# gflush sheds from the tail, so display order *is* shed order. A mid-merge
# conflict and unpushed/unpulled commits are the states you cannot afford to miss
# (they change what you should do next); a stash count is the one you can. So the
# tail — stash, untracked — is what a too-narrow pane gives up, and x/^/v are the
# last to go. Leftmost is also nearest the branch it qualifies.
_ct_disp=() _ct_plain=()
ctadd() {
  _ct_disp[${#_ct_disp[@]}]=$1
  _ct_plain[${#_ct_plain[@]}]=$2
}
[ "$conflict" -gt 0 ] && ctadd "${BOLD}${RED}x${conflict}${RST}" "x${conflict}"
[ "$ahead" -gt 0 ] && ctadd "${GREEN}^${ahead}${RST}" "^${ahead}"
[ "$behind" -gt 0 ] && ctadd "${RED}v${behind}${RST}" "v${behind}"
[ "$unstaged" -gt 0 ] && ctadd "${YELLOW}!${unstaged}${RST}" "!${unstaged}"
[ "$staged" -gt 0 ] && ctadd "${GREEN}+${staged}${RST}" "+${staged}"
[ "$untracked" -gt 0 ] && ctadd "${CYAN}?${untracked}${RST}" "?${untracked}"
[ "$stash" -gt 0 ] && ctadd "${MAGENTA}*${stash}${RST}" "*${stash}"

nct=${#_ct_plain[@]}
ct_width=0
for ((ci = 0; ci < nct; ci++)); do ct_width=$((ct_width + 1 + ${#_ct_plain[ci]})); done

if [ "$git_is_repo" -eq 1 ] || [ -n "$branch" ]; then
  b=$branch
  [ -z "$b" ] && b="-"

  # Name budgets. `avail` is the row minus "[]", the "@", and the counters — what
  # the names may occupy, including the "/" a worktree adds.
  #
  # Sized from what each name ACTUALLY NEEDS (its own length, capped by its share
  # of the pane), never from the 5-col floor: budgeting by the floor threw away a
  # 2-char worktree suffix that had room to spare, and handed the worktree a flat
  # 40% it didn't need while over-truncating the branch. Order of yielding, most
  # expendable last to arrive: shrink the branch -> shrink the worktree -> drop
  # the worktree suffix -> and only then let gflush's tail-shed reach a counter.
  # The suffix goes before any counter because it restates which checkout this is,
  # which the pane title and branch already imply, while a missing counter
  # misreports the tree. Floor at 5 because trunc_mid declines to ellipsize below
  # that (it would hand the name back untouched and overrun anyway).
  b_max=$branch_max
  w_max=$wt_max
  # Claude Code names a worktree branch "worktree-<name>", so the "/wt" suffix
  # usually spends 1+len(wt) columns restating text the branch already carries —
  # 23 of them for "@worktree-underline-links-1-1-1/underline-links-1-1-1". When
  # the branch already contains the name, show it IN PLACE: that run of the branch
  # renders magenta, the same color the suffix used, so the cell still answers
  # "which worktree?" at zero extra width.
  #
  # Matched only at a name boundary (the whole branch, or delimited by -/_), so a
  # short worktree name can't claim a coincidental substring of an unrelated
  # branch and suppress a suffix that was carrying real information.
  wt_inline=0
  if [ -n "$wt" ] && [ -n "$branch" ]; then
    case "$branch" in
      "$wt" | *[-/_]"$wt" | "$wt"[-/_]*) wt_inline=1 ;;
    esac
  fi
  show_wt=0
  [ -n "$wt" ] && [ "$wt_inline" -eq 0 ] && show_wt=1
  if [ -n "$cols" ]; then
    avail=$((cols - 3 - ct_width))

    want_b=${#b}
    [ "$want_b" -gt "$b_max" ] && want_b=$b_max
    want_w=0
    if [ "$show_wt" -eq 1 ]; then
      want_w=${#wt}
      [ "$want_w" -gt "$w_max" ] && want_w=$w_max
    fi
    need=$want_b
    [ "$show_wt" -eq 1 ] && need=$((need + 1 + want_w))

    # The suffix is shown only when it costs the branch NOTHING — i.e. both names
    # fit at the lengths they want. That is not a stylistic choice, it is the only
    # rule that keeps the BRANCH monotonic in pane width: showing "/wt" costs
    # 1+len(wt) columns, so any width at which the suffix starts appearing would
    # otherwise SHORTEN the branch by that much versus one column narrower. (An
    # earlier version squeezed both and pinned the branch at its floor to keep the
    # suffix, which is exactly how widening a pane could shorten the branch.)
    #
    # The branch is monotonic; the SUFFIX is not, and it cannot be made so here.
    # `need` is capped by branch_max (cols/3) and wt_max (cols/5), so where both
    # step — cols divisible by 15 — need grows by 2 while avail grows by 1 and the
    # suffix drops out for exactly one column (shown at COLUMNS 52, gone at 53,
    # back at 54, with a long branch and a >=9-char worktree). Periods 3 and 5
    # collide every 15 columns whatever the caps are; letting the branch absorb the
    # difference instead just moves the 1-column artifact onto branch length, which
    # is the more informative cell. Bounded and asserted in test/run.sh: the suffix
    # never vanishes for more than one consecutive column.
    # Below that, the suffix is dropped and the whole budget goes to the branch —
    # one readable branch beats two mangled names, and it is the branch the
    # counters qualify.
    if [ "$need" -le "$avail" ]; then
      b_max=$want_b w_max=$want_w
    else
      show_wt=0
      b_max=$want_b
      [ "$b_max" -gt "$avail" ] && b_max=$avail
    fi
    [ "$b_max" -lt 5 ] && b_max=5
  fi

  # Truncate the *displayed* text only; the hyperlink target keeps the full ref.
  b_txt=$(trunc_mid "$b" "$b_max")
  # Recolor, never re-measure: b_plain below still counts b_txt, and the highlight
  # is only applied when the run survived truncation whole. Switching to MAGENTA
  # and back to BLUE (not RST) keeps the bold and the link underline intact.
  b_render=$b_txt
  if [ "$wt_inline" -eq 1 ]; then
    case "$b_txt" in
      *"$wt"*) b_render="${b_txt%%"$wt"*}${MAGENTA}${wt}${BLUE}${b_txt#*"$wt"}" ;;
    esac
  fi
  if [ -n "$repo_https" ] && [ -n "$branch" ]; then
    b_disp=$(osc8 "$repo_https/tree/$branch" "$b_render")
  else
    b_disp=$b_render
  fi
  b_plain="${SIG_BRANCH}${b_txt}"
  if [ "$show_wt" -eq 1 ]; then
    wt_txt=$(trunc_mid "$wt" "$w_max")
    b_disp="${b_disp}${MAGENTA}/${wt_txt}"
    b_plain="${b_plain}/${wt_txt}"
  fi
  gadd "${BLUE}${BOLD}${SIG_BRANCH}${b_disp}${RST}" "$b_plain"
fi

for ((ci = 0; ci < nct; ci++)); do gadd "${_ct_disp[ci]}" "${_ct_plain[ci]}"; done
# Session churn joins the git cell: +N/-M is what this session did to this
# working tree, so it reads with the tree's own state rather than as its own
# bracket. Last in the group, hence first to shed — the counters describe what is
# there now, the churn describes how it got there.
#
# Digits are the one member that must not be ellipsized ("+12..56" reads as a real
# number), so an over-wide churn abbreviates the way token counts already do:
# +123456/-654321 -> +123k/-654k. It can also LEAD the group (churn reported
# outside a repo), and gflush never sheds a first member, so it must fit alone.
if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
  ch_add=$lines_added ch_del=$lines_removed
  if [ -n "$cols" ] && [ $((${#ch_add} + ${#ch_del} + 3)) -gt $((cols - 5)) ]; then
    ch_add=$(abbrev_num "$lines_added")
    ch_del=$(abbrev_num "$lines_removed")
  fi
  gadd "${GREEN}${BOLD}+${ch_add}${RST}${MUTED}/${RED}${BOLD}-${ch_del}${RST}" \
    "+${ch_add}/-${ch_del}"
fi

gflush

# ── Group 2: this session's config ──────────────────────────────────────────
# [<model> <ctxflag> <effort> <style> <$cost>] — every knob that decides how this
# session behaves, in one cell: model (cyan), extended-context flag (yellow),
# reasoning effort (green), output style (magenta), spend (green).
#
# There is no name cell. The group used to lead with one — the agent name, else
# your session_name — on the theory that it answered "which of my many concurrent
# tabs is this?" before anything about the model mattered. It didn't: every
# untyped agent reports the generic "claude", which names nothing and can't tell
# two agents apart, and the pane is already identified by the title's owner/repo
# and the branch. The cost trails: it is the group's one derived number, the only
# member that keeps changing on its own, and the one you can reconstruct after the
# fact from the transcript.
#
# Short name: drop the " (...)" suffix. Capped to the branch budget because it
# leads the group, and gflush can never shed a first member.
model_short="${model_name%% (*}"
model_short=$(trunc_mid "$model_short" "$branch_max")

# Context flag: prefer the authoritative context_window_size — anything past the
# 200k default becomes a flag (abbrev_num(1000000) -> "1M"). Fall back to the
# model-name parenthetical whenever the size field yields no flag (absent, or a
# build that reports the default size while the 1M beta is active), so the
# extended-window indicator is never silently dropped.
ctx_flag=""
if [ "$ctx_window_size" -gt 200000 ]; then
  ctx_flag="$(abbrev_num "$ctx_window_size")"
fi
if [ -z "$ctx_flag" ]; then
  case "$model_name" in
    *\(*\)*)
      ctx_flag="${model_name#*(}"
      ctx_flag="${ctx_flag%%)*}"
      ctx_flag="${ctx_flag%% context}" # "1M context" -> "1M"
      ;;
  esac
fi

# Effort: a 2-3 char label per tier. Every tier is abbreviated, not just the ones
# that read wrong title-cased ("Xhigh"), because the cell is a dial position — you
# read it against the other tiers, not as a word — and "Medium" spent 6 columns
# saying what "Med" says. An unknown tier still title-cases so a new one from
# Claude Code renders legibly instead of vanishing.
case "$effort_level" in
  "") effort_cap="" ;;
  low) effort_cap="Lo" ;;
  medium) effort_cap="Med" ;;
  high) effort_cap="Hi" ;;
  xhigh) effort_cap="XHi" ;;
  max) effort_cap="Max" ;;
  *) effort_cap="$(printf '%s' "${effort_level:0:1}" | tr '[:lower:]' '[:upper:]')${effort_level:1}" ;;
esac

# The model cells stay gated on the model fields: a payload that reports only a
# context_window_size must not surface a bare [1M] on its own (it didn't before
# these merged into one group).
#
# Order is shed order here too (gflush drops from the tail), so the output style
# goes last: it is set once and stays put, while everything ahead of it describes
# what this session IS.
show_model=0
if [ -n "$model_name" ] || [ -n "$effort_level" ] || [ -n "$output_style" ]; then
  show_model=1
fi
if [ "$show_model" -eq 1 ]; then
  gadd "${CYAN}${model_short}${RST}" "$model_short"
  gadd "${YELLOW}${ctx_flag}${RST}" "$ctx_flag"
  gadd "${GREEN}${effort_cap}${RST}" "$effort_cap"
fi
# Capped ONLY when it actually leads the group — i.e. every cell ahead of it is
# empty. Capping unconditionally ellipsized a long style name that fit with columns
# to spare ("Deep Research Mode" -> "Deep R..h Mode" at COLUMNS=48, where main
# showed it whole); the first-member rule that justifies a cap simply did not apply.
style_txt=$output_style
if [ -z "$model_short" ] && [ -z "$ctx_flag" ] && [ -z "$effort_cap" ]; then
  style_txt=$(trunc_mid "$output_style" "$branch_max")
fi
[ "$show_model" -eq 1 ] && gadd "${MAGENTA}${style_txt}${RST}" "$style_txt"

# Cost: total + per-hour burn from one awk pass (burn needs >=1min of duration).
money=$(awk -v c="$cost_usd" -v d="$duration_ms" 'BEGIN{
  if (c ~ /^[0-9]+(\.[0-9]+)?$/) {
    printf "$%.2f", c
    if (c+0 > 0 && d+0 >= 60000) printf " ($%.2f/h)", (c+0) / ((d+0)/3600000.0)
  }
}')
# The cost cell can still be the group's FIRST member (a payload with a cost and
# no name, model, effort or style), and gflush never sheds a first member — so it
# has to fit on its own. Drop the derived per-hour burn before the total, which is
# the half you cannot reconstruct from the other.
# Gated on the ROW, not on branch_max: that is a name budget (cols/3), and using
# it here dropped the burn rate at COLUMNS=60, where it fits fine.
#
# Measured against what the group ALREADY holds, not against the money cell alone.
# Alone-only meant that in the ordinary name+churn+cost group the full string still
# "fit the row" on its own, so nothing shortened — and gflush then shed the entire
# cost member, losing the total too. That inverted the intent: at COLUMNS=52 the
# row read `[my-ses..e-here +1200/-450 ..]` when `$12.34` had room.
# The per-hour burn is the row's most expendable text: derived, ~9 columns, and
# recomputable from the total, which is the half you cannot get back. So it is kept
# only when the WHOLE row still fits on ONE line with it — a burn rate that costs a
# wrapped line costs more than it says.
#
# Projected width = title + the space after it + every group already flushed + this
# group as it stands + the telemetry chip that always follows (its text + brackets;
# it is the last group either way). Measuring the row, not the money cell alone, is
# what makes this correct in both directions: cell-alone let the full string "fit"
# while gflush then shed the entire cost member, losing the TOTAL too — at
# COLUMNS=52 the row read `[my-ses..e-here +1200/-450 ..]` when `$12.34` had room.
#
# The separator counts only when something is actually there. Adding it
# unconditionally cost a cost-only group its burn rate at an exact fit (19 columns
# into 19), which is the very case the check exists for.
if [ -n "$cols" ] && [ -n "$money" ]; then
  case "$money" in
    *' ('*)
      _rw=${#title_txt} # title_len is not assigned until the packer, below
      for ((_ri = 0; _ri < ${#seg_len[@]}; _ri++)); do _rw=$((_rw + seg_len[_ri])); done
      # The space after the title, which the packer adds before the FIRST group —
      # so it is owed whenever there is a title, not only once a group has flushed
      # (this group may be the first one).
      [ "${#title_txt}" -gt 0 ] && _rw=$((_rw + 1))
      _gw=0
      for ((_ri = 0; _ri < ${#_gm_plain[@]}; _ri++)); do
        [ "$_ri" -gt 0 ] && _gw=$((_gw + 1))
        _gw=$((_gw + ${#_gm_plain[_ri]}))
      done
      [ "${#_gm_plain[@]}" -gt 0 ] && _gw=$((_gw + 1)) # separator before the cost
      _rw=$((_rw + 2 + _gw + ${#money}))               # this group's own brackets
      case "$telem_state" in
        tagged) _rw=$((_rw + 11)) ;;
        untagged) _rw=$((_rw + 14)) ;;
      esac
      [ "$_rw" -gt "$cols" ] && money=${money%% (*}
      ;;
  esac
fi
gadd "${GREEN}${money}${RST}" "$money"
gflush

# ── Group 3: telemetry coverage ─────────────────────────────────────────────
# [telem tag] when this repo's Claude Code usage is attributed to a project in the
# dashboard, [no telem tag] when it isn't and the usage lands there under
# "(untagged)" (fix: /toolkit:project-telem-tag). Two shades of ONE hue rather than
# green-vs-yellow: this is one axis with two positions, not two unrelated states, so
# it reads as a single dial — dim burnt orange for covered, bright orange for the
# state that wants doing something about. Nothing rests on telling the shades apart:
# the two chips already differ by the word "no". Both are OSC8 links to the
# dashboard itself, so the cell answers "am I covered?" and ⌘-click goes to where the
# answer matters. Two states rather than nag-only: a chip that only ever appears as a
# warning leaves you unable to tell "covered" from "this statusline is too old to
# know".
#
# Its own group rather than a member of the git one: it's a fact about the project,
# not about the working tree, and it must not share a bracket whose over-wide shed
# could drop it — or drop branch state to keep it. Last on purpose, too: it renders
# on every refresh inside a git repo, and the packer spills whole groups in order, so
# anywhere earlier would push git state onto a continuation line on a narrow pane to
# make room for a cell that rarely changes. Trailing, it's the first thing to spill.
# CLAUDE_STATUSLINE_HIDE_TELEM=1 drops it entirely.
case "$telem_state" in
  tagged) gadd "${TELEM_ON}$(osc8 "$TELEM_URL" 'telem tag')${RST}" 'telem tag' ;;
  untagged) gadd "${TELEM_OFF}$(osc8 "$TELEM_URL" 'no telem tag')${RST}" 'no telem tag' ;;
esac
gflush

# Pack the groups onto lines: the title starts line 1; each group joins the
# current line when it still fits within `cols`, otherwise it starts a fresh
# continuation line. One space sits between the title and the first group; groups
# otherwise butt together (matching the original flush layout). When cols is
# unknown there's no bound to enforce, so everything rides a single line.
title_len=${#title_txt}
cur_disp=$id_part cur_len=$title_len title_only=1
i=0 nseg=${#seg_len[@]}
while [ "$i" -lt "$nseg" ]; do
  sep=0
  [ "$title_only" -eq 1 ] && [ "$title_len" -gt 0 ] && sep=1
  cost=$((sep + seg_len[i]))
  if [ -n "$cols" ] && [ "$cur_len" -gt 0 ] && [ $((cur_len + cost)) -gt "$cols" ]; then
    printf '%s\n' "$cur_disp"
    cur_disp=${seg_disp[i]} cur_len=${seg_len[i]} title_only=0
  else
    [ "$sep" -eq 1 ] && cur_disp="${cur_disp} ${seg_disp[i]}" || cur_disp="${cur_disp}${seg_disp[i]}"
    cur_len=$((cur_len + cost)) title_only=0
  fi
  i=$((i + 1))
done
printf '%s\n' "$cur_disp"

# ── Line 2: CTX bar ─────────────────────────────────────────────────────────
# Build the CTX trailing text FIRST (colored form for output, plus a plain twin
# whose length feeds the shared bar reserve): the CTX line's trailing text is
# usually the widest, so the bar can't be sized until it's known.
used_int=$(int_prefix "$used_pct")

# Detail = absolute token readout + prompt-cache hit ratio (both from the live
# context_window). used_percentage is input-only, so this adds the raw figure and
# how much of the context is served from cache — a session-efficiency signal.
ctx_detail="" ctx_detail_plain=""
if [ "$ctx_input_tokens" -gt 0 ]; then
  if [ "$ctx_window_size" -gt 0 ]; then
    ctx_tok="$(abbrev_num "$ctx_input_tokens")/$(abbrev_num "$ctx_window_size")"
  else
    ctx_tok="$(abbrev_num "$ctx_input_tokens")"
  fi
  ctx_detail=" ${MUTED}${ctx_tok}${RST}"
  ctx_detail_plain=" ${ctx_tok}"
  if [ "$cache_read_tokens" -gt 0 ]; then
    cache_pct=$((cache_read_tokens * 100 / ctx_input_tokens))
    [ "$cache_pct" -gt 100 ] && cache_pct=100
    ctx_detail="${ctx_detail} ${MUTED}cache ${cache_pct}%${RST}"
    ctx_detail_plain="${ctx_detail_plain} cache ${cache_pct}%"
  fi
fi

# Escalate the pct color as it nears autocompact, and make the threshold active:
# show live headroom (N%->AC) below it, a bracket chip [AC] once crossed.
ctx_pct_color=$GREEN
ctx_warn="" ctx_warn_plain=""
if [ "$used_int" -ge "$ac" ]; then
  ctx_pct_color=$RED
  ctx_warn=" ${MUTED}[${AUTOCOMPACT}AC${MUTED}]${RST}"
  ctx_warn_plain=" [AC]"
else
  [ "$used_int" -ge $((ac - 15)) ] && ctx_pct_color=$YELLOW
  ctx_detail="${ctx_detail} ${MUTED}$((ac - used_int))%->AC${RST}"
  ctx_detail_plain="${ctx_detail_plain} $((ac - used_int))%->AC"
fi
if [ -n "$exceeds_200k" ]; then
  ctx_warn="${ctx_warn} ${MUTED}[${BOLD}${RED}200k+${RST}${MUTED}]${RST}"
  ctx_warn_plain="${ctx_warn_plain} [200k+]"
fi
ctx_overhead=$((CTX_FIXED + ${#ctx_detail_plain} + ${#ctx_warn_plain}))

# ── Lines 3-4: rate-limit windows — compute pieces, then render ──────────────
# One `date` call for both windows (they share the same "now").
NOW=$(date +%s)

# 7d earns its own row only when it's the binding window (>=50% or higher than
# 5h); otherwise it rides inline on the 5h line as a compact "7d N%" badge, so a
# quiet week doesn't cost a whole bar row.
five_int=$(int_prefix "$five_pct")
seven_int=$(int_prefix "$seven_pct")
show_7d=0
if [ -n "$seven_pct" ] && [ -n "$seven_resets_at" ]; then
  if [ "$seven_int" -ge 50 ] || [ "$seven_int" -gt "$five_int" ]; then show_7d=1; fi
fi
five_extra="" five_extra_plain=""
if [ "$show_7d" -eq 0 ] && [ -n "$seven_pct" ]; then
  five_extra=" ${MUTED}7d ${seven_int}%${RST}"
  five_extra_plain=" 7d ${seven_int}%"
fi

# Registry of computed windows (parallel indexed arrays; bash 3.2 safe). Each
# window's display pieces are computed up front — including its trailing-text
# overhead — so the shared bar reserve can account for every bar line before any
# is rendered.
_win_lbl=() _win_pct=() _win_clock=() _win_proj=() _win_time=() _win_delta=() _win_extra=() _win_over=()
compute_window() {
  local pct_str=$1 resets_str=$2 window_min=$3 label=$4 extra_disp=$5 extra_plain=$6
  local pct
  pct=$(int_prefix "$pct_str")
  local resets=$resets_str
  case "$resets" in *[!0-9]*) resets=0 ;; esac
  local remain_sec=$((resets > NOW ? resets - NOW : 0))
  local remain_min=$((remain_sec / 60))
  [ "$remain_min" -gt "$window_min" ] && remain_min=$window_min
  local clock_pct=$(((window_min - remain_min) * 100 / window_min))
  local proj_pct=""
  [ "$clock_pct" -gt 5 ] && proj_pct=$((pct * 100 / clock_pct))
  local delta=$((pct - clock_pct)) delta_disp delta_plain
  if [ "$delta" -gt 0 ]; then
    delta_disp="${RED}+${delta}%${RST}"
    delta_plain="+${delta}%"
  elif [ "$delta" -lt 0 ]; then
    delta_disp="${GREEN}${delta}%${RST}"
    delta_plain="${delta}%"
  else
    delta_disp="${MUTED}0%${RST}"
    delta_plain="0%"
  fi

  # Time remaining, framed as "… left" (no leading '-', which read as negative).
  local time_label
  if [ "$remain_min" -ge 1440 ]; then
    printf -v time_label '%dd %dh' "$((remain_min / 1440))" "$(((remain_min % 1440) / 60))"
  elif [ "$remain_min" -ge 60 ]; then
    printf -v time_label '%dh %dm' "$((remain_min / 60))" "$((remain_min % 60))"
  else
    printf -v time_label '%dm' "$remain_min"
  fi

  local n=${#_win_lbl[@]}
  _win_lbl[n]=$label
  _win_pct[n]=$pct
  _win_clock[n]=$clock_pct
  _win_proj[n]=$proj_pct
  _win_time[n]=$time_label
  _win_delta[n]=$delta_disp
  _win_extra[n]=$extra_disp
  _win_over[n]=$((WIN_FIXED + ${#time_label} + ${#delta_plain} + ${#extra_plain}))
}

five_has_data=0
if [ -n "$five_pct" ] && [ -n "$five_resets_at" ]; then
  five_has_data=1
  compute_window "$five_pct" "$five_resets_at" 300 "5h" "$five_extra" "$five_extra_plain"
fi
[ "$show_7d" -eq 1 ] && compute_window "$seven_pct" "$seven_resets_at" 10080 "7d" "" ""

# Shared bar width: hold back the widest overhead across the CTX + window lines
# so no line's trailing text can run off the right edge, plus one safety col.
reserve=$ctx_overhead
for _o in "${_win_over[@]}"; do [ "$_o" -gt "$reserve" ] && reserve=$_o; done
reserve=$((reserve + BAR_SAFETY))
pip_count=$(pip_count_for_width "$cols" "$reserve")

# Render Line 2 (CTX).
ctx_bar=$(render_bar "$used_int" "$ac" "" "$pip_count" "$AUTOCOMPACT")
printf -v ctx_lbl '%-3s' "CTX"
printf -v ctx_pct '%3s' "$used_int"
printf '%s%s%s %s %s%s%%%s%s%s\n' "$MUTED" "$ctx_lbl" "$RST" "$ctx_bar" "$ctx_pct_color" "$ctx_pct" "$RST" "$ctx_detail" "$ctx_warn"

# Render Lines 3-4 (rate-limit windows). The "no data yet" placeholder is a
# 5h-labelled fallback; a 7d row can still render on its own when it has data.
if [ "$five_has_data" -eq 0 ]; then
  printf -v lbl '%-3s' "5h"
  printf '%s%s%s %sno rate-limit data yet%s\n' "$MUTED" "$lbl" "$RST" "$MUTED" "$RST"
fi
render_window() {
  local i=$1 bar lbl pctf
  bar=$(render_bar "${_win_pct[i]}" "${_win_clock[i]}" "${_win_proj[i]}" "$pip_count" "$MARKER")
  printf -v lbl '%-3s' "${_win_lbl[i]}"
  printf -v pctf '%3s' "${_win_pct[i]}"
  printf '%s%s%s %s %s%s%%%s %s%s left%s [%s%s]%s%s\n' \
    "$MUTED" "$lbl" "$RST" "$bar" "$MUTED" "$pctf" "$RST" \
    "$MARKER" "${_win_time[i]}" "$RST" "${_win_delta[i]}" "$MUTED" "$RST" "${_win_extra[i]}"
}
i=0
while [ "$i" -lt "${#_win_lbl[@]}" ]; do
  render_window "$i"
  i=$((i + 1))
done

# Always succeed: a statusline must never signal failure to Claude Code (a
# trailing conditional would otherwise leak a non-zero status).
exit 0
