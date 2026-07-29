# claude-statusline

The Gnar Company's [Claude Code](https://claude.com/claude-code) statusline + subagent
statusline, each a single bash script. No Rust, no extra binaries — just `git` and `jq`.
Targets macOS system bash (3.2) so it's a portable drop-in.

## What it shows

```
TheGnarCo/claude-statusline [@main/wt ^2 !2 +3][reviewer +42/-7 $1.23 ($7.38/h)][Opus 4.8 1M High N Explanatory][telem tag]
CTX ####--------------------|-----  13% 128k/1M cache 78% 67%->AC
5h  |###########------------------  40% 3h 12m left [+8%] 7d 22%
```

Pure ASCII (`#` fill, `-` track, `|` clock/threshold, `*` burn projection) — no Nerd Font
required. Bars size themselves to the terminal via the `COLUMNS` env var, holding back a
small margin so they never overrun Claude's own chrome. The layout stays compact: **2–4
lines** — identity and config share one row of colored `[]` groups, and the 7-day window
shows only when it's the binding one.

- **Line 1** — the repo as **`owner/name`** (linked to GitHub; the owner is muted so the repo name stays the anchor), or the cwd's last two components outside a repo — then **one `[]` per concept**: a bracket is a group of related cells, not a single field, so the eye stops three times instead of eight. Groups pack left-to-right and wrap to a continuation line only when they won't fit the pane. Members are space-separated, each keeping its own color, and any member with nothing to say drops out (an all-empty group renders no bracket at all):
  - **`[@branch/worktree counters +added/-removed]`** — **git**. Branch (blue, links to the tree) and worktree (magenta), then the working-tree state as colored ASCII sigils: `x`conflict `^`ahead `v`behind `!`modified `+`staged `?`untracked `*`stash, and finally this session's churn — e.g. `[@main/wt ^2 !2 +3 +120/-45]`. The churn trails because the counters say what is in the tree now and the churn says how it got there; it's the first member of the group to go on a narrow pane. Ordered most-urgent-first, which is also the order a too-narrow pane gives them up in (from the tail): a conflict or unpushed commits are what you cannot afford to miss, a stash count is what you can. Long branch/worktree names are middle-ellipsized (`feature/some-l..name-here`) to a width budget. When the worktree name is **already part of the branch** — which it always is for Claude Code's `worktree-<name>` branches — it isn't restated as a suffix; that run of the branch is recolored magenta in place, which is the same information for 23 fewer columns (`[@worktree-my-fix/my-fix]` → `[@worktree-`**`my-fix`**`]`). A worktree whose name isn't in the branch still gets its `/suffix`.
  - **`[name model 1M effort style $cost ($/h)]`** — **this session**: who it is and every knob that decides how it behaves. The name leads and orients you among many concurrent tabs — `agent.name` (a spawned/`--agent` context, magenta) wins over your `session_name` (cyan) when both are set, and an agent that never picked a type is named `claude`, which names nothing and can't tell two agents apart, so it's dropped and the slot falls back to `session_name`. Then model, context-window flag (`1M` for the extended window), reasoning effort (`Lo`/`Med`/`Hi`/`XHi`/`Max` — you read it against the other tiers, not as a word), and output style — the style appears only when a **non-default** one is set (Claude Code names the built-in style `claude`, which said nothing and sat on every row). Cost + per-hour burn trail: the group's one derived number, and the only member that keeps moving on its own. The `($/h)` half is kept only when the **whole row** still fits on one line with it — a burn rate that costs a wrapped line costs more than it says.
  - **`[telem tag]` / `[no telem tag]`** — **telemetry coverage**. Whether this repo's Claude Code usage is attributed to a project in [telem.thegnar.info](https://telem.thegnar.info) (a `project.name` OTEL attribute). Two shades of one hue, because this is a single dial with two positions rather than two unrelated states: dim burnt orange when it is; bright orange when it isn't and the usage lands there under *(untagged)* — run `/toolkit:project-telem-tag` in the repo to fix that. Nothing rests on telling the shades apart, since the chips already differ by the word *no*. Both states link to the dashboard. Only rendered inside a git repo, and it sits last so it's the first group to spill onto a continuation line on a narrow pane.

  (No PR cell — Claude Code already surfaces the current PR.)
- **Line 2** — context window with a blackbody-gradient bar; an amber cell marks the autocompact threshold. The `%` escalates green→amber→red as it approaches; below the threshold a `N%->AC` badge shows live headroom, and once crossed a `[AC]` chip (plus `[200k+]` past 200k tokens). Trailing `Nk/Nk` is tokens-in-context / window size, and `cache N%` is the share served from the prompt cache.
- **Line 3** — the 5-hour rate-limit window. The blue pip is the wall-clock position in the window; the yellow pip projects end-of-window usage at the current burn rate; `time left` counts down to the reset; `[+N%]` is usage-vs-clock delta. When the 7-day window isn't binding it rides here as a compact `7d N%` badge.
- **Line 4** — the 7-day window, shown as its own bar only when it's ≥50% or busier than the 5-hour window.

