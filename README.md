# claude-statusline

The Gnar Company's [Claude Code](https://claude.com/claude-code) statusline +
subagent statusline, each a single bash script. No Rust, no extra binaries — just
`git` and `jq`. Targets macOS system bash (3.2) so it's a portable drop-in.

## What it shows

```
╭─ TheGnarCo/claude-statusline ────────────────────────────────────────────────────────────────────── untagged ╮
│ @work ^3 v2 !1 +1 ?1 *1 +120/-45         │         Opus 4.8 Hi Explanatory         │         $1.23  $7.38/h  │
├─ USAGE ──────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ CTX ▒▒▒▒▒▒▒▒▒▒░░░░░░░░░░░░░░ 420k/1M │ 5h ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░░ 73% 5h0m │ 7d ▒▒▒▒▒▒▒▒▒▒░░░░░░░░░░░░░ 7d0h │
╰──────────────────────────────────────────────────────────────────────────────────────────────────────────────╯
```

*(That block is `test/golden/panel-full.txt` verbatim — the suite pins it, so it
cannot drift from what the script actually prints.)*

A five-line panel with two rows of content. **The top rule carries what is true of
the whole panel** — the repo, and whether its usage is attributed in telemetry.
**Row 1 is what this session is**; **row 2 is what it is spending**. Both content
rows are divided by vertical rules in burnt Gnar orange, the same colour as the
frame.

### The marks

Every meter is one texture: a mid shade over a light track.

| Mark | Meaning |
| --- | --- |
| `▒` | spent |
| `░` | untouched |

The three meters are told apart by **the label immediately in front of each one**
and by colour — context purple, the 5-hour window warm, the 7-day window blue.
That is a deliberate reversal of the per-row glyph tiers this statusline used to
have: those existed because bars stacked on separate rows had no adjacent label to
disambiguate them. Side by side, they do.

### Row 1 — what this session is

Groups are separated by a vertical rule and **spread across the full row**
(space-between), so the row reaches both edges rather than trailing off into
blank. Each group drops out entirely when it has nothing to say.

- **git** — the branch (blue, linked to the tree) with its `@` sigil and, when the
  active worktree's name isn't already part of the branch, a magenta `/worktree`
  suffix. Claude Code names its worktree branches `worktree-<name>`, so that run
  is recoloured in place instead of restated. Then the working tree as coloured
  ASCII sigils, most urgent first — `x`conflict `^`ahead `v`behind `!`modified
  `+`staged `?`untracked `*`stash — and finally this session's churn `+N/-M`.
- **config** — model (cyan), reasoning effort (green, as `Lo`/`Med`/`Hi`/`XHi`/`Max`
  — you read it against the other tiers, not as a word), and output style
  (magenta), which appears only when a **non-default** style is set.
- **update** — `↑2.1.240` (yellow) when a newer Claude Code exists. Absent when
  you're current, which is almost always. See [Update check](#update-check).
- **spend** — total cost and per-hour burn (green).

When the pane narrows, the row sheds cheapest-loss-first, one rung at a time:

| Rung | What goes |
| --- | --- |
| 1 | the derived per-hour burn (recomputable from the total) |
| 2 | the output style |
| 3 | this session's churn **and** a worktree suffix that isn't already in the branch |
| 4 | the working-tree sigils |
| 5 | the spend |
| 6 | the config group |

Only after all six does the branch name itself middle-ellipsize — and then by
**exactly the overflow**, never to a fixed stub, so a pane that can hold most of
a branch shows most of it. It will not shrink below 6 characters.

### Row 2 — what it is spending

Three meters, each `LABEL bar detail`. **There are no percentages**: the bar is
the proportion. What sits beside each meter is what a bar cannot say.

- **CTX** — tokens in context over the window size (`420k/1M`). Its **label is the
  autocompact indicator**, escalating green → amber → bold red as it closes on the
  threshold. With no percentage left to escalate and a flat bar with no boundary to
  mark, the label is where that warning lives. Default threshold 80%; override with
  `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`.
- **5h / 7d** — the rate-limit windows, each with its time to reset (`5h0m`,
  `2d4h`). A window shows its percentage **only at 70% or above**: a bar cannot
  separate 73% from 78%, and that difference only matters near the limit, so the
  number costs its columns in the state that wants them and no other.

A meter is never dropped to save room — a missing meter reads as "no data", which
is a different and wrong statement. On a narrow pane the bars shrink instead.

### Links

