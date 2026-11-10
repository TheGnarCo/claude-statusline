# CLAUDE.md

This file guides Claude Code (claude.ai/code) when working in this repository.

## What This Is

The Gnar Company's **Claude Code statusline**, shipped as two standalone bash scripts —
no Rust, no build step, no extra binaries beyond `git` and `jq`. Targets macOS system
bash (3.2) so it's a portable drop-in.

- **`statusline.sh`** — the main statusline. Reads Claude Code's statusline JSON on
  stdin and emits a **five-line framed panel**: a top rule carrying the repo (and an
  update chip when a newer release exists), a text row (git / config / spend), a `USAGE` rule, a
  meter row (CTX / 5h / 7d), and a bottom rule. Frame and separators are burnt Gnar
  orange. **Unicode block elements and box drawing, with no ASCII fallback** — see
  the gotcha below, because this repo used to sell pure ASCII as a feature.
- **`subagent-statusline.sh`** — the agent-panel status line. Reads the panel JSON
  on stdin and writes **one JSON line per row**, `{"id": ..., "content": ...}`, in a
  single `jq` pass. `content` replaces the whole row body and may carry ANSI. It
  emitted a `{"tasks":[...]}` envelope until v2.0.0, which Claude Code silently
  rejected — see the gotcha below, because that failure mode is invisible.
- **`install.sh`** — symlinks both scripts into `~/.local/bin` as `claude-statusline`
  and `claude-subagent-statusline`.

The `README.md` is the user-facing reference for what each cell means.

## How it's consumed

Two paths, and **both install a copy**. Nothing here is read live from a checkout:

1. **The README's [Install](./README.md#install) steps.** People point Claude Code at this repo
   and ask it to install the statusline. The agent follows those steps: it resolves the
   **latest GitHub release** (the `releases/latest` redirect), copies both scripts into
   `~/.claude/`, wires `statusLine` and `subagentStatusLine`, and verifies. Users are never on
   `main`, and no version is pinned anywhere. This replaced the `/gnar-statusline` command
   that agent-skills' `toolkit` plugin used to ship, which retired with toolkit. **The README
   is now the installer**, so treat its Install section as code: a change to the file names,
   the settings keys or the subagent output contract must update those steps in the same PR.
2. **`install.sh`**, for working on the scripts: it symlinks a local clone into
   `~/.local/bin`.

Practical consequences:

- **Publishing a release IS the delivery, and there is no second gate.** A merge to `main`
  reaches nobody. Publishing a GitHub release reaches everyone the next time they install,
  with nothing to bump anywhere else. The release is the whole review gate, so cut one
  deliberately, and don't point the install steps at `main`. A **draft** release delivers
  nothing: the `releases/latest` redirect skips drafts.
