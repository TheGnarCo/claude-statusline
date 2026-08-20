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
# One texture for every meter: a mid shade over a light track. The meters are
# told apart by the label immediately in front of each one and by colour, not by
# glyph. That works in this layout and did not in the last one: side by side you
# read a label and its bar in one glance, so shape has nothing left to
# disambiguate. Stacked on separate rows it did, which is why the old per-row
# glyph tiers existed.
#
# These are Unicode block elements, not ASCII. That is a deliberate, breaking
# change from every version before this one, and there is no ASCII fallback: the
# marks are CP437-heritage and single-width, so the column arithmetic stays
# deterministic, but a font that substitutes a double-width glyph will misalign
# the frame. See README "Requirements".
BAR_FILL='▒'  # spent
BAR_TRACK='░' # untouched

# Frame. Section labels sit inside the rules rather than above them.
FR_TL='╭' FR_TR='╮' FR_BL='╰' FR_BR='╯'
FR_H='─' FR_V='│' FR_ML='├' FR_MR='┤'
SIG_BRANCH='@' # branch (evokes git @/HEAD)

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
  BOLD="" RST="" MUTED="" RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN=""
  UL="" UL_OFF=""
  TELEM_ON="" TELEM_OFF=""
  CTX_HUE="" FIVE_HUE="" SEVEN_HUE=""
else
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
    # Two oranges, and which is which is load-bearing. The BURNT one is chrome:
    # frame, vertical rules, and the covered tag. The BRIGHT one is spent on one
    # thing only — an untagged repo. Chrome that appears on every row of every
    # repo cannot also be a warning, so the bright shade is never used for it.
    TELEM_ON="${ESC}[38;2;181;110;58m"  # frame, rules, covered tag (burnt orange)
    TELEM_OFF="${ESC}[38;2;255;160;60m" # untagged tag ONLY      (bright orange)
    # One hue per meter, flat rather than ramped: the three bars are already
    # distinguished by hue, so a gradient inside each would fight that.
    CTX_HUE="${ESC}[38;2;158;86;224m"   # context   (purple)
    FIVE_HUE="${ESC}[38;2;224;140;60m"  # 5h window (warm)
    SEVEN_HUE="${ESC}[38;2;77;143;214m" # 7d window (blue)
  else
    # 256-color approximations for terminals without truecolor.
    TELEM_ON="${ESC}[38;5;130m"
    TELEM_OFF="${ESC}[38;5;214m"
    CTX_HUE="${ESC}[38;5;141m"
    FIVE_HUE="${ESC}[38;5;179m"
    SEVEN_HUE="${ESC}[38;5;68m"
  fi
fi

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

# Repeat a glyph n times. Bash 3.2 has no string repetition and printf's %*s
# pads with spaces only, so this is a bounded loop — n is never wider than a pane.
rep() {
  local g=$1 n=$2 out="" i
  for ((i = 0; i < n; i++)); do out="${out}${g}"; done
  printf '%s' "$out"
}

# render_bar <pct> <width> <fill-color>
#
# Flat fill, no gradient. The three meters are distinguished by hue, so a ramp
# inside each one would fight the thing hue is already doing; and with the clock
# pips and projection gone there is nothing left in a bar that a gradient helped
# locate. The old ramp machinery went with them.
render_bar() {
  local pct=$1 w=$2 color=$3 filled
  [ "$w" -lt 1 ] && return 0
  filled=$((pct * w / 100))
  [ "$filled" -lt 0 ] && filled=0
  [ "$filled" -gt "$w" ] && filled=$w
  printf '%s%s%s%s%s' \
    "$color" "$(rep "$BAR_FILL" "$filled")" \
    "$MUTED" "$(rep "$BAR_TRACK" "$((w - filled))")" "$RST"
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
  "session_id=\(.session_id // "")",
  "cc_version=\(.version // "")",
  "fast_mode=\(if .fast_mode == true then "1" else "" end)",
  "thinking_off=\(if .thinking.enabled == false then "1" else "" end)",
  "api_duration_ms=\(.cost.total_api_duration_ms // 0 | tostring)",
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
  "five_pct=\(.rate_limits.five_hour.used_percentage // "" | tostring)",
  "five_resets_at=\(.rate_limits.five_hour.resets_at // "" | tostring)",
  "seven_pct=\(.rate_limits.seven_day.used_percentage // "" | tostring)",
  "seven_resets_at=\(.rate_limits.seven_day.resets_at // "" | tostring)",
  "cols=\((.columns // .terminal.columns) // "" | tostring)"
' 2> /dev/null)

used_pct="" ctx_input_tokens=0 ctx_window_size=0 cache_read_tokens=0
session_id="" cc_version="" fast_mode="" thinking_off="" api_duration_ms=0
worktree_name_input="" project_dir="" cwd_input=""
repo_host="" repo_owner="" repo_name_input=""
model_name="" effort_level="" output_style="" cost_usd="" duration_ms=0
lines_added=0
lines_removed=0 five_pct=""
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
    session_id) session_id=$_v ;;
    cc_version) cc_version=$_v ;;
    fast_mode) fast_mode=$_v ;;
    thinking_off) thinking_off=$_v ;;
    api_duration_ms) api_duration_ms=$_v ;;
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
api_duration_ms=$(int_prefix "$api_duration_ms")
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