The repo title, the branch, and the coverage tag are OSC8 hyperlinks, rendered
**underlined** so you can tell what is clickable before you try it; ⌘-click them
in a supporting terminal. Under cmux the escape is dropped (it miscounts the
zero-width payload) and the underline goes with it — the text stays, the promise
of a link doesn't.

### Coverage

`tagged` / `untagged` in the top rule says whether this repo's Claude Code usage is
attributed to a project in [telem.thegnar.info](https://telem.thegnar.info) (a
`project.name` OTEL attribute). Untagged usage lands there under *(untagged)* — run
`/toolkit:project-telem-tag` in the repo to fix it. Both states render and both
link to the dashboard; the untagged one takes the **bright** orange, which is
reserved for it and used nowhere else, precisely so it can still raise an alarm
against orange chrome.

## Requirements

- `git` and `jq` on `PATH`.
- **A terminal font with Unicode block elements and box drawing.** `▒ ░ ╭ ╮ ╰ ╯ ─ │
  ├ ┤` — CP437-heritage characters, present in essentially every terminal font for
  forty years, and single-width, so the column arithmetic stays deterministic.
  **This replaced the previous pure-ASCII output and there is no ASCII fallback.**
  A font that substitutes a double-width glyph for any of them will misalign the
  frame.
- Claude Code v2.1.153+ for `COLUMNS`-based sizing (older versions fall back to a
  fixed width).
- macOS system bash (3.2) or newer.

