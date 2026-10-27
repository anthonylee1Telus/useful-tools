---
name: pair-review
description: >-
  Two-reviewer PR review. Claude's /code-review and a peer Claude in a new Herdr pane running /codex:adversarial-review review the same PR head, reconcile over shared files until aligned, and produce ONE combined table (Number | File : line | What to change | Why | Severity). Asks before posting to GitHub. Optional args: effort level (low|medium|high|xhigh|max) and max rounds (--rounds N, default 4). Requires HERDR_ENV=1.
disable-model-invocation: true
argument-hint: '<pr-number|branch> [low|medium|high|xhigh|max] [--rounds N] [focus text]'
---

# pair-review

You are the **leader**. You produce one review yourself with `/code-review`, a
**peer** Claude in a sibling Herdr pane produces an independent one with
`/codex:adversarial-review`, and the two of you reconcile until aligned. The
user gets a single merged table, then decides whether it goes to GitHub.

Two independent reviewers catch different things (in the session this skill
came from, Codex approved with zero findings while Claude found five doc-drift
issues — and Claude had three stale findings that Codex's fresh look exposed).
The value is in the *reconciliation*, so don't skip it.

## 0. Parse arguments and preconditions

- **Target**: a PR number (default) or a branch name. If absent, use the PR
  for the current branch (`gh pr view --json number`); if none, ask.
- **Effort**: optional `low|medium|high|xhigh|max`. If given, pass it to
  `/code-review` and to the peer via `--effort`. If omitted, pass no level
  anywhere: `/code-review` then reuses the user's last level and the peer
  Claude starts at the configured default — i.e. "the effort currently set".
  `/codex:adversarial-review` itself has **no effort option** (its companion
  script only accepts `--base`, `--scope`, `--model`, `--cwd` for reviews), so
  don't invent one; the effort only governs the Claude side of the peer.
- **Max rounds**: optional `--rounds N` (also accept "N rounds" / "max N
  rounds" in prose): the cap on leader↔peer round trips in step 4. Default
  **4** when not given. Must be a positive integer; otherwise ask.
- **Focus text**: anything else is passed through as Codex focus text.

```bash
test "${HERDR_ENV:-}" = 1 || echo "NOT IN HERDR"
```
Not in Herdr → say so and stop.

## 1. Pin the review target (one head for both reviewers)

Both reviews must look at the **same commit**. A PR that gets pushed to
mid-review produces stale findings that waste a reconciliation round, so
record the head SHA now and re-check it before publishing.

```bash
gh pr view <N> --json headRefName,baseRefName,headRefOid,title
git fetch -q origin <head> <base>
```

Create a detached worktree of the head in your scratchpad (never touch the
user's checkout — they may be on another branch with work in progress):

```bash
git worktree add -q --detach <scratchpad>/pr<N> origin/<head>
```

The peer works in that worktree; `/codex:adversarial-review` reviews
`HEAD` vs `--base origin/<base>`.

The comms dir doesn't exist yet, so keep the worktree path. Step 3 logs it.

## 2. Start your own review (background)

Invoke the `code-review` skill with args `<effort?> pr <N>` (append nothing
about GitHub; it does not post unless `--comment` is passed — don't pass it).
It runs as a background fork; its findings arrive as a task notification.

Do **not** delegate the Herdr/peer part to that fork — a forked review
agent won't spawn panes. You (the leader) own steps 3–5 while it runs.

## 3. Spawn the peer and run Codex

Follow `~/.claude/skills/herdr-pair/SKILL.md` for the mechanics (comms dir,
`PROTOCOL.md`, pane split, `herdr agent start`, the turn loop, handling
`blocked`/`timeout`). Read it now if you haven't this session. Specifics for
this skill:

- **Artifact log**: as soon as the comms dir exists, append
  `worktree <scratchpad>/pr<N>` to `$COMMS/ARTIFACTS.md` (herdr-pair "Keep a
  session artifact log"). The pane line follows herdr-pair step 3. Log every
  later scratch file the same way.
- **Permissions**: ask once (AskUserQuestion). Recommend
  *auto + comms dir*: the peer validates findings with read-only `sed`/`cat`/
  `git diff`, and under `acceptEdits` each of those blocks on the user.
  Offer *acceptEdits + comms dir* and *default* as the alternatives.
- **Start** with `--cwd <worktree>` on the split and
  `-- [--effort <level>] --permission-mode <mode> --add-dir <comms>`.
  Name it e.g. `pr<N>-codex`.
- **PROTOCOL.md role**: "independent adversarial reviewer of PR <N>; review
  only; do NOT post to GitHub, push, or edit repo files; only write in the
  comms dir; cite file:line for every claim and mark anything unverified."
- **First prompt is the slash command itself.** `/codex:adversarial-review`
  has `disable-model-invocation`, so the peer can't call it as a tool; it must
  arrive as typed input. Use `--wait` so it doesn't stop to ask
  foreground/background:
  ```bash
  herdr agent prompt <name> "/codex:adversarial-review --wait --base origin/<base> <focus text>" --wait --timeout 540000
  ```
- **Turn 1** (`001-lead.md`): ask the peer to put Codex's output in its reply
  (keep every finding), validate each Codex claim against the worktree as
  CONFIRMED / PLAUSIBLE / REJECTED with file:line, add anything Codex missed,
  and end with a ranked list. Do **not** include your findings yet — the
  independence is the point.

## 4. Reconcile until aligned

Once both your `/code-review` result and `001-peer.md` are in:

1. `git fetch` and compare the head SHA with step 1. If it moved, say so,
   update the worktree, and re-verify every finding against the new head.
2. Spot-check your own findings at the head (grep the cited lines). Withdraw
   anything already fixed rather than defending it.
3. Write `002-lead.md`: your findings, split into *withdrawn (fixed at head)*,
   *overlapping with yours*, and *only mine*. Ask the peer to verify the
   contested ones and propose a merged ranked list; reply `STATUS: DONE` if
   it agrees.
4. Loop until DONE or the round cap (`--rounds`, default 4 — a heuristic;
   tell the user the cap in use and that `--rounds N` changes it). Turn 1
   counts as round 1. Disagreements that survive the cap go in the final
   output as explicitly *disputed*, with both positions — don't ask to
   extend; the user can re-run with a higher `--rounds`.

Give the user a one-line progress note between turns.

## 5. Build the combined table

Before writing it, re-check **every** `file:line` against the pinned head —
line numbers drift and you'll be publishing them. One row per file location
(split a finding that touches several files into several rows).

Use exactly these columns:

```markdown
| Number | File : line | What to change | Why | Severity |
|---|---|---|---|---|
| 1 | `path/to/file.ts:42` | Concrete edit | Evidence-backed reason, citing design/code file:line | High |
```

- Severity: Critical / High / Medium / Low / Info. Rank most severe first.
- Above the table: head SHA reviewed, one-line verdict (e.g. "no code
  defects; all items are doc drift"), and whether tests were run (say plainly
  if neither reviewer ran them).
- Below the table: withdrawn/stale findings in one line, and any disputed
  items.

Show the table to the user in the terminal.

## 6. Ask before posting

Nothing goes to GitHub by default — a PR comment is public, outward-facing,
and hard to retract. Ask with AskUserQuestion: "Post these recommendations to
PR <N>?" (Yes / No). Only on **Yes**:

```bash
gh pr comment <N> --body-file <scratchpad>/pr<N>-review.md
```

The body is the summary + table + footnote, ending with the PR attribution
lines from the current system reminder if any. Report the comment URL.
When you write the body file, append `file <scratchpad>/pr<N>-review.md` to
`$COMMS/ARTIFACTS.md`, whether or not it gets posted.

## 7. Ask about cleanup

Follow herdr-pair step 5 "Wrap up": ask once, list every item in
`$COMMS/ARTIFACTS.md` plus the comms dir with literal paths or IDs, and offer
*Yes, delete all* / *Choose which* / *Keep everything*. Delete only logged
items, in that step's order (worktree, pane, files, comms dir last). The PR
comment is not a session artifact; never delete it.