# ── Cache ───────────────────────────────────────────────────────────────────
# Claude Code re-runs this on every event — several times a second during an
# active turn — and the git calls below are the only genuinely slow thing on the
# row. A short-lived cache collapses those bursts without making the display
# stale: the TTL is small enough that any idle refresh still reads the tree.
#
# Keyed on session_id, which is stable for the life of a session and unique
# across concurrent ones. NOT $$, os.getpid() or similar: those change on every
# invocation, so the cache would never hit and the whole thing would be a slower
# no-op. Without a session_id the cache is simply disabled rather than guessed at.
#
# The timestamp lives in the file's FIRST LINE rather than being read from mtime:
# `stat` takes -f on BSD and -c on GNU, and this script targets both.
CACHE_DIR="${TMPDIR:-/tmp}/claude-statusline"
CACHE_OK=0
[ -n "$session_id" ] && CACHE_OK=1
case "${CLAUDE_STATUSLINE_NO_CACHE:-}" in '' | 0) ;; *) CACHE_OK=0 ;; esac

NOW=$(date +%s 2> /dev/null)
case "$NOW" in '' | *[!0-9]*) NOW=0 CACHE_OK=0 ;; esac

# cache_read <key> <ttl-seconds> — prints the payload and returns 0 when fresh.
cache_read() {
  [ "$CACHE_OK" -eq 1 ] || return 1
  local f=$CACHE_DIR/$session_id-$1 ts="" line first=1 out=""
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then
      ts=$line
      first=0
      continue
    fi
    out="${out}${line}
"
  done < "$f"
  case "$ts" in '' | *[!0-9]*) return 1 ;; esac
  [ "$((NOW - ts))" -ge "$2" ] && return 1
  [ "$((NOW - ts))" -lt 0 ] && return 1 # clock moved backwards; re-gather
  printf '%s' "$out"
}

# cache_write <key> <payload> — best effort, never fatal. Writes to a temp file
# and renames, so a refresh that lands mid-write reads the old value rather than
# half of the new one.
cache_write() {
  [ "$CACHE_OK" -eq 1 ] || return 0
  mkdir -p "$CACHE_DIR" 2> /dev/null || return 0
  local f=$CACHE_DIR/$session_id-$1
  printf '%s\n%s' "$NOW" "$2" > "$f.$$" 2> /dev/null || {
    rm -f "$f.$$" 2> /dev/null
    return 0
  }
  mv -f "$f.$$" "$f" 2> /dev/null || rm -f "$f.$$" 2> /dev/null
  return 0
}

# ── Gather git state ────────────────────────────────────────────────────────
# GIT_OPTIONAL_LOCKS=0: this runs on every refresh in the background — it must
# never contend for index.lock with the session's own git rebase/add.
export GIT_OPTIONAL_LOCKS=0
git_is_repo=0 branch="" repo_https="" repo_name="" repo_slug="" git_worktree_name=""
ahead=0 behind=0 staged=0 unstaged=0 untracked=0 conflict=0 stash=0
topl=""

# Short by design. The tree is what the agent is actively changing, so a long TTL
# would show you a stale working copy — the one thing this row exists to report.
# 3s collapses an event burst and nothing more.
GIT_CACHE_TTL=3
case "${CLAUDE_STATUSLINE_GIT_CACHE_TTL:-}" in
  '' | *[!0-9]*) ;;
  *) GIT_CACHE_TTL=$CLAUDE_STATUSLINE_GIT_CACHE_TTL ;;
esac

