# CLAUDE.md

This file guides Claude Code (claude.ai/code) when working in this repository.

## What This Is

The Gnar Company's **Claude Code statusline**, shipped as two standalone bash scripts —
no Rust, no build step, no extra binaries beyond `git` and `jq`. Targets macOS system
bash (3.2) so it's a portable drop-in.

- **`statusline.sh`** — the main statusline. Reads Claude Code's statusline JSON on
  stdin and emits 2–4 colored lines (identity/config row, a context-window bar, and the
  5h/7d rate-limit windows). Pure ASCII pips (`#`/`-`/`|`/`*`), so no Nerd Font is
  required; colors honor `NO_COLOR` and degrade to a 256-color ramp off truecolor.
- **`subagent-statusline.sh`** — the agent-panel status line. Reads subagent JSON on
  stdin and emits `{"tasks":[...]}` in a single `jq` pass.
- **`install.sh`** — symlinks both scripts into `~/.local/bin` as `claude-statusline`
  and `claude-subagent-statusline`.

The `README.md` is the user-facing reference for what each cell means.

## How it's consumed

Two paths, and **both install a copy** — nothing here is read live from a checkout:

1. **The Gnar plugin.** [`TheGnarCo/agent-skills`](https://github.com/TheGnarCo/agent-skills)
   ships a `/gnar-statusline` command in its `toolkit` plugin. It fetches a **pinned tag**
   of this repo and copies the scripts into `~/.claude/`. Users are never on `main`.
2. **`install.sh`**, for people who don't run the plugin — symlinks a local clone into
   `~/.local/bin`.

Practical consequences:

- **Tag releases deliberately.** A merge to `main` reaches nobody until someone bumps the
  pin in agent-skills. That is the intended review gate — don't try to make the plugin
  track `main`.
- **The plugin's command prose is coupled to this layout.** `/gnar-statusline`'s Customize
  mode names specific lines and specific blocks in `statusline.sh`. If you add, remove, or
  reorder an emitted line, the corresponding agent-skills PR has to rewrite that command,
  not just move the pin. Say so in the PR description here.

## Relationship to alxjrvs/claude-statusline

Seeded from [`alxjrvs/claude-statusline`](https://github.com/alxjrvs/claude-statusline)
at `7107dc5`. It is **not** a fork: that repo is a personal statusline, this one is a Gnar
product, and they are expected to diverge. Do not add sync tooling or drift checks between
them, and don't assume a change there belongs here. Cherry-pick by hand when a fix
genuinely suits both.

## Test / lint locally

```sh
bash test/run.sh              # snapshot suite: render vs. test/golden/, + color/exit/width asserts
bash test/run.sh --update     # regenerate golden snapshots after an INTENTIONAL output change
shellcheck -x *.sh test/run.sh
shfmt -d -i 2 -ci -sr *.sh test/run.sh   # -d = diff (dry-run); -w to apply
```

`test/run.sh` renders `statusline.sh` against fixture payloads in a throwaway non-git
(and one git) temp dir and diffs the ANSI-stripped output against `test/golden/*.txt`. It
also asserts color-mode behavior (ANSI on by default, none under `NO_COLOR`, indexed ramp
off truecolor), that the script always exits 0, and that no rendered line exceeds
`COLUMNS`. CI (`.github/workflows/ci.yml`) runs the same shellcheck + shfmt + `test/run.sh`
on every push/PR via mise.

Run `shfmt -w -i 2 -ci -sr` before committing — those flags are the canonical format here.

## Gotchas

- **Golden snapshots are ANSI-stripped.** They catch layout/content regressions, not
  color. After an intentional change to the rendered text, run `test/run.sh --update` and
  review the diff before committing. Color behavior is covered by separate presence/absence
  assertions in `run.sh`, not the goldens.
- **Determinism in tests** depends on pinned env: `HOME` off-tree (so `~` abbreviation is
  stable), a far-future `resets_at` sentinel (so "time left" pins to the full window and
  cancels the real clock), and a fixed `COLUMNS` per case. Don't introduce wall-clock or
  `$HOME`-relative output without pinning it in `run.sh`.
- **Autocompact marker defaults to 80%.** The amber threshold cell / `N%->AC` headroom /
  `[AC]` chip assume autocompact fires at 80% of the context window. Override the marker
  with `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (1–100) if a session's real threshold differs, or
  it will point at the wrong cell.
- **Bash 3.2 only.** No associative arrays, no `${var^^}`, no `mapfile`. The scripts use
  parallel indexed arrays and `tr` for case-folding on purpose — keep new code 3.2-safe so
  it runs on macOS system bash.
- **A statusline must never fail.** `statusline.sh` ends with `exit 0`, and missing JSON
  fields degrade to a dropped segment rather than an error. Preserve that: a non-zero exit
  or stderr noise leaks into Claude Code's UI.
- **`COLUMNS` chrome margin.** Bars fill the pane minus `CHROME_MARGIN` (default 8) so they
  don't overrun Claude's own UI hints and force a wrap. Tune with
  `CLAUDE_STATUSLINE_CHROME_MARGIN`.