- **The install steps don't describe the layout.** They install, verify and link the README
  for what the panel shows, so a layout change needs no edit to them. The verify step does
  depend on the subagent script's output (`{"id","content"}` per task), so a change to that
  contract does.

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
bash test/subagent.sh         # agent-panel contract: {id, content} per line, degradation, colour
shellcheck -x *.sh test/run.sh
shfmt -d -i 2 -ci -sr *.sh test/run.sh   # -d = diff (dry-run); -w to apply
```

`test/run.sh` renders `statusline.sh` against fixture payloads in a throwaway non-git
(and one git) temp dir and diffs the ANSI-stripped output against `test/golden/*.txt`. It
also asserts color-mode behavior (ANSI on by default, none under `NO_COLOR`, indexed ramp
off truecolor), that the script always exits 0, and that every rendered line is
**exactly** `COLUMNS - CHROME_MARGIN` wide — not merely under it. `test/subagent.sh`
covers the agent panel separately. CI (`.github/workflows/ci.yml`) runs the same shellcheck + shfmt + `test/run.sh`
+ `test/subagent.sh` on every push/PR via mise.

Run `shfmt -w -i 2 -ci -sr` before committing — those flags are the canonical format here.

## Gotchas

- **Golden snapshots are ANSI-stripped.** They catch layout/content regressions, not
  color. After an intentional change to the rendered text, run `test/run.sh --update` and
  review the diff before committing. Color behavior is covered by separate presence/absence
  assertions in `run.sh`, not the goldens.
- **Determinism in tests** depends on pinned env: `HOME` off-tree (so `~` abbreviation is
  stable), a far-future `resets_at` sentinel (so "time left" pins to the full window and
  cancels the real clock), and a fixed `COLUMNS` per case. Don't introduce wall-clock, `$HOME`-relative, or
  ambient-env output without pinning it in `run.sh`.
- **Unicode is a hard dependency now, and that is a reversal.** The bars are `▒`
  over `░` and the frame is box drawing. Both README and this file used to promise
  "pure ASCII, no Nerd Font required"; that promise is gone, deliberately, and there
  is **no `CLAUDE_STATUSLINE_ASCII` escape hatch** — it was considered and declined.
  These are CP437-heritage single-width characters, so the column arithmetic stays
  deterministic, but a font substituting a double-width glyph will misalign the
  frame. If that ever bites, the fix is a fallback, not a layout change.
- **Geometry is THE invariant: every line is exactly `COLUMNS - CHROME_MARGIN`.**
  A frame whose rules and content rows disagree by one column is visibly broken, so
  `test/run.sh` sweeps widths x payloads asserting it. Three things round
  independently — the row-1 shed ladder, the space-between join, and the three-way
  bar split — so an off-by-one shows only at particular widths. **Never spot-check
  a width; run the sweep.**
- **Visible width is not byte length.** The output is multibyte, so `${#var}` in bash
  and `length` in awk both count bytes. The suite's `vislen` deletes UTF-8
  continuation bytes and then counts, which is locale-independent — `wc -m` and awk's
  `length` would each need a UTF-8 locale, and CI and macOS do not ship the same
  ones. In the script itself every display string carries a **plain twin** whose
  length is the measurement; never measure a string holding ANSI or OSC8.
- **One texture, three hues — and the labels are what disambiguate.** All three
  meters render the same shade over the same track; they are told apart by the label
  in front of each and by colour. That reverses the old per-row glyph tiers on
  purpose: those existed because bars stacked on separate rows had no adjacent label.
  Side by side they do. Under `NO_COLOR` the hues vanish and the labels carry it
  alone — which is why a meter must never render without its label.
- **A meter is never dropped to save room.** A missing meter reads as "no data",
  which is a different and wrong statement from "narrow pane". The bars shrink, the
  tails shed, the meters stay.
- **The CTX label is the autocompact indicator**, escalating green to amber to bold
  red (default threshold 80%, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`). With percentages
  dropped there is no number left to escalate and a flat bar has no boundary to mark,
  so the warning lives on the label. Asserted on escape codes, since the whole point
  is colour.
- **Percentages are deliberately absent except above `WINDOW_LOUD_PCT` (70).** The
  bar is the proportion. A window shows its number only near the limit, where a bar
  cannot separate 73% from 78%. Don't "restore" percentages without moving that
  constant — the omission is the design.
- **Shed cheapest-loss-first, and never key a shed on punctuation.** The row-1 ladder
  has **seven** rungs, and `build_row1` gates them by `lvl`: 1 the derived burn, 2 the
  output style, 3 churn *and* a worktree suffix not already inside the branch (one
  rung, not two), 4 the working-tree sigils, 5 spend, 6 the config group — and only
  then, at `lvl >= 5`, the branch is trimmed by **exactly the overflow**, floored at
  `_BRANCH_FLOOR` (6). Read the gates rather than this list if they disagree; this
  list has been wrong before. A previous implementation detected the burn rate by
  matching a literal `" ("`; dropping the parens made it silently stop matching and
  shed the whole cost member, taking the total with it. **Detect the burn by its
  unit (`/h`).**
- **There is no telemetry chip, on purpose.** Up to v2.0.1 the top rule said `tagged` /
  `untagged` for a `project.name` OTEL attribute, mirroring a hook agent-skills' toolkit
  plugin used to ship. Claude Code now attributes usage per repo natively
  (`OTEL_METRICS_INCLUDE_REPOSITORY=1`, set org-wide in managed settings), so the chip
  would read `untagged` on every correctly attributed repo. It and
  `CLAUDE_STATUSLINE_HIDE_TELEM` are gone, and with them the only cell that read the
  repo's settings files. Don't bring back a coverage check that reimplements what Claude
  Code already does.
- **The title's owner comes from two sources that must agree.** Claude Code's structured
  `workspace.repo` payload when present, else parsing the `origin` URL. That parse takes the
  path segment immediately *before* the repo, not the first one — paths deeper than
  `<owner>/<repo>` are normal (GitLab subgroups, Bitbucket's `/scm/<project>/<repo>`) and
  taking the first segment rendered `scm/myrepo`. With nothing before the repo (a top-level
  or non-GitHub-SSH remote) there's no owner and the title degrades to the bare name rather
  than labelling something else as one. Both sources and the deep-path shapes are covered in
  `run.sh` — change one and check the other.
- **Cutting a release means bumping `STATUSLINE_VERSION` in `statusline.sh`.** It
  feeds the self-update chip, and plugin users receive a *copy* with no git
  metadata, so it cannot be derived at runtime. `test/run.sh` asserts it equals the
  newest `## vX.Y.Z` heading in `CHANGELOG.md` — so forgetting it fails CI instead
  of shipping a statusline that tells every user it is current forever. Bump the
  constant and the CHANGELOG in the same commit as the tag.
- **A broken agent panel is INVISIBLE.** Claude Code validates each line of
  `subagent-statusline.sh`'s stdout against `{id: string, content: string}`, logs
  `subagentStatusLine emitted invalid schema` — only under `claude --debug` — and
  falls back to the default row. The script was a silent no-op from whenever the
  contract changed until v2.0.0 and nothing surfaced it. Two consequences: run
  `test/subagent.sh` after touching it, and remember that an **empty `content`
  hides a row**, so every failure path must emit *nothing* rather than an empty
  string.
- **The README's example panel is `test/golden/panel-full.txt` verbatim.** It was
  hand-drawn once and drifted four columns from real output. Regenerate with
  `test/run.sh --update` and paste, or leave it alone.
- **Bash 3.2 only.** No associative arrays, no `${var^^}`, no `mapfile`. The scripts use
  parallel indexed arrays and `tr` for case-folding on purpose — keep new code 3.2-safe so
  it runs on macOS system bash. C-style `for ((...))` is fine; `rep()` builds repeated
  glyphs with one because bash has no string multiplication and `printf %*s` pads with
  spaces only.
- **A statusline must never fail.** `statusline.sh` ends with `exit 0`, and missing JSON
  fields degrade to a dropped segment rather than an error. Preserve that: a non-zero exit
  or stderr noise leaks into Claude Code's UI.
- **`COLUMNS` chrome margin.** The panel fills the pane minus `CHROME_MARGIN` (default 8)
  so it doesn't overrun Claude's own UI hints and force a wrap — which for a frame means
  the box visibly breaks, not just an ugly line. Tune with
  `CLAUDE_STATUSLINE_CHROME_MARGIN`.