git_cached=0
if _gc=$(cache_read git "$GIT_CACHE_TTL"); then
  git_cached=1
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in *=*) ;; *) continue ;; esac
    _gk=${_line%%=*}
    _gv=${_line#*=}
    case "$_gk" in
      git_is_repo) git_is_repo=$_gv ;;
      topl) topl=$_gv ;;
      branch) branch=$_gv ;;
      repo_https) repo_https=$_gv ;;
      repo_name) repo_name=$_gv ;;
      repo_slug) repo_slug=$_gv ;;
      git_worktree_name) git_worktree_name=$_gv ;;
      ahead) ahead=$_gv ;;
      behind) behind=$_gv ;;
      staged) staged=$_gv ;;
      unstaged) unstaged=$_gv ;;
      untracked) untracked=$_gv ;;
      conflict) conflict=$_gv ;;
      stash) stash=$_gv ;;
    esac
  done <<< "$_gc"
fi

if [ "$git_cached" -eq 0 ] && topl=$(git rev-parse --show-toplevel 2> /dev/null) && [ -n "$topl" ]; then
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

# Persist for the next few renders. Written only on a real gather, so a cache hit
# never refreshes its own timestamp — otherwise a busy session would keep the
# entry alive indefinitely and never re-read the tree.
if [ "$git_cached" -eq 0 ]; then
  cache_write git "git_is_repo=$git_is_repo
topl=$topl
branch=$branch
repo_https=$repo_https
repo_name=$repo_name
repo_slug=$repo_slug
git_worktree_name=$git_worktree_name
ahead=$ahead
behind=$behind
staged=$staged
unstaged=$unstaged
untracked=$untracked
conflict=$conflict
stash=$stash"
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

# ── Panel ───────────────────────────────────────────────────────────────────
# Five lines, two of them content:
#
#   ╭─ owner/repo ──────────────────────────────────────────────────────────╮
#   │ @branch sigils churn │ model effort style │ $cost $burn      tagged │
#   ├─ USAGE ───────────────────────────────────────────────────────────────┤
#   │ CTX ▒▒░░ 420k/1M │ 5h ▒▒▒░ 5h0m │ 7d ▒▒░░ 2d4h                       │
#   ╰───────────────────────────────────────────────────────────────────────╯
#
# Row 1 is what this session IS; row 2 is what it is spending. Groups ride on a
# vertical rule rather than brackets, and both the frame and those rules take the
# burnt Gnar orange. The BRIGHT orange is deliberately not used as chrome — it is
# the untagged warning, and a colour that appears on every row of every repo can
# no longer raise an alarm.

pcols=$cols
[ -z "$pcols" ] && pcols=112
# Floor low enough that a narrow pane renders a cramped panel rather than one
# that overruns its width and wraps — a wrapped frame is unreadable, a tight
# one is merely tight.
[ "$pcols" -lt 24 ] && pcols=24
inner=$((pcols - 4)) # "│ " + content + " │"

FRAME=$TELEM_ON
SEP_D=" ${TELEM_ON}${FR_V}${RST} "
SEP_P=" ${FR_V} "

# Coverage rides in the TOP RULE, opposite the repo name — the two facts that are
# true of the whole panel rather than of this turn. Being out of the content rows
# also means it never competes for their columns and never sheds.
tag_d="" tag_p=""
case "$telem_state" in
  tagged) tag_p="tagged" tag_d="${TELEM_ON}$(osc8 "$TELEM_URL" 'tagged')${RST}" ;;
  untagged) tag_p="untagged" tag_d="${TELEM_OFF}$(osc8 "$TELEM_URL" 'untagged')${RST}" ;;
esac

# ── Title: the repo, as the panel's name, set into the top rule ─────────────
# Owner muted, name in the frame's own orange and bold. Same hue as the rule it
# sits in, which works because the rule is a thin run of ─ and the name is bold
# text: weight and shape separate them where colour no longer does.
if [ -n "$repo_slug" ]; then
  title_txt=$repo_slug
elif [ -n "$repo_name" ]; then
  title_txt=$repo_name
else
  title_txt=$dir_disp
