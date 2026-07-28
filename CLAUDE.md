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
- **The plugin's command is install-only and does NOT describe this layout.** It fetches the
  pinned scripts, wires both keys, verifies, and links this repo for what they render — it
  says outright "Don't restate its contents here or narrate the segments to the user". There
  is no Customize mode and no segment inventory: agent-skills `#422`/`#424` removed both, and
  its changelog links a `v1.0.0...v1.1.0` compare rather than re-listing cells. So a layout
  change here needs the **pin moved and nothing rewritten** on that side.

  This entry used to claim the opposite, and that stale claim got repeated as outstanding
  debt across several PRs here before anyone checked. Check rather than trust it:

  ```sh
  gh api repos/TheGnarCo/agent-skills/contents/toolkit/commands/gnar-statusline.md \
    --jq .content | base64 -d | grep -niE 'customize|counters group|vim-mode chip|model group'
  ```

  If that returns nothing, the command is layout-agnostic and only the pin matters.

  This is about the command's *prose* only. There is a real behavioural coupling to
  agent-skills — the telem-tag chip has to agree with that plugin's detection hook — and it
  has its own entry below. Don't read this bullet as "nothing on that side ever needs
  touching".

## Relationship to alxjrvs/claude-statusline

Seeded from [`alxjrvs/claude-statusline`](https://github.com/alxjrvs/claude-statusline)
at `7107dc5`. It is **not** a fork, and the distinction that matters is **ownership, not
features**: that repo is one person's statusline, this one is owned collectively by The
Gnar Company and evolves by whatever the team decides it should show.

Practical consequences:

- **Don't treat the personal repo as upstream.** No sync tooling, no drift checks, and a
  change there does not imply a change here. Cherry-pick by hand when a fix suits both.
- **Don't defend the current layout as canonical.** It is the seed, not a spec. Anyone at
  Gnar can propose changing what it shows; "that's how the original did it" is not a
  reason to keep something.

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
  cancels the real clock), a fixed `COLUMNS` per case, and an empty
  `OTEL_RESOURCE_ATTRIBUTES` (so the telem-tag chip answers to the fixture, not to
  whether the session running the suite is itself tagged — this repo is, CI isn't, and
  that would flip all three git goldens). Don't introduce wall-clock, `$HOME`-relative, or
  ambient-env output without pinning it in `run.sh`.
- **Autocompact marker defaults to 80%.** The amber threshold cell / `N%->AC` headroom /
  `[AC]` chip assume autocompact fires at 80% of the context window. Override the marker
  with `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (1–100) if a session's real threshold differs, or
  it will point at the wrong cell.
- **The telem-tag chip duplicates the toolkit hook's detection on purpose.** It answers
  the same question as `toolkit/scripts/hooks/project-telem-tag-check.sh` in agent-skills
  (does this repo carry a `project.name=` OTEL attribute — live env, then
  `.claude/settings.json`, then `.claude/settings.local.json`?), and the two must agree, or
  the statusline nags about a repo the hook considers tagged. There's no shared code to
  reach for — this repo ships two standalone scripts and can't depend on the plugin — so if
  that hook's rule changes, port the change into `statusline.sh` by hand. One deliberate
  refinement: where the hook takes the *first* file carrying the attribute, the chip lets a
  later file that defines it win, matching Claude Code's own `settings.local.json`-over-
  `settings.json` env merge. That can't produce a disagreement in practice — whenever any
  settings file defines the attribute, Claude Code exports the merged value and the env
  branch answers before either file is read.
- **The chip is the one cell that touches the filesystem.** Everything else renders from
  stdin. It stays cheap because a tagged repo answers from `$OTEL_RESOURCE_ATTRIBUTES`
  (Claude Code exports it) and an untagged one usually has no settings file to read, so the
  `jq` fork only happens for a repo with settings but no tag. Keep it that way — this runs
  on every refresh.
- **The title's owner comes from two sources that must agree.** Claude Code's structured
  `workspace.repo` payload when present, else parsing the `origin` URL. That parse takes the
  path segment immediately *before* the repo, not the first one — paths deeper than
  `<owner>/<repo>` are normal (GitLab subgroups, Bitbucket's `/scm/<project>/<repo>`) and
  taking the first segment rendered `scm/myrepo`. With nothing before the repo (a top-level
  or non-GitHub-SSH remote) there's no owner and the title degrades to the bare name rather
  than labelling something else as one. Both sources and the deep-path shapes are covered in
  `run.sh` — change one and check the other.
- **Bash 3.2 only.** No associative arrays, no `${var^^}`, no `mapfile`. The scripts use
  parallel indexed arrays and `tr` for case-folding on purpose — keep new code 3.2-safe so
  it runs on macOS system bash.
- **A statusline must never fail.** `statusline.sh` ends with `exit 0`, and missing JSON
  fields degrade to a dropped segment rather than an error. Preserve that: a non-zero exit
  or stderr noise leaks into Claude Code's UI.
- **`COLUMNS` chrome margin.** Bars fill the pane minus `CHROME_MARGIN` (default 8) so they
  don't overrun Claude's own UI hints and force a wrap. Tune with
  `CLAUDE_STATUSLINE_CHROME_MARGIN`.
