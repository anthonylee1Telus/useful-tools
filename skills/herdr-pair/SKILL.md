---
name: herdr-pair
description: >-
  Launch a peer coding agent (Claude, Codex, etc., on any named model) inside a new Herdr terminal pane or split, then run a multi-turn conversation with it through shared markdown files. Use this skill only when the user explicitly asks for a pane or split to host the new agent, e.g. "in a new pane", "in a split", "next to this pane", "herdr pane". Typical uses: a helper that reviews, challenges, digs through logs or implements alongside you. The literal word "pane" or "split" (or Herdr by name) is required. Phrases like "pair with another agent", "open another claude next to/beside you", "start a planner agent", "split the work", "two of you", "coordinate through files" or "iterate til it's good" don't qualify without it. Those go to normal subagent delegation, not this skill. Also don't use it to message or prompt an agent that already exists, run shell commands in a pane, switch your own model, or route a task to a cheaper model. Requires HERDR_ENV=1.
---

# herdr-pair

You are the **leader**. You spawn a **peer** agent in a sibling Herdr pane, then
run a turn-based conversation with it. Each message is a markdown file in a
shared comms directory. You drive the loop. The peer only ever replies by
writing a file and then ending its turn.

Files are the channel because terminal scrollback is lossy: agents draw on the
alternate screen, and long injected prompts are fragile. A file gives both sides
the whole message, and the user gets a readable transcript afterwards.

## 0. Preconditions

```bash
test "${HERDR_ENV:-}" = 1 || echo "NOT IN HERDR"
```

If you're not inside Herdr, say so and stop. For any command syntax this file
doesn't cover, the installed binary is the authority: run `herdr --skill`, or
run a command group like `herdr agent` with no subcommand. Don't guess flags.

## 1. Gather inputs (defaults are fine, so don't over-ask)

- **Task / role for the peer.** Get this from the request, e.g. "review my
  plan" or "implement the tests while I write the handler". Ask only if it's
  genuinely unclear.
- **Model.** If the user named one (e.g. "sonnet", "haiku", `claude-opus-5-5`),
  pass it through. If not, omit the flag so the peer gets its CLI's default
  model.
- **Agent kind.** The default is `claude`. If the user names a non-Claude model
  or tool (codex, gemini, …), map it to the matching `--kind` value (see
  `herdr agent start --help`), then run `<kind> --help` to find that CLI's
  model flag. Don't assume it's `--model`.
- **Peer write access.** The peer has to write its reply file, and a peer in
  default permission mode blocks on every write, which stalls each turn on the
  user. Ask once with AskUserQuestion. Offer:
  1. *acceptEdits + comms dir (Recommended).* Use
     `--permission-mode acceptEdits --add-dir <comms>`. The peer auto-accepts
     file edits in its working dirs, which includes its cwd as well as the
     comms dir. This does **not** cover Bash, so a peer that runs even a
     read-only shell command to check a fact will still block.
  2. *auto + comms dir.* Use `--permission-mode auto --add-dir <comms>`. This
     covers shell commands too, so there are fewer stalls, but the peer acts
     with less oversight.
  3. *Default permissions.* The user approves each write in the peer pane. You
     will see `blocked` states.
- **Turn cap.** Default 6 round trips. This is an arbitrary heuristic, so tell
  the user they can change it.

## 2. Set up the comms directory

Use a temp dir so nothing lands in the repo. In a background job, put it under
`$CLAUDE_JOB_DIR/tmp`, which is removed when the job is deleted:

```bash
COMMS=$(mktemp -d "${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"/herdr-pair.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/herdr-pair.XXXXXX"); echo "$COMMS"
```

Shell variables don't persist between Bash tool calls, so copy the printed path
and use it as a literal everywhere `$COMMS` appears below. One way is to start
each later Bash call with `COMMS=<literal path>;`. If you skip this, the peer
gets told to read `/PROTOCOL.md`.

Write `$COMMS/PROTOCOL.md` (the peer reads it once) from this template:

```markdown
# Pairing protocol

You are the PEER agent, working with a LEADER agent in another pane.
Shared dir: <COMMS>
Working directory: <PWD>
Your role: <ROLE / TASK SUMMARY>

## How turns work
- Every message is a file `NNN-lead.md` (from the leader) or `NNN-peer.md` (from you). NNN is a zero-padded turn counter.
- When prompted, read the newest `NNN-lead.md` (and earlier files if you need context), do the work, then write your reply to the exact path the leader gives you. Then **stop and end your turn**. Don't wait or poll for the next message. The leader will prompt you.
- The first line of every reply must be exactly one of:
  - `STATUS: CONTINUE`: more back-and-forth is needed.
  - `STATUS: DONE`: from your side the task is finished.
  - `STATUS: NEEDS_USER`: you need a decision only the human can make (say what it is).
- After the status line, write your reply in markdown. Be concrete: say what you did, which files you changed, what you found, and what you need from the leader.

## Rules
- Don't message the leader any other way. Never run `herdr agent prompt`, `herdr agent send-keys`, `herdr pane send-*`, or `herdr pane run` against any pane. Injecting text into a busy session corrupts it.
- Don't spawn other agents and don't invoke the herdr-pair skill.
- Don't edit files outside your agreed scope (see the role above). If you think a change is needed elsewhere, propose it in your reply.
```

Then write the first message, `$COMMS/001-lead.md`. Include the task, the
relevant context (file paths, constraints, what you're doing in parallel), and
what you want back.

### Keep a session artifact log

From the start, keep `$COMMS/ARTIFACTS.md`. Each time you create something
**only** for this pairing session, append one line with its kind and literal
path or ID. Kinds: `pane <pane_id>`, `worktree <path>`, `file <path>`,
`dir <path>`. Examples are a review worktree, a scratch file of a draft, or a
pane you split. The comms dir itself is implied and is deleted last. Wrap-up
(step 5) cleans up from this log, and a log survives context compaction where
your memory does not.

Never log anything that existed before the session, any repo file, or a
deliverable the user asked for (a report, a page, a commit). A file you wrote
under the repo for the user is theirs, not a session artifact. If you reuse an
existing comms dir later in the same conversation, keep appending to its log.

## 3. Spawn the peer pane

```bash
herdr pane layout --pane "$HERDR_PANE_ID"
```

Split **right** if the caller pane is wide, and **down** if it's narrow or tall.
Don't make a sliver: if the tab already has several columns, prefer `down`.
Keep the user's focus where it is:

```bash
herdr pane split --current --direction <right|down> --cwd "$PWD" --no-focus
```

Read the new ID from `.result.pane.pane_id`. Don't predict it. Append
`pane <pane_id>` to `$COMMS/ARTIFACTS.md`. Then choose a
peer name that matches `[a-z][a-z0-9_-]{0,31}` and isn't already live (check
with `herdr agent list`). Base it on the role, e.g. `reviewer`, `impl-peer`, or
`planner-2`.

```bash
herdr agent start <name> --kind claude --pane <pane_id> -- \
  [--model <model>] [--permission-mode acceptEdits] --add-dir "$COMMS"
```

Anything after `--` goes to the agent CLI. Drop `--model` when you're using the
default model. Drop `--permission-mode` if the user picked default permissions.
If start returns `agent_not_ready` (blocked at startup, e.g. a trust-folder
dialog), run `herdr agent read <name> --source recent-unwrapped --lines 60`,
show the user what it says, and ask before you answer it.

## 4. The turn loop

Turn `n` (starting at 1). You've already written `NNN-lead.md`, where `NNN` is
`n` zero-padded to 3 digits:

1. **Prompt briefly.** On turn 1, include the protocol:
   ```bash
   herdr agent prompt <name> "Read $COMMS/PROTOCOL.md, then $COMMS/001-lead.md. Do the work, write your reply to $COMMS/001-peer.md, then end your turn." --wait --timeout 540000
   ```
   On later turns: `"New message: $COMMS/NNN-lead.md. Reply to $COMMS/NNN-peer.md, then end your turn."`
   Run this Bash call with `timeout: 600000`. The Bash tool caps foreground
   calls at 600s, so herdr's `--timeout` has to sit below it. 540000 is a
   margin heuristic, not a measured value.
   **Parallel work:** if you have your own share of the task to do this turn,
   prompt without `--wait`, do your work, then run
   `herdr agent wait <name> --timeout 540000`.