fi
_title_budget=$((inner - 6 - ${#tag_p}))
[ "$_title_budget" -lt 8 ] && _title_budget=8
title_txt=$(trunc_mid "$title_txt" "$_title_budget")
if [ -n "$repo_slug" ] && [ "$title_txt" = "$repo_slug" ]; then
  title_disp="${MUTED}${repo_slug%/*}/${BOLD}${TELEM_ON}${repo_slug##*/}${RST}"
else
  title_disp="${BOLD}${TELEM_ON}${title_txt}${RST}"
fi
[ -n "$repo_https" ] && title_disp=$(osc8 "$repo_https" "$title_disp")

# ── Update check ────────────────────────────────────────────────────────────
# The one cell that cannot be computed from stdin: whether a newer Claude Code
# exists. Three rules keep it honest on a row that redraws several times a second:
#
#   1. It NEVER blocks the render. The check runs detached; this render draws
#      whatever the cache already holds, which on a cold start is nothing.
#   2. It runs at most once a day, behind the same session-keyed cache as git.
#   3. Silence is the normal state. The chip exists only when you are behind.
#
# It makes a network request, which nothing else here does — hence the opt-out,
# and hence saying so plainly in the README rather than burying it.
UPDATE_TTL=86400  # a day between checks
UPDATE_RETRY=3600 # ...but retry an hour after a failed one
UPDATE_URL='https://registry.npmjs.org/@anthropic-ai/claude-code/latest'

update_enabled=1
case "${CLAUDE_STATUSLINE_NO_UPDATE_CHECK:-}" in '' | 0) ;; *) update_enabled=0 ;; esac
[ "$CACHE_OK" -eq 1 ] || update_enabled=0
[ -n "$cc_version" ] || update_enabled=0
command -v curl > /dev/null 2>&1 || update_enabled=0

# ver_gt <a> <b> — 0 when a is strictly newer than b. Dotted integers only, and
# non-numeric components (a "2.1.0-beta") compare as 0, which makes a prerelease
# read as older than its release rather than sorting unpredictably.
ver_gt() {
  local a=$1 b=$2 i=0 x y
  for i in 1 2 3; do
    x=${a%%.*} y=${b%%.*}
    case "$x" in '' | *[!0-9]*) x=0 ;; esac
    case "$y" in '' | *[!0-9]*) y=0 ;; esac
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
    case "$a" in *.*) a=${a#*.} ;; *) a=0 ;; esac
    case "$b" in *.*) b=${b#*.} ;; *) b=0 ;; esac
  done
  return 1
}

# Detached, output discarded, hard timeout. A statusline must never leave a
# process hanging around waiting on a socket.
spawn_update_check() {
  cache_write version "" # claim the slot first, so concurrent renders don't all fetch
  (
    _latest=$(curl -fsS --max-time 5 "$UPDATE_URL" 2> /dev/null |
      jq -r '.version // empty' 2> /dev/null)
    case "$_latest" in
      '' | *[!0-9.]*) exit 0 ;; # unparseable: leave the empty claim to expire
    esac
    cache_write version "$_latest"
  ) > /dev/null 2>&1 &
}

update_chip=""
if [ "$update_enabled" -eq 1 ]; then
  if _cached=$(cache_read version "$UPDATE_TTL"); then
    _latest=${_cached%%
*}
    if [ -n "$_latest" ]; then
      ver_gt "$_latest" "$cc_version" && update_chip="↑${_latest}"
    elif ! cache_read version "$UPDATE_RETRY" > /dev/null; then
      # An empty entry is a claim whose fetch failed. Retry on the hour rather
      # than staying silent for a full day over one dropped request.
      spawn_update_check
    fi
  else
    spawn_update_check
  fi
fi

