# Changelog

What each **tag** ships. Tags are the only thing that reaches anyone: `/gnar-statusline`
installs the latest **published release** and `install.sh` symlinks a clone, so a merge to
`main` changes nothing for users — and publishing a release changes it for all of them, on
their next install, with nothing to bump anywhere else.

## v2.0.0

**Breaking.** The statusline is now a framed panel, and it needs a font with Unicode block
elements and box drawing. There is no ASCII fallback.

```
v1.2.0  CTX ~~~~~~~~~~~~~~~~................|.......  42% 84k/200k 38%->AC
        5h  |############################-----------  73% 5h 0m left [+73%]
        7d  |:::::::::::::::::::::::________________  60% 7d 0h left [+60%]

v2.0.0  ╭─ TheGnarCo/claude-statusline ──────────────────────── tagged ╮
        │ @main ?2 +120/-45    │    Opus 4.8 Hi    │    $1.23  $7.38/h │
        ├─ USAGE ──────────────────────────────────────────────────────┤
        │ CTX ▒▒░░░░░ 84k/200k │ 5h ▒▒▒▒▒░░ 73% 5h0m │ 7d ▒▒▒▒░░░ 7d0h │
        ╰──────────────────────────────────────────────────────────────╯
```

Two rows of content instead of three or four bars. **Row 1 is what this session is** — repo,
branch, working tree, model, spend. **Row 2 is what it is spending** — context and both
rate-limit windows, side by side. The top rule carries what is true of the whole panel: the
repo, and whether its usage is attributed in telemetry.

### Why a frame

Three bars stacked down the left edge read as three separate readouts that happened to be
adjacent. A frame says they are one object, and it earns its lines: the top rule carries the
repo name, which hands 28 columns back to the text row, and the `USAGE` rule labels the split
between what the session *is* and what it is *costing*. Vertical rules in burnt Gnar orange
divide the groups, so brackets are gone — spacing and colour do that work now.

### Why the marks changed, and what it costs

Every meter is one texture: `▒` spent over `░` untouched. The meters are told apart by the
label immediately in front of each and by colour, not by glyph.

That **reverses v1.2.0 deliberately.** Per-row glyph tiers existed because bars stacked on
separate rows had no adjacent label to disambiguate them — you located a row by recognising
its texture. Side by side, each bar has its own label an inch to its left, so shape has
nothing left to disambiguate and the three can share one.

The cost is real and worth stating plainly: **this drops the pure-ASCII promise**, which
every version through v1.2.0 sold as a feature. These are CP437-heritage single-width
characters, present in essentially every terminal font for forty years, so the column
arithmetic stays deterministic — but a font that substitutes a double-width glyph will
misalign the frame. An opt-in ASCII mode was considered and declined; if it is ever needed,
it is a fallback to add, not a layout to change.

### What is gone

Clock pips, the burn projection, pace deltas, per-row gradients, the `[AC]` and `[200k+]`
chips, the prompt-cache ratio, the redundant `1M` flag, and bracket groups. The row states
**magnitude, not pace**.

Percentages are gone too, except where a bar cannot substitute. `CTX` shows `84k/200k`, which
is the same fact stated more precisely. A window shows its percentage **only at 70% or above**
— a bar cannot separate 73% from 78%, and that only matters near the limit, so the number
costs its columns in the state that wants them and no other.

The autocompact threshold moved onto the **`CTX` label**, which escalates green → amber → bold
red as it closes. With the percentage gone there was no number left to escalate, and a
single-texture bar has no boundary to mark.

### Faster, and it now knows about updates

Git state is cached per session (`session_id`, 3s TTL), which is **~45% faster per render** —
99ms to 54ms measured over 20 renders. Claude Code re-runs the statusline on every event,
several times a second during an active turn, and the git calls were the only genuinely slow
thing on the row. The TTL is short on purpose: the working tree is what the agent is actively
changing, so a long one would show a stale working copy.

An `↑2.1.240` chip appears when the running Claude Code is behind the latest release. It is
checked at most once a day, detached with a 5-second timeout, and **never blocks a render** —
the first thing in this statusline that touches the network, so it is opt-out via
`CLAUDE_STATUSLINE_NO_UPDATE_CHECK=1` and documented rather than buried.