2. **Handle the wait result.**
   - `idle` / `done`: go to step 3.
   - `blocked`: the peer is at an approval or question UI. Run
     `herdr agent read <name> --source recent-unwrapped --lines 80` and show
     the user, and ask how to answer (AskUserQuestion). Don't decide for them.
     If they tell you to answer for them, use
     `herdr agent send-keys <name> <key>`, e.g. `1` for "Yes". Herdr's state
     can lag the keystroke, so an immediate wait may return the stale
     `blocked`. Run `herdr agent wait <name> --until working --timeout 10000`
     first. 10000 is a heuristic, and a timeout exit is fine because it just
     means the agent finished fast. Then, as a separate call or joined with
     `;` rather than `&&` (the first wait exits 1 on timeout), run
     `herdr agent wait <name> --timeout 540000`. If that still returns
     `blocked`, read the pane again: if no dialog is showing, the state is
     stale, so wait again.
   - `timeout`: the peer is still working. Re-issue
     `herdr agent wait <name> --timeout 540000`. **Don't re-prompt.** A second
     prompt queues a duplicate turn.
   - `agent_prompt_stalled` / `agent_blocked`: read the pane, report to the
     user, then decide together.

3. **Verify the reply exists.** `--wait` tracks lifecycle state, not turns, so
   "idle" alone doesn't prove the peer answered. Check that
   `$COMMS/NNN-peer.md` exists. If it's missing, read the pane to see why, and
   send one nudge (`"Please write your reply to $COMMS/NNN-peer.md now, then
   end your turn."`). If it's still missing after the nudge, stop and tell the
   user.

4. **Read and act.** Read `NNN-peer.md` and parse the `STATUS:` line.
   - `CONTINUE`: do your side of the work, write `(n+1)-lead.md` with your
     response or next request, and loop.
   - `DONE`: if you agree the task is finished, go to step 5. If not, write
     the next lead file explaining what's still open, and loop.
   - `NEEDS_USER`: put the question to the user verbatim, write their answer
     into the next lead file, and loop.
   - Missing or garbled status: treat it as CONTINUE, and remind the peer of
     the format in your next message.

5. **Cap.** When you hit the turn cap, stop and summarize the state for the
   user. Ask whether to continue for more turns.

Between turns, give the user a one-line progress note (turn n: what the peer
said and what you're doing next), so they aren't watching a silent loop.

You can end the conversation yourself at any time by writing a final lead file
whose first line is `STATUS: DONE` and that holds a closing summary. You don't
need to prompt the peer on it unless you want an acknowledgement.

## 5. Wrap up

- Summarize what got done, who changed which files, and anything unresolved.
- Give the comms dir path, which holds the full transcript.
- **Ask once about all session artifacts.** Read `$COMMS/ARTIFACTS.md`, then
  ask with AskUserQuestion: "Delete all artifacts from this session?" List
  every item with its literal path or ID in the question: the comms dir
  (transcript), each logged pane, worktree, file and dir. Offer:
  1. *Yes, delete all.*
  2. *Choose which.* Follow up with a multiSelect of the same items.
  3. *Keep everything.*
- **On delete, remove exactly the logged items** (or the chosen ones), in this
  order, and report each result:
  1. Worktrees: `git -C <repo> worktree remove --force <path>`.
  2. Panes: `herdr pane close <pane_id>`. Only panes from the log, so never
     one you didn't create.
  3. Files and dirs: `rm -f -- <file>` for each file, and
     `find <dir> -mindepth 1 -delete && rmdir <dir>` for each dir. Don't use
     `rm -rf`, because a deny rule blocks it.
  4. The comms dir, last, because it holds the log:
     `~/.claude/skills/herdr-pair/cleanup.sh <literal comms path>`. It is
     allow-listed, and it refuses any path that isn't a `herdr-pair.XXXXXX`
     dir directly under a temp root. A comms dir under `$CLAUDE_JOB_DIR/tmp`
     also goes when the job is deleted.
- Then confirm what was removed and what remains. Run `git worktree list` and
  check each path is gone. Delete nothing that isn't in the log, even if it
  looks like a leftover. Name it to the user instead.
- **On keep**, leave the peer pane open in case the user wants to inspect it
  or keep talking.

## Pitfalls

- **Same files, same time.** If both agents edit code, divide ownership in
  `001-lead.md` (e.g. "you own `src/foo/**`, I own the rest") so you don't
  clobber each other. Don't edit files the peer owns while its turn is running.
- **Long prompts in `agent prompt`.** Keep prompt text to one or two lines that
  point at files. The substance belongs in the markdown.
- **Targets.** Address the peer only by its name or its pane ID. Never rely on
  the UI-focused pane, which may be the user's.