Colors honor [`NO_COLOR`](https://no-color.org) and degrade to a 256-color ramp on
terminals without truecolor (`COLORTERM`). Under `NO_COLOR` the frame, the labels
and every readout still render — only the hues distinguishing the three meters are
lost, and the labels already carry that.

## Install

### Via the Gnar plugin (recommended)

Install the `toolkit` plugin from the [`gnar` marketplace](https://github.com/TheGnarCo/agent-skills)
and run:

```
/gnar-statusline
```

The command fetches the latest release of these scripts, backs up any existing
statusline config, and wires `~/.claude/settings.json` for you.

### Manual

```sh
git clone https://github.com/TheGnarCo/claude-statusline ~/Code/claude-statusline
~/Code/claude-statusline/install.sh
```

`install.sh` symlinks both scripts into `~/.local/bin`, then add to
`~/.claude/settings.json`:

```json
{
  "statusLine":         { "type": "command", "command": "~/.local/bin/claude-statusline", "refreshInterval": 15 },
  "subagentStatusLine": { "type": "command", "command": "~/.local/bin/claude-subagent-statusline" }
}
```

`refreshInterval` is recommended: status lines are otherwise event-driven, so the
time-based cells (`5h0m`, `2d4h`) would freeze while the session sits idle. A 15s
timer keeps them live. Omit it to update only on events.

## Knobs

| Variable | Effect |
| --- | --- |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | Autocompact threshold, 1–100. Defaults to 80. Drives the CTX label's escalation. |
| `CLAUDE_STATUSLINE_CHROME_MARGIN` | Columns held back from the pane's right edge so the panel doesn't overrun Claude's own UI hints. Defaults to 8; `0` fills edge to edge. |
| `CLAUDE_STATUSLINE_HIDE_TELEM` | `1` hides the coverage tag (for anyone not sending OTEL telemetry, where it has nothing to say). Unset and `0` both mean show. |
| `CLAUDE_STATUSLINE_GIT_CACHE_TTL` | Seconds a gathered git state stays warm. Defaults to 3. `0` re-gathers every render. |
| `CLAUDE_STATUSLINE_NO_CACHE` | `1` disables caching entirely. |
| `CLAUDE_STATUSLINE_NO_UPDATE_CHECK` | `1` disables the daily Claude Code version check — the only thing here that touches the network. |
| `NO_COLOR` | Suppresses all ANSI. |

## The subagent statusline

`subagent-statusline.sh` is the second export of this repo and a peer of the main
statusline rather than an add-on. It drives Claude Code's **agent panel** — the
per-task rows shown for spawned subagents — and is wired separately, via
`subagentStatusLine`.

It reads the agent-panel JSON on stdin and writes **one JSON line per row** —
`{"id": "<task id>", "content": "<row body>"}` — in a single `jq` pass (no
per-task subshell, `awk` or `date` fork). `content` replaces the whole row body
and is rendered as-is, so it may carry ANSI.

Rows use the same marks as the main panel, so a subagent's context pressure reads
the way the session's does:

```
Explore  ▒▒░░░░░░░░ 42k  opus-5 high  2m05s
Review   ▒▒▒▒▒▒▒▒▒░ 900k              1h01m
Fresh    500 tokens                   30s
```

A failed task renders its name in red, since the custom body replaces the status
text the panel would otherwise show. A task whose `contextWindowSize` isn't known
yet gets a plain token count instead of a bar — a bar drawn against a guessed
denominator would be a lie. `contextWindowSize` and `model` need Claude Code
v2.1.205+, `effort` v2.1.214+; each cell is simply absent on older builds.

**Every failure path emits nothing at all**, rather than an empty `content`.
That distinction matters: an empty string *hides* a row, so a malformed payload
would blank the agent panel instead of leaving it on Claude Code's default
rendering.
## Caching

Claude Code re-runs the statusline on every event — several times a second during
an active turn — and the git calls are the only genuinely slow thing on the row.
A short-lived cache collapses those bursts: **~45% faster per render** in this
repo (99ms → 54ms measured over 20 renders).

It is keyed on the `session_id` Claude Code passes on stdin, which is stable for
the life of a session and unique across concurrent ones. Not the pid — that
changes on every invocation, so the cache would never hit and would be a slower
no-op. Without a `session_id` the cache is simply disabled.

The TTL is deliberately short (3s). The working tree is what the agent is actively
changing, so a long TTL would show you a stale working copy — the one thing this
row exists to report. Three seconds collapses an event burst and nothing more, and
any idle refresh still reads the tree.

Entries live under `${TMPDIR}/claude-statusline/` and hold their own timestamp in
the first line, because `stat` takes `-f` on BSD and `-c` on GNU. A cache hit never
refreshes that timestamp, so a busy session can't keep an entry alive indefinitely.
Corrupt, unreadable and unwritable caches all degrade to a live gather rather than
to a broken panel.

## Update check

`↑2.1.240` appears when the Claude Code you're running is behind the latest
published release. **This is the one cell that makes a network request** — nothing
else in this statusline leaves the machine — so it's worth being explicit about
what it does:

- It compares the `version` Claude Code passes on stdin against
  `registry.npmjs.org/@anthropic-ai/claude-code/latest`.
- It runs **at most once a day**, behind the same session-keyed cache as git
  state, and retries an hour after a failed check rather than staying silent for
  a full day over one dropped request.
- It **never blocks the render.** The fetch is detached with a 5-second hard
  timeout; this render draws whatever the cache already holds, which on a cold
  start is nothing. You'll see the chip on a later refresh, not this one.
- **Silence is the normal state.** The chip exists only when you're behind.

Set `CLAUDE_STATUSLINE_NO_UPDATE_CHECK=1` to turn it off entirely; no request is
made and no cache entry is written.

Versions compare component-wise rather than lexically — `2.1.9` is older than
`2.1.10`, which a string comparison gets backwards — and a non-numeric component
(a `-beta` suffix) reads as `0`, so a prerelease sorts as older than its release
rather than unpredictably.

## Notes

- The 5h/7d meters appear only once the session has made a request that populates
  the rate-limit fields.
- Apart from the cache above, the statusline writes nothing. Every cell renders
  from the JSON Claude Code passes on stdin, except the coverage tag, which also
  reads the repo's `.claude/settings.json` — and only when the attribute isn't
  already in the environment.

## Tests

`test/run.sh` renders the script against fixture payloads and diffs the
ANSI-stripped output against golden snapshots in `test/golden/`, plus colour-mode,
geometry, shed-order and exit-code assertions. Run `test/run.sh` to check,
`test/run.sh --update` to refresh the snapshots after an intentional change.

**The load-bearing assertion is geometry**: every emitted line must be exactly
`COLUMNS - CHROME_MARGIN` wide. A frame whose rules and content rows disagree by
one column is visibly broken, and that check is swept across widths and payloads
because the shed ladder, the space-between join and the three-way bar split each
round independently.

## Provenance

Seeded from [`alxjrvs/claude-statusline`](https://github.com/alxjrvs/claude-statusline)
at `7107dc5`, by its author.

The difference between the two repos is **ownership, not features**. That one is
one person's statusline, shaped to one person's taste. This one is **owned
collectively by The Gnar Company** — anyone here can change it, and it evolves by
whatever the team decides it should show.

So the two will diverge, but not from a spec written up front: they diverge because
different people steer them. Nothing is synced in either direction, and there is
deliberately no drift check between them. Cherry-pick by hand when a fix genuinely
suits both.

## License

[MIT](./LICENSE) © The Gnar Company, Inc.
