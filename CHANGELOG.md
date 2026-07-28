# Changelog

What each **tag** ships. Tags are the only thing that reaches anyone: `/gnar-statusline`
installs a pinned tag and `install.sh` symlinks a clone, so a merge to `main` changes
nothing for users until a tag is cut and the agent-skills pin moves.

## v1.1.0

Line 1 is restructured: **one bracket per concept** instead of one per field, a new
telemetry-coverage chip, and a defined order for what a narrow pane gives up.
`subagent-statusline.sh` and `install.sh` are unchanged, and there are no new dependencies.

### Line 1 groups by concept

Both lines below are real output from the two versions against the *same* repo state
(2 ahead, 1 behind, 2 modified, 3 staged, 1 untracked) and the same payload:

```
v1.0.0  claude-statusline [reviewer][@main/wt][?1 !2 +3 ^2 v1][+42/-7][Opus 5 1M XHi Explanatory][N][$1.23 ($7.38/h)]
v1.1.0  claude-statusline [@main/wt ^2 v1 !2 +3 ?1][reviewer +42/-7 $1.23 ($7.38/h)][Opus 5 1M XHi N Explanatory][no telem tag]
```

| bracket | holds |
| --- | --- |
| **git** | branch (linked), worktree, working-tree counters |
| **session** | agent/session name, churn, cost + per-hour burn |
| **config** | model, context-window flag, effort, vim mode, output style |
| **telemetry** | whether this repo's usage is attributed — see below |

Reading "what is the git state here?" is now one stop instead of reassembling a bracket run.

### New: telemetry-coverage chip, and an `owner/name` title

- **`[telem tag]` / `[no telem tag]`** — whether this repo's Claude Code usage is attributed
  to a project in [telem.thegnar.info](https://telem.thegnar.info) via a `project.name` OTEL
  attribute. Green when it is; yellow when it isn't and the usage lands under *(untagged)*.
  Only inside a git repo, and it sits last so it is the first cell to spill onto a
  continuation line. Hide it with `CLAUDE_STATUSLINE_HIDE_TELEM=1`.
- **The title is now the repo as `owner/name`** (linked, owner muted so the name stays the
  anchor), or the cwd's last two components outside a repo.
- This is the one cell that reads anything off disk — the repo's `.claude/settings.json`,
  and only when the attribute isn't already in the environment. Every other cell still comes
  purely from the JSON on stdin.

### Two cells moved

- **Counter sigils are ordered by urgency**, not by index-then-upstream:
  `x`conflict `^`ahead `v`behind `!`modified `+`staged `?`untracked `*`stash.
  Previously `*`stash came first and `^`/`v` last.
- **Vim mode now precedes the output style.**

Both orders are load-bearing rather than cosmetic: display order *is* the order a
too-narrow pane gives cells up, and a conflict or unpushed commits matter more than a stash
count, as a live editing mode does more than a style set once.

### Narrow panes degrade in a defined order

A bracket can't be split across lines, so an over-wide one sheds its lowest-priority cells
and marks the elision with `..` rather than overrunning the pane:

- **Names yield before counters.** The branch shrinks, then the `/worktree` suffix is
  dropped, before any counter is shed — a missing `^2` reads as "in sync with upstream"
  when you are not, while a shortened branch reads as exactly what it is. All seven
  counters are asserted to survive to `COLUMNS` 40, and in practice reach 36 with
  single-digit counts (the exact width depends on how many digits they carry).
- **The cost drops its `($/h)` burn rate before the total**, the half you can't
  reconstruct from the other.
- **Churn abbreviates rather than truncating digits**: `+123456/-654321` → `+123k/-654k`,
  because `+12..56` reads as a real number.
- Every cell that can *lead* its bracket carries its own width cap, since the first cell is
  never shed.

### Known limitations

Both are stated rather than silently present:

- The `/worktree` suffix flickers off for **exactly one column** every 15, where the branch
  and worktree width budgets (`cols/3` and `cols/5`) step together. Periods 3 and 5 collide
  every 15 columns whatever the budgets are, and the alternatives move the artifact onto
  branch length — the more informative cell. Bounded by test: never more than one
  consecutive column, never permanently.
- Below roughly `COLUMNS` 24, line 1 cannot be held inside the pane: a single indivisible
  cell is wider than the whole budget. That is the same regime where the context bar's
  minimum readable width already overruns, so the pane is over-full regardless.

### Also

- MIT license, and the README/CLAUDE.md framing of this repo as collectively owned rather
  than a fork of `alxjrvs/claude-statusline` (#1).
- Claude Code telemetry from this repo is tagged with `project.name` (#4) — repo-internal,
  nothing shipped.
- CLAUDE.md's claim that the plugin command's prose is coupled to this layout, corrected
  (#9) — it has been install-only since agent-skills `#422`/`#424`, so a layout change needs
  the pin moved and nothing rewritten. Repo-internal, nothing shipped.
- Test suite grew from 19 assertions to 58, including an all-seven-counter git fixture
  (real upstream for ahead/behind, stashes, a conflicted merge) covering the shed logic.

**Scope:** `#1`, `#4`, `#5`, `#7`, `#8`, `#9` — every commit on `main` since `v1.0.0`. Among
shipped files only `statusline.sh` changed; `subagent-statusline.sh` and `install.sh` are
byte-identical to `v1.0.0`. `#6` (Fable 5 weekly cap) is still draft and is not in this
release.

**Full diff:** [`v1.0.0...v1.1.0`](https://github.com/TheGnarCo/claude-statusline/compare/v1.0.0...v1.1.0)

## v1.0.0

First tagged release: the two scripts extracted into their own repo, seeded from
[`alxjrvs/claude-statusline`](https://github.com/alxjrvs/claude-statusline) at `7107dc5`.

- `statusline.sh` — 2–4 lines: identity/config row, a context-window bar with an
  autocompact marker, and the 5h/7d rate-limit windows. Pure ASCII, `NO_COLOR`-aware,
  256-color fallback.
- `subagent-statusline.sh` — the agent panel's per-task rows, one `jq` pass.
- `install.sh` — symlinks both into `~/.local/bin`.

---

## Cutting a release

A tag is the delivery, so the notes above are reviewed *before* the tag exists rather than
written after it is immutable.

1. Land everything intended for the release on `main`.
2. Add its section here in a PR, and merge that PR — it is the last commit in the release.
3. Cut an **annotated** tag at that commit (`v1.0.0` is annotated; keep them consistent)
   and publish a GitHub release pointing at this file's section.
4. Move `STATUSLINE_VERSION` in agent-skills' `toolkit/commands/gnar-statusline.md`. Until
   that pin moves, no plugin user sees any of it.

Step 4 is a separate repo and a separate review. Cutting the tag before that pin moves is
fine; moving the pin before the tag exists is not — the command's `curl` 404s and it
refuses to write a partial install.