Every linked cell — repo, branch, telemetry chip — is an OSC8 hyperlink and renders
**underlined**, so you can tell what's clickable before you try it; ⌘-click them in a
supporting terminal. Under cmux the escape is dropped (it miscounts the
zero-width payload), and the underline goes with it — the text
stays, the promise of a link doesn't.

Colors honor [`NO_COLOR`](https://no-color.org) and degrade to a 256-color ramp on
terminals without truecolor (`COLORTERM`); the ASCII pip shapes keep the bars legible even
with color off entirely.

## The subagent statusline

`subagent-statusline.sh` is the second export of this repo, and a peer of the main
statusline rather than an add-on. It drives Claude Code's **agent panel** — the per-task
rows shown for spawned subagents — and is wired separately, via `subagentStatusLine`.

It reads Claude Code's subagent JSON on stdin and emits `{"tasks":[...]}` on stdout in a
single `jq` pass (no per-task subshell, `awk`, or `date` forks). Per task it reports:

- **`state`** — `success` / `error` / `inactive`, mapped from the reported status.
  `complete`, `completed`, `succeeded`, `success` → `success`; `failed`, `error` → `error`;
  `inactive`, `idle` → `inactive`; anything else (i.e. still running) → `success`.
- **`elapsed`** — `30s` / `2m05s` / `1h02m`, compacted to `30s` / `2m` / `1h` when the
  panel is narrow (`columns < 100`).
- **`tokenText`** — integer abbreviation, no decimals or float math: `42` / `12k` / `1M`.

Output keys are emitted sorted, so the JSON is deterministic and diffable. Malformed or
non-object input — and a missing `jq` — degrade to an empty panel (`{"tasks":[]}`) rather
than an error, on the same "must never fail" principle as the main statusline.

## Requirements

- `git` and `jq` on `PATH`.
- No special font — output is pure ASCII.
- Claude Code v2.1.153+ for `COLUMNS`-based bar sizing (older versions fall back to a fixed width).
- Works with macOS system bash (3.2) and newer.

## Install

### Via the Gnar plugin (recommended)

Install the `toolkit` plugin from the [`gnar` marketplace](https://github.com/TheGnarCo/agent-skills)
and run:

```
/gnar-statusline
```

The command fetches the latest release of these scripts, backs up any existing statusline
config, and wires `~/.claude/settings.json` for you.

### Manual

```sh
git clone https://github.com/TheGnarCo/claude-statusline ~/Code/claude-statusline
~/Code/claude-statusline/install.sh
```

`install.sh` symlinks both scripts into `~/.local/bin`, then add to `~/.claude/settings.json`:

```json
{
  "statusLine":         { "type": "command", "command": "~/.local/bin/claude-statusline", "refreshInterval": 15 },
  "subagentStatusLine": { "type": "command", "command": "~/.local/bin/claude-subagent-statusline" }
}
```

`refreshInterval` is recommended here: status lines are otherwise event-driven, so the
time-based cells (the 5h/7d clock pips, `time left`, and the burn projection) would
freeze while the session sits idle. A 15s timer keeps them live. Omit it to update only
on events.

## Notes

- The 5h window shows `no rate-limit data yet` until you've made a request in the session that populates it.
- The statusline writes nothing to disk. Every cell is rendered from the JSON Claude Code passes on stdin, except the telem-tag chip, which also reads the repo's `.claude/settings.json` — and only when the attribute isn't already in the environment.
- Hide the telem-tag chip with `CLAUDE_STATUSLINE_HIDE_TELEM=1` (for anyone not sending OTEL telemetry, where the cell has nothing to say).
- Set the autocompact marker with `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (1–100); defaults to 80.
- Tune the right-edge chrome reserve with `CLAUDE_STATUSLINE_CHROME_MARGIN` (columns held back from the bar width); defaults to 8. Set `0` to fill edge-to-edge.

## Tests

`test/run.sh` renders the script against fixture payloads and diffs the ANSI-stripped
output against golden snapshots in `test/golden/`, plus color-mode and exit-code
assertions. Run `test/run.sh` to check, `test/run.sh --update` to refresh the snapshots
after an intentional change.

## Provenance

Seeded from [`alxjrvs/claude-statusline`](https://github.com/alxjrvs/claude-statusline)
at `7107dc5`, by its author.

The difference between the two repos is **ownership, not features**. That one is one
person's statusline, shaped to one person's taste. This one is **owned collectively by
The Gnar Company** going forward — anyone here can change it, and it evolves by whatever
the team decides it should show.

So the two will diverge, but not from a spec written up front: they diverge because
different people steer them. Nothing is synced in either direction, and there is
deliberately no drift check between them. Cherry-pick by hand when a fix genuinely suits
both.

## License

[MIT](./LICENSE) © The Gnar Company, Inc.