# ── Row 1 ───────────────────────────────────────────────────────────────────
# Built at a shed level; the caller walks levels up until the row fits. Sets
# R1_D (display) and R1_P (its visible-length twin).
#
# Shed order, cheapest loss first: the per-hour burn (derived, recomputable from
# the total), then the output style (set once, rarely re-read), then this
# session's churn (the tree state above it is the urgent half), then the branch
# name itself, middle-ellipsized. The coverage tag never sheds — it is anchored
# to the right edge, so what gives way is always on the left.
build_row1() {
  local lvl=$1 bmax=$2
  local n=0 d p b wt
  G_D=() G_P=()

  # git — branch, worktree, working-tree sigils, this session's churn
  if [ -n "$branch" ]; then
    b=$(trunc_mid "$branch" "$bmax")
    wt=$git_worktree_name
    [ -z "$wt" ] && wt=$worktree_name_input
    # A worktree name that is NOT already inside the branch costs a suffix, and
    # that suffix is the next thing to give once the branch itself is truncated.
    [ "$lvl" -ge 3 ] && [ "${b#*"$wt"}" = "$b" ] && wt=""
    p="${SIG_BRANCH}${b}"
    # Claude Code names its worktree branches worktree-<name>, so the name is
    # already inside the branch. Recolour that run in place rather than restating
    # it — same information, ~23 fewer columns on the common case.
    if [ -n "$wt" ] && [ "${b#*"$wt"}" != "$b" ]; then
      d="${BLUE}${SIG_BRANCH}${b%%"$wt"*}${MAGENTA}${wt}${BLUE}${b#*"$wt"}${RST}"
    else
      d="${BLUE}${SIG_BRANCH}${b}${RST}"
      if [ -n "$wt" ]; then
        d="${d}${MUTED}/${MAGENTA}${wt}${RST}"
        p="${p}/${wt}"
      fi
    fi
    [ -n "$repo_https" ] && [ -n "$branch" ] &&
      d=$(osc8 "${repo_https}/tree/${branch}" "$d")

    # Working-tree state, most urgent first — a conflict or unpushed commits are
    # what you cannot afford to miss; a stash count is what you can.
    if [ "$lvl" -lt 4 ]; then
      [ "$conflict" -gt 0 ] && d="${d} ${BOLD}${RED}x${conflict}${RST}" && p="${p} x${conflict}"
      [ "$ahead" -gt 0 ] && d="${d} ${GREEN}^${ahead}${RST}" && p="${p} ^${ahead}"
      [ "$behind" -gt 0 ] && d="${d} ${RED}v${behind}${RST}" && p="${p} v${behind}"
      [ "$unstaged" -gt 0 ] && d="${d} ${YELLOW}!${unstaged}${RST}" && p="${p} !${unstaged}"
      [ "$staged" -gt 0 ] && d="${d} ${GREEN}+${staged}${RST}" && p="${p} +${staged}"
      [ "$untracked" -gt 0 ] && d="${d} ${CYAN}?${untracked}${RST}" && p="${p} ?${untracked}"
      [ "$stash" -gt 0 ] && d="${d} ${MAGENTA}*${stash}${RST}" && p="${p} *${stash}"
    fi

    if [ "$lvl" -lt 3 ] && { [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; }; then
      local ca cr
      ca=$(abbrev_num "$lines_added")
      cr=$(abbrev_num "$lines_removed")
      d="${d} ${GREEN}${BOLD}+${ca}${RST}${MUTED}/${RED}${BOLD}-${cr}${RST}"
      p="${p} +${ca}/-${cr}"
    fi
    G_D[n]=$d
    G_P[n]=$p
    n=$((n + 1))
  fi

  # config — every knob that decides how this session behaves
  d="" p=""
  if [ "$lvl" -lt 6 ] && [ -n "$model_name" ]; then
    d="${CYAN}${model_name}${RST}"
    p="$model_name"
  fi
  if [ -n "$effort_cap" ]; then
    [ -n "$p" ] && d="${d} " && p="${p} "
    d="${d}${GREEN}${effort_cap}${RST}"
    p="${p}${effort_cap}"
  fi
  # Fast mode changes how the model responds, so it belongs beside effort — and it
  # is off by default, so the cell is absent unless it is telling you something.
  if [ -n "$fast_mode" ]; then
    [ -n "$p" ] && d="${d} " && p="${p} "
    d="${d}${BOLD}${CYAN}Fast${RST}"
    p="${p}Fast"
  fi
  # Only ever rendered when thinking is EXPLICITLY off. Absent means "Claude Code
  # did not say", which is not the same as disabled and must not look like it.
  if [ -n "$thinking_off" ]; then
    [ -n "$p" ] && d="${d} " && p="${p} "
    d="${d}${YELLOW}NoThink${RST}"
    p="${p}NoThink"
  fi
  if [ "$lvl" -lt 2 ] && [ -n "$output_style" ]; then
    [ -n "$p" ] && d="${d} " && p="${p} "
    d="${d}${MAGENTA}${output_style}${RST}"
    p="${p}${output_style}"
  fi
  if [ -n "$p" ]; then
    G_D[n]=$d
    G_P[n]=$p
    n=$((n + 1))
  fi

  # update — absent unless you are behind, so it costs nothing in the normal case
  if [ "$lvl" -lt 1 ] && [ -n "$update_chip" ]; then
    G_D[n]="${YELLOW}${update_chip}${RST}"
    G_P[n]="$update_chip"
    n=$((n + 1))
  fi

  # spend — the one derived number on the row, and the only one still moving
  if [ "$lvl" -lt 5 ] && [ -n "$money_total" ]; then
    d="${GREEN}${money_total}${RST}"
    p="$money_total"
    if [ "$lvl" -lt 1 ] && [ -n "$money_burn" ]; then
      d="${d}  ${GREEN}${money_burn}${RST}"
      p="${p}  ${money_burn}"
    fi
    if [ "$lvl" -lt 1 ] && [ -n "$api_pct" ]; then
      d="${d}  ${MUTED}api ${api_pct}%${RST}"
      p="${p}  api ${api_pct}%"
    fi
    G_D[n]=$d
    G_P[n]=$p
    n=$((n + 1))
  fi
  G_N=$n
}

# Join the groups across the row: first hard left, the slack shared evenly between
# the rules in between — space-between, not packed-left. A row that ends in a long
# blank run reads as truncated; one that reaches both edges reads as laid out.
#
# The gap is CAPPED, though, because unbounded space-between degenerates: a wide
# pane holding only two short groups pushed them to opposite walls with the rule
# marooned ~40 columns from anything, which reads as a rendering fault rather than
# as layout. Past the cap the row simply stops short of the right edge, which is
# the lesser of the two wrongs.
MAX_GROUP_GAP=16
assemble_row1() {
  local i slack per extra rem left right
  R1_D="" R1_P=""
  [ "$G_N" -eq 0 ] && return 0
  local sum=0
  for ((i = 0; i < G_N; i++)); do sum=$((sum + ${#G_P[i]})); done
  slack=$((inner - sum - (G_N - 1) * 3))
  [ "$slack" -lt 0 ] && slack=0
  per=0 rem=0
  if [ "$G_N" -gt 1 ]; then
    per=$((slack / (G_N - 1)))
    rem=$((slack % (G_N - 1)))
    if [ "$per" -ge "$MAX_GROUP_GAP" ]; then
      per=$MAX_GROUP_GAP
      rem=0
    fi
  fi
  for ((i = 0; i < G_N; i++)); do
    if [ "$i" -gt 0 ]; then
      extra=$per
      [ "$((i - 1))" -lt "$rem" ] && extra=$((extra + 1))
      left=$((extra / 2))
      right=$((extra - left))
      R1_D="${R1_D}$(rep ' ' "$((left + 1))")${TELEM_ON}${FR_V}${RST}$(rep ' ' "$((right + 1))")"
      R1_P="${R1_P}$(rep ' ' "$((left + 1))")${FR_V}$(rep ' ' "$((right + 1))")"
    fi
    R1_D="${R1_D}${G_D[i]}"
    R1_P="${R1_P}${G_P[i]}"
  done
}

# Effort: a 2-3 char label per tier. The cell is a dial position — you read it
# against the other tiers, not as a word — so every tier abbreviates.
case "$effort_level" in
  "") effort_cap="" ;;
  low) effort_cap="Lo" ;;
  medium) effort_cap="Med" ;;
  high) effort_cap="Hi" ;;
  xhigh) effort_cap="XHi" ;;
  max) effort_cap="Max" ;;
  *) effort_cap="$(printf '%s' "${effort_level:0:1}" | tr '[:lower:]' '[:upper:]')${effort_level:1}" ;;