Three fields that were always on stdin now render: `Fast` when fast mode is on, `NoThink` when
extended thinking is explicitly off, and `api N%` — the share of the session spent blocked on
the API. All three are silent in their normal state.

### The agent panel was broken and nobody could tell

`subagent-statusline.sh` had been a **silent no-op**. It emitted a `{"tasks":[...]}` envelope;
Claude Code validates each stdout line against `{id, content}`, logs a schema error visible
only under `claude --debug`, and falls back to the default row. It has been rewritten to the
current contract and now renders each task in the panel's own marks:

```
Explore  ▒▒░░░░░░░░ 42k  opus-5 high  2m05s
Review   ▒▒▒▒▒▒▒▒▒░ 900k              1h01m
```

It also resolves colour the way the main panel does. Previously it ignored `NO_COLOR` entirely
and drew a 256-colour purple where the main panel drew a truecolor one — the same meter in two
shades.

### Upgrading

Nothing to configure. `install.sh` and the `/gnar-statusline` command are unchanged, and there
are no new dependencies — still just `git` and `jq`. If your terminal font renders `▒ ░ ╭ ─ │`
at single width, which is nearly all of them, the panel will line up.

## v1.2.0

Each bar row now has its own vocabulary. `CTX` is a `~` wave on dots over a purple gradient,
`7d` is a `:` dotted band on underscores over a blue one, and `5h` keeps `#` on `-` over the
warm blackbody ramp it always had. You can tell which row you're reading from its texture
alone. `subagent-statusline.sh` and `install.sh` are unchanged, and there are no new
dependencies.

```
v1.1.3  CTX ################----------------|-------  42% 84k/200k 38%->AC
        5h  |############################-----------  73% 5h 0m left [+73%]
        7d  |#######################----------------  60% 7d 0h left [+60%]

v1.2.0  CTX ~~~~~~~~~~~~~~~~................|.......  42% 84k/200k 38%->AC
        5h  |############################-----------  73% 5h 0m left [+73%]
        7d  |:::::::::::::::::::::::________________  60% 7d 0h left [+60%]
```

### Why

Three bars in one vocabulary read as one block. You located a row by counting down from the
top rather than recognising it, which is slowest at exactly the moment it matters — glancing
mid-task to see whether it's the context window or the week that's nearly gone.

Both halves of a bar carry the row's identity, because **fill and track fail at opposite
ends of the range.** A fill-only scheme says nothing on a nearly empty bar: at 2% the clock
pip lands on the single filled cell and overwrites it, so a window row shows no fill glyph
at all. A track-only scheme says nothing on a full one. Pairing them keeps every row legible
at every level, with fill always the denser half so the fill/track contrast that makes a bar
readable survives inside each row.

Glyphs come from what nothing else claims: `# - | * !` are spoken for inside the bar and
`+ ^ v ? x @` on line 1.

### Color, and why it isn't the mechanism

Each row also gets its own gradient family, and all three run the same arc — a **shared grey
at empty**, up through the row's own hue, out to a **white tinted toward that hue** at full.
So the bars read as one system, and a nearly empty bar is grey on every row. That last part
is the point: at low fill hue distinguishes nothing, and under `NO_COLOR` it contributes
nothing at all. Hue sharpens the glyph distinction; it never carries it.

