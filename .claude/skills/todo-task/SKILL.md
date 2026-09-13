---
name: todo-task
description: "Task lifecycle manager: create ideas, triage into specs, implement them in-session or via headless agents, check status, monitor agents. Usage: /todo-task [create|triage|execute|status|monitor] [args]"
---

# todo-task

Unified task lifecycle manager. When the user's intent is clear (e.g. "make a todotask to..."), go straight to the appropriate mode — do not run status first.

Route on `$ARGUMENTS[0]`. Each non-trivial mode lives in a sibling file — **read that file before acting in the mode**:

| Command | Mode | Read first |
|---------|------|-----------|
| `/todo-task` or `/todo-task status` | Show status | inline below |
| `/todo-task monitor` | Live dashboard | inline below |
| `/todo-task create {description}` | File a new task | `create.md` |
| `/todo-task triage {slug}` | Refine a task into an executable spec | `triage.md` |
| `/todo-task execute {slug}` | Launch headless agent to implement a plan | `execute.md` |

A spec reaches "done" by one of two routes, and triage picks between them with the
user:

- **In-session** — whoever triaged (or a later session that picked the spec up)
  implements it in the conversation, the user commits, and `archive.sh --merged {slug}`
  closes it out. No worktree, no `execute`. This is the path for work that grew
  through discussion, or that a person wants to drive by hand.
- **Headless** — `execute` launches an agent in an isolated worktree that implements,
  verifies, and squash-merges one commit to trunk. This is the path for well-bounded
  work that needs no mid-implementation judgement.

A draft is also a durable handoff between sessions: one session can file a task purely
so a later session has the context to triage and implement it. Launch is not the
assumed destination.

All files are in `.claude/skills/todo-task/`. For the lifecycle model (derive-don't-store),
manual merge-conflict cleanup, deferred-chain finalization, and the invariant rules, read
`REFERENCE.md` — needed only when reasoning about state or cleaning up a merge by hand.

First-time setup: if todo-task scripts prompt for approval, read `.claude/skills/todo-task/SETUP.md` for a suggested allowlist (kept separate to avoid context pollution).

---

## Vocabulary

One preferred term per concept — use these, not coined synonyms. **Chain** and **epic**
are orthogonal: chain is a *run* mechanism, epic is a *grouping* label; you can chain
without an epic and group an epic without chaining.

- **Task** — one unit of work moving through the lifecycle, named by a **slug**.
- **Draft** — an untriaged idea at `inbox/{slug}.md` (gitignored). Created by `create`.
- **Spec** — a triaged, executable task at `tasks/{slug}.md`. A draft becomes a spec by **triage**. A spec may be implemented in-session or by a run.
- **Run** — one headless-agent execution of a spec, in an isolated **worktree**. Only the headless route produces a run; an in-session implementation has none.
- **Worktree** — the throwaway git checkout (`../{prefix}-{repo}-{slug}`) a run works in; carries ignored files (specs, results) by copy, never by commit.
- **Trunk** — the branch runs merge back into. A successful task adds **exactly one commit** to trunk.
- **Run-record** — `.running/{slug}.run`, the orchestrator's live state for a run. The reporter reads it; nothing else writes it.
- **Chain** — an ordered set of specs (its **phases**) run sequentially, each accumulating onto one shared chain branch, merged to trunk as a **single squash commit**. Mechanically it runs any ordered specs; its intended use is dependent phases, where each phase is triaged against the previous phase's Surface.
- **Phase** — one spec within a chain.
- **Surface** — a phase's `## Surface after this phase` block: the symbols and behaviors it promises the next phase. Absent from a Surface = later phases treat it as nonexistent. A triage-time contract, not enforced at run time.
- **Epic** — `epics/{epic}.md` with `members: a,b,c`: a tracked label over related tasks that still execute and merge independently.
- **Derive-don't-store** — lifecycle state is computed from file presence by `report.sh`, never written as a standing status field.

---

## Mode: `status` (default when no arguments)

**IMPORTANT: ALWAYS run the status script FIRST. Do NOT read files, investigate errors, check git state, or do any other research before running this script. Show the script output to the user, then follow the triage flow below. Only investigate issues after the full triage flow is complete and the user asks you to.**

Run the status script with `--archive` and display results:

```bash
bash .claude/skills/todo-task/status.sh --archive
```

`--archive` renders the board AND auto-archives clean successes and completed chains in the same step (status delegates to `archive.sh`), printing an `- Archived {slug}` line for each. Make this the default — archiving successes is routine, derived cleanup, not a decision, so never ask whether to do it. Add `--force-failed` only if the user also wants failures archived.

### Triage completed agents

The `--archive` render above already archived clean successes and completed chains and reported which ones — relay those lines to the user. Then handle the states it deliberately leaves in place (these need a human, and are never auto-archived):

**Conflict agents (`merge_conflict` / `merged_with_markers`):** NOT auto-archived — the worktree is kept for resolution. Check if the branch was already merged manually. If `git log` shows the agent's commits on the current branch, the conflict was already resolved — then `archive.sh {slug}` cleans up. If not, treat as a failed merge and ask the user.

**Ready-for-review agents (`--no-merge`):** NOT archived — they await a human merge of the agent branch.

**Failed agents (`build_failure`/`session_failed`/`no_op`/`trunk_leak`, crashed, failed chains):** Do NOT archive by default. `archive.sh --force-failed` archives them explicitly once reviewed. First, ask the user what to do with `AskUserQuestion` (header "Failed agent"), offering: **Fix it now** (recommended — investigate the failure and fix the code in the existing worktree), **Re-triage and retry** (refine the plan to avoid the failure, then re-launch), **Archive and skip** (move to archived, don't retry).

**Salvaged agents (`salvageable`, e.g. a crashed run finished and merged by hand):** Never `--force-failed`-eligible — a worktree with recoverable work is never auto-`rm`'d. Once the operator has finished the work by hand and squash-merged it to trunk, run `archive.sh --merged <slug>` to clean it up — this is the sanctioned exit, not hand-moving files into `.archived/`.

---

## Mode: `monitor`

Launch the live dashboard — a self-refreshing TUI showing running agents, recent completions, and epic progress.

Tell the user to run it in a separate terminal (it redraws on its own; press `q` or `Ctrl-C` to exit):

```bash
bash .claude/skills/todo-task/monitor.sh
```

---

## Core rules

Full detail (with rationale) lives in `REFERENCE.md`. The invariants:

- `create` only writes `inbox/{slug}.md` (gitignored draft). Never commit it.
- `triage` promotes the draft → `tasks/{slug}.md` and deletes the inbox draft (and may add a slug to an epic's `members:` list). Do not commit the spec — the orchestrator commits it at launch.
- `execute` launches agents via shell scripts; it never moves files between directories.
- A spec implemented **in-session** is closed with `archive.sh --merged {slug}` after the user commits — same sanctioned exit as a hand-finished run.
- **Never hand-commit task specs** — when a spec goes to a run, the orchestrator commits it automatically before cutting the worktree. (An in-session implementation carries no separate spec commit — the user commits the actual work.)
- **Never hand-edit `results/*.agent.md`** — it is worktree-owned and carried by the merge.
- **Never write to `.running/`** — the run-record is the orchestrator's; the reporter only reads it.
- **Never hand-move files** to archive — run `archive.sh` (it copies to `.archived/`, then removes).
- **After manually resolving a merge conflict, always clean up** — see `REFERENCE.md`.