esac

# Spend, split so the burn can shed without taking the total with it. Detect the
# burn by its UNIT, never by punctuation: a previous version keyed the shed on a
# literal " (" and silently stopped matching when the parens were dropped, which
# sent gflush after the whole cost member and lost the total too.
# Share of the session spent blocked on the API, from two duration fields that
# have always been on stdin. Gated on a minute of session so a fresh session does
# not report a wild ratio off a few hundred milliseconds, and clamped because the
# two clocks are measured independently and can disagree at the margin.
api_pct=""
if [ "$duration_ms" -ge 60000 ] && [ "$api_duration_ms" -gt 0 ]; then
  api_pct=$((api_duration_ms * 100 / duration_ms))
  [ "$api_pct" -gt 100 ] && api_pct=100
fi

money_total="" money_burn=""
if [ -n "$cost_usd" ]; then
  money_total=$(awk -v c="$cost_usd" 'BEGIN{ if (c ~ /^[0-9]+(\.[0-9]+)?$/) printf "$%.2f", c }')
  money_burn=$(awk -v c="$cost_usd" -v d="$duration_ms" 'BEGIN{
    if (c ~ /^[0-9]+(\.[0-9]+)?$/ && c+0 > 0 && d+0 >= 60000)
      printf "$%.2f/h", (c+0) / ((d+0)/3600000.0)
  }')
fi