The clock pips changed with the ramps. A pip *replaces* its cell, so it is ink on the
terminal background — what makes it findable is contrast with that background plus
perceptual distance from the fill ink beside it. Picked that way the three rows disagree, and
have to: amber reads against purple, blue against warm, and **7d's pip is pink**, because
against a blue ramp both a blue pip (collides with the ramp's peak) and a near-white one
(collides with its tinted-white terminus) measure ΔE ≈ 6 — present but invisible. Pink
measures ΔE ≈ 73. The pip's *shape* still carries the meaning; its color is chosen purely so
you can find it.

Non-truecolor terminals get three distinct 256-color ramps rather than one, or the tiers
would not exist for those users at all. All three open on index 59 (`#5f5f5f`) so the shared
grey origin holds off truecolor too — `warm` used to open on 60 (`#5f5f87`, blue-violet),
which made an empty 5h bar blue where the others were grey. The two new families also ascend
monotonically in luminance, so the fill reads as a level instead of dipping darker partway
along. `warm` still dips at 96 and 202; those dips predate this change and flattening them
would re-color the 5h row on every non-truecolor terminal, so that stays a separate decision.

One thing deliberately *not* recolored: the `time left` readout stays blue on both window
rows. `MARKER_7D` is pink because pink survives against 7d's blue bar fill, but that
constraint doesn't apply to text sitting on the terminal background — there it would land
pink immediately beside the red/green `[+N%]` delta and blunt the delta's own coding.

`run.sh` grew assertions for the glyph pairs, the glyphs surviving `NO_COLOR`, the shared
grey origin in both color depths, each row's hue family, the pip/ramp collision, three
distinct indexed ramps, and ramp luminance monotonicity — the goldens are ANSI-stripped, so
they catch the glyphs and are blind to every hue.

## v1.1.3

The name cell is gone. v1.1.2 dropped only the *generic* agent name; this drops the slot
itself — a deliberately-named agent, and your `session_name` behind it, no longer render.
Nothing else moves: `subagent-statusline.sh` and `install.sh` are unchanged, and there are
no new dependencies.

```
v1.1.2  TheGnarCo/claude-statusline [@worktree-drop-agent-name !5 +163/-34][reviewer Opus 5 1M Hi $1.23 ($7.38/h)][telem tag]
v1.1.3  TheGnarCo/claude-statusline [@worktree-drop-agent-name !5 +163/-34][Opus 5 1M Hi $1.23 ($7.38/h)][telem tag]
```

### Why

The cell was justified by "which of my many concurrent tabs is this?", and it answered that
badly. Every background or spawned agent that never picked a type reports the name `claude`
— which names nothing and cannot tell two concurrent agents apart — so on the panes where
the question is actually asked, the slot was either empty or a non-answer. The named case
that did earn it (`--agent reviewer`) is rare enough that the column was mostly spent on
nothing, and the pane already carries two identifiers that are always right: the title's
`owner/name` and the branch.

So the config group now opens on the model, `session_name` is no longer read from the
payload at all, and a session that set one gets the columns back.

## v1.1.2

Line 1 is re-cut: four brackets become three, and every cell that was saying nothing is
gone. Same information, ~40 fewer columns on a typical worktree row. `subagent-statusline.sh`
and `install.sh` are unchanged, and there are no new dependencies.

```
v1.1.1  TheGnarCo/claude-statusline [@worktree-underline-links-1-1-1/underline-links-1-1-1 !2 +163/-34][claude $1.23 ($7.38/h)][Opus 5 1M High claude I][telem tag]
v1.1.2  TheGnarCo/claude-statusline [@worktree-underline-links-1-1-1 +163/-34][Opus 5 1M Hi $1.23 ($7.38/h)][telem tag]
```

### The session group is dissolved

Its three cells went where they belong, and the bracket is gone:

| cell | now lives |
| --- | --- |
| `+N/-M` churn | end of the **git** group — it is what this session did to *this* working tree, so it reads with the tree's own state. Last in the group, so it sheds before the counters: they say what is there now, the churn says how it got there. |
| name | front of the **config** group — it answers "which of my many concurrent tabs is this?" before anything about the model matters. |
| `$cost ($/h)` | end of the **config** group — the group's one derived number, and the only member that keeps moving on its own. |

### Cells that said nothing are gone

- **The generic agent name.** A background/spawned agent that never picked a type is named
  `claude`, so the cell rendered a magenta word on every agent pane that neither identified
  the pane nor told two concurrent agents apart. A deliberately-named agent (`reviewer`)
  still earns it, and a suppressed generic name hands the slot back to `session_name`
  instead of masking it.
- **The vim-mode chip.** One character of live state that nobody was reading, and its slot
  cost the output style a column whenever the group had to shed.

### The worktree renders inside the branch

Claude Code names a worktree branch `worktree-<name>`, so the `/wt` suffix was spending 23
columns restating text the branch already carried. That run of the branch is recolored
magenta in place instead — the same color the suffix used — so the cell still answers
"which worktree?" at zero extra width.

Matched only at a name boundary (the whole branch, or delimited by `-` `/` `_`), so a short
worktree name cannot claim a coincidental substring and suppress a suffix that was carrying
real information; a worktree whose name genuinely is not in the branch still gets its
`/suffix`.

### Smaller change, same meaning

- **Effort tiers are abbreviated**: `Lo` / `Med` / `Hi` / `XHi` / `Max`. The cell is a dial
  position — read against the other tiers, not as a word — and `Medium` spent 6 columns
  saying what `Med` says. An unknown tier still title-cases rather than vanishing.
- **The per-hour burn is gated on the whole row**, not just its own group: it is derived,
  ~9 columns, and recomputable from the total, so a burn rate that costs a wrapped line
  costs more than it says. This subsumes the old group-local check, and the two collapsed
  into one.
- **The telemetry chip is two shades of one hue** — dim burnt orange for covered, bright
  orange for untagged — rather than green-vs-yellow implying two unrelated states. Nothing
  rests on telling the shades apart: the chips already differ by the word *no*. Both have a
  256-color fallback.

### Also

The test suite grew from 58 assertions to 82, and every golden snapshot was regenerated and
reviewed. One second-order effect worth naming: merging groups makes each one wider, so a
narrow pane wraps the title onto its own line slightly sooner than v1.1.1 did.

Docs-only, shipped in `main` but not in this release's scripts: `/gnar-statusline` tracks
`releases/latest` rather than a pinned tag (agent-skills `#426`), so nothing needs bumping
on that side — corrected in `#12` after v1.1.1's notes claimed otherwise.

**Full diff:** [`v1.1.1...v1.1.2`](https://github.com/TheGnarCo/claude-statusline/compare/v1.1.1...v1.1.2)

## v1.1.1

Two small line-1 corrections. No new dependencies; `subagent-statusline.sh` and
`install.sh` are unchanged, and no line is added, removed, or reordered.

### Links are underlined

Every OSC8 hyperlink — the repo title, the branch, the telemetry chip — now renders
underlined. The OSC 8 escape is zero-width, so until now a clickable cell looked exactly
like every other cell on the row: the only way to learn what was a link was to ⌘-click and
find out. The underline is the affordance every terminal renders, and it costs no columns.

It closes with SGR 24 rather than a full reset, so the cell's own color survives, and the
cmux shim drops the underline along with the escape — under cmux there is no link, and an
underlined cell that does nothing when clicked is worse than a plain one.

### The default output style is no longer a cell

Claude Code reports the built-in style by name (`claude`, or `default` on older builds), so
the config group carried a permanent magenta word on every session that had never run
`/output-style`. It now renders only when a **non-default** style is active — which is
exactly when "why is Claude answering like this?" is a question worth a column. A lone
default style leaves no empty bracket behind.

**Full diff:** [`v1.1.0...v1.1.1`](https://github.com/TheGnarCo/claude-statusline/compare/v1.1.0...v1.1.1)

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

A release is the delivery, so the notes above are reviewed *before* the tag exists rather
than written after it is immutable.

1. Land everything intended for the release on `main`.
2. Add its section here in a PR, and merge that PR — it is the last commit in the release.
3. Cut an **annotated** tag at that commit (`v1.0.0` is annotated; keep them consistent).
4. **Publish** a GitHub release at that tag, pointing at this file's section.

Step 4 is the delivery itself, not paperwork after it. `/gnar-statusline` resolves
`releases/latest` at install time (agent-skills `#426` deleted the version it used to
hardcode), so the moment the release is published every subsequent run installs it — there
is nothing to bump in agent-skills and no second review. Two consequences:

- **Publish, don't draft.** The `releases/latest` redirect skips drafts, so a draft release
  delivers nothing while looking done.
- **Tag first, release second.** A release pointing at a tag that doesn't exist yet leaves
  the command's `curl` 404ing, and it refuses to write a partial install.

Verify a release actually landed:

```sh
curl -fsSL -o /dev/null -w '%{url_effective}\n' \
  https://github.com/TheGnarCo/claude-statusline/releases/latest
```
