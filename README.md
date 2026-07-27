# claude-statusline

The Gnar Company's [Claude Code](https://claude.com/claude-code) statusline + subagent
statusline, each a single bash script. No Rust, no extra binaries — just `git` and `jq`.
Targets macOS system bash (3.2) so it's a portable drop-in.

## What it shows

```
claude-statusline [reviewer][@main/wt][?1 !2 +3][+42/-7][Opus 4.8 1M High Explanatory][N][$1.23 ($7.38/h)]
CTX ####--------------------|-----  13% 128k/1M cache 78% 67%->AC
5h  |###########------------------  40% 3h 12m left [+8%] 7d 22%
```

Pure ASCII (`#` fill, `-` track, `|` clock/threshold, `*` burn projection) — no Nerd Font
required. Bars size themselves to the terminal via the `COLUMNS` env var, holding back a
small margin so they never overrun Claude's own chrome. The layout stays compact: **2–4
lines** — identity and config share one row of colored `[]` groups, and the 7-day window
shows only when it's the binding one.

- **Line 1** — one packed row of colored `[]` groups that wrap to a continuation line only when they won't fit the pane:
  - **`[name]`** — session/agent name for orienting among many concurrent tabs: `agent.name` (a spawned/`--agent` context, magenta) wins over your `session_name` (cyan) when both are set.
  - **`[@branch/worktree]`** — repo (title, links to GitHub), branch (links to the tree), and worktree. Long branch/worktree names are middle-ellipsized (`feature/some-l..name-here`) to a width budget.
  - **`[counters]`** — git state as colored ASCII sigils, space-separated: `*`stash `x`conflict `?`untracked `!`modified `+`staged `^`ahead `v`behind (e.g. `[?1 !2 +3]`).
  - **`[+added/-removed]`** — session churn.
  - **`[model 1M effort style]`** — model, context-window flag (`1M` for the extended window), reasoning effort (`XHi`/`Max` for the high tiers), output style.
  - **`[N]`** — vim mode (`N`/`I`/`V`/`V-L`), colored by mode; shown only when vim mode is on.
  - **`[$cost ($/h)]`** — session cost + per-hour burn.

  (No PR cell — Claude Code already surfaces the current PR.)
- **Line 2** — context window with a blackbody-gradient bar; an amber cell marks the autocompact threshold. The `%` escalates green→amber→red as it approaches; below the threshold a `N%->AC` badge shows live headroom, and once crossed a `[AC]` chip (plus `[200k+]` past 200k tokens). Trailing `Nk/Nk` is tokens-in-context / window size, and `cache N%` is the share served from the prompt cache.
- **Line 3** — the 5-hour rate-limit window. The blue pip is the wall-clock position in the window; the yellow pip projects end-of-window usage at the current burn rate; `time left` counts down to the reset; `[+N%]` is usage-vs-clock delta. When the 7-day window isn't binding it rides here as a compact `7d N%` badge.
- **Line 4** — the 7-day window, shown as its own bar only when it's ≥50% or busier than the 5-hour window.

Repo and branch cells are OSC8 hyperlinks — ⌘-click them in a supporting terminal.

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

The command fetches a pinned release of these scripts, backs up any existing statusline
config, and wires `~/.claude/settings.json` for you. It also offers a **Customize** mode
that walks the lines and installs a tailored copy.

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
- The statusline writes nothing to disk — every cell is rendered from the JSON Claude Code passes on stdin.
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