R1_D="" R1_P=""
G_D=() G_P=() G_N=0
_BRANCH_FLOOR=6
_bmax=${#branch}
[ "$_bmax" -lt 1 ] && _bmax=1
for _lvl in 0 1 2 3 4 5 6; do
  build_row1 "$_lvl" "$_bmax"
  _w=0
  for ((_i = 0; _i < G_N; _i++)); do _w=$((_w + ${#G_P[_i]})); done
  _w=$((_w + (G_N - 1) * 3))
  [ "$_w" -le "$inner" ] && break
  # Last resort: give back exactly the overflow from the branch name.
  if [ "$_lvl" -ge 5 ]; then
    _cut=$((_bmax - (_w - inner)))
    [ "$_cut" -lt "$_BRANCH_FLOOR" ] && _cut=$_BRANCH_FLOOR
    build_row1 "$_lvl" "$_cut"
    # Keep the trimmed build. Falling through to the next level would rebuild at
    # full branch width and undo it, which is what made a long branch never
    # ellipsize at all.
    break
  fi
done
assemble_row1

# ── Row 2: the meters ───────────────────────────────────────────────────────
# One texture, three hues, each bar labelled in front of it. No clock ticks and
# no projection: the row states magnitude, not pace.
# time_left <resets-at> <window-minutes> -> "5h0m" / "2d4h" / "12m"
time_left() {
  local resets=$1 wmin=$2 remain_sec remain_min
  case "$resets" in '' | *[!0-9]*) resets=0 ;; esac
  remain_sec=$((resets > NOW ? resets - NOW : 0))
  remain_min=$((remain_sec / 60))
  [ "$remain_min" -gt "$wmin" ] && remain_min=$wmin
  if [ "$remain_min" -ge 1440 ]; then
    printf '%dd%dh' "$((remain_min / 1440))" "$(((remain_min % 1440) / 60))"
  elif [ "$remain_min" -ge 60 ]; then
    printf '%dh%dm' "$((remain_min / 60))" "$((remain_min % 60))"
  else
    printf '%dm' "$remain_min"
  fi
}

used_int=$(int_prefix "$used_pct")

# The CTX label carries the autocompact warning. With the percentage gone there is
# no number left to escalate, and the bar is one flat texture with no boundary to
# mark — so the label itself is the threshold indicator: green while there is
# room, amber as it closes, red once autocompact will fire on the next turn.
ctx_lab_color=$GREEN
if [ "$used_int" -ge "$ac" ]; then
  ctx_lab_color="${BOLD}${RED}"
elif [ "$used_int" -ge $((ac - 15)) ]; then
  ctx_lab_color=$YELLOW
fi

# WINDOW_LOUD_PCT: a window's percentage is shown only at or above this. A bar
# cannot tell you 73% from 78%, and that distinction only matters near the limit —
# so the number costs its columns in the state that wants them and no other.
WINDOW_LOUD_PCT=70

m_lab=() m_labcol=() m_pct=() m_fill=() m_tail=()
add_meter() {
  local i=${#m_lab[@]}
  m_lab[i]=$1 m_labcol[i]=$2 m_pct[i]=$3 m_fill[i]=$4 m_tail[i]=$5
}

ctx_tok=""
if [ "$ctx_input_tokens" -gt 0 ]; then
  if [ "$ctx_window_size" -gt 0 ]; then
    ctx_tok="$(abbrev_num "$ctx_input_tokens")/$(abbrev_num "$ctx_window_size")"
  else
    ctx_tok="$(abbrev_num "$ctx_input_tokens")"
  fi
fi
add_meter CTX "$ctx_lab_color" "$used_int" "$CTX_HUE" "$ctx_tok"

if [ -n "$five_pct" ] && [ -n "$five_resets_at" ]; then
  _p=$(int_prefix "$five_pct")
  _t=$(time_left "$five_resets_at" 300)
  [ "$_p" -ge "$WINDOW_LOUD_PCT" ] && _t="${_p}% ${_t}"
  add_meter 5h "$FIVE_HUE" "$_p" "$FIVE_HUE" "$_t"
fi
if [ -n "$seven_pct" ] && [ -n "$seven_resets_at" ]; then
  _p=$(int_prefix "$seven_pct")
  _t=$(time_left "$seven_resets_at" 10080)
  [ "$_p" -ge "$WINDOW_LOUD_PCT" ] && _t="${_p}% ${_t}"
  add_meter 7d "$SEVEN_HUE" "$_p" "$SEVEN_HUE" "$_t"
fi

# Bars split what the labels and tails leave, CTX taking the remainder so the
# widest meter is the one watched most. Below MIN_BAR the CTX token readout is
# the first thing to go, then the meters render at the floor and the row is
# allowed to be narrow rather than dropping a meter entirely — a missing meter
# reads as "no data", which is a different and wrong statement.
build_row2() {
  local drop_tok=$1 drop_tails=$2 minbar=$3 nm=${#m_lab[@]} fixed=0 i w rem
  [ "$nm" -eq 0 ] && return 1
  for ((i = 0; i < nm; i++)); do
    fixed=$((fixed + ${#m_lab[i]} + 1)) # label + space before bar
    local t=${m_tail[i]}
    [ "$drop_tails" -eq 1 ] && t=""
    [ "$i" -eq 0 ] && [ "$drop_tok" -eq 1 ] && t=""
    [ -n "$t" ] && fixed=$((fixed + 1 + ${#t}))
    [ "$i" -gt 0 ] && fixed=$((fixed + ${#SEP_P}))
  done
  w=$(((inner - fixed) / nm))
  [ "$w" -lt "$minbar" ] && return 1
  rem=$((inner - fixed - w * nm))
  R2_D="" R2_P=""
  for ((i = 0; i < nm; i++)); do
    local bw=$w t=${m_tail[i]}
    [ "$i" -eq 0 ] && bw=$((w + rem))
    [ "$drop_tails" -eq 1 ] && t=""
    [ "$i" -eq 0 ] && [ "$drop_tok" -eq 1 ] && t=""
    if [ "$i" -gt 0 ]; then
      R2_D="${R2_D}${SEP_D}"
      R2_P="${R2_P}${SEP_P}"
    fi
    R2_D="${R2_D}${m_labcol[i]}${m_lab[i]}${RST} $(render_bar "${m_pct[i]}" "$bw" "${m_fill[i]}")"
    R2_P="${R2_P}${m_lab[i]} $(rep "$BAR_TRACK" "$bw")"
    if [ -n "$t" ]; then
      R2_D="${R2_D} ${MUTED}${t}${RST}"
      R2_P="${R2_P} ${t}"
    fi
  done
  return 0
}

R2_D="" R2_P=""
build_row2 0 0 6 || build_row2 1 0 6 || build_row2 1 1 6 || build_row2 1 1 3 || {
  _txt=""
  for ((_i = 0; _i < ${#m_lab[@]}; _i++)); do
    [ -n "$_txt" ] && _txt="${_txt} "
    _txt="${_txt}${m_lab[_i]} ${m_pct[_i]}%"
  done
  [ -z "$_txt" ] && _txt="no usage data yet"
  _txt=$(trunc_mid "$_txt" "$inner")
  R2_D="${MUTED}${_txt}${RST}"
  R2_P="$_txt"
}

# ── Emit ────────────────────────────────────────────────────────────────────
# rule <left> <right> <label-disp> <label-width> [<right-label-disp> <right-width>]
#
# Widths are passed rather than measured because the display strings carry ANSI
# and OSC8 payloads that ${#...} would count.
rule() {
  local fill
  if [ -n "${5:-}" ]; then
    fill=$((pcols - 7 - $4 - $6))
    [ "$fill" -lt 1 ] && fill=1
    printf '%s%s%s%s %s %s%s%s %s %s%s%s\n' \
      "$FRAME" "$1" "$FR_H" "$RST" "$3" \
      "$FRAME" "$(rep "$FR_H" "$fill")" "$RST" "$5" "$FRAME" "$2" "$RST"
  else
    fill=$((pcols - 5 - $4))
    [ "$fill" -lt 1 ] && fill=1
    printf '%s%s%s%s %s %s%s%s%s\n' \
      "$FRAME" "$1" "$FR_H" "$RST" "$3" "$FRAME" \
      "$(rep "$FR_H" "$fill")" "$2" "$RST"
  fi
}

# content <display> <visible-length>
content() {
  printf '%s%s%s %s%s %s%s%s\n' \
    "$FRAME" "$FR_V" "$RST" "$1" "$(rep ' ' "$((inner - $2))")" \
    "$FRAME" "$FR_V" "$RST"
}

rule "$FR_TL" "$FR_TR" "$title_disp" "${#title_txt}" "$tag_d" "${#tag_p}"
content "$R1_D" "${#R1_P}"

rule "$FR_ML" "$FR_MR" "${BOLD}${TELEM_ON}USAGE${RST}" 5
content "$R2_D" "${#R2_P}"
printf '%s%s%s%s%s\n' "$FRAME" "$FR_BL" "$(rep "$FR_H" "$((pcols - 2))")" "$FR_BR" "$RST"

# Always succeed: a statusline must never signal failure to Claude Code (a
# trailing conditional would otherwise leak a non-zero status).
exit 0
