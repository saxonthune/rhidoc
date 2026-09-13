# todo-task: lifecycle & manual-cleanup reference

Background model for how the system represents task state, plus the hand-cleanup
procedures for merges the orchestrator could not complete automatically. Read this
when you need to reason about lifecycle state or resolve a conflict/deferred chain
by hand — the operational modes do not require it.

## Task Lifecycle (derive, don't store)

There is no directory-as-state-machine. Lifecycle is **derived from which files exist**,
not from moving files between directories. The directories below are stable *categories*,
never lifecycle states.

```
.todo-tasks/
  inbox/{slug}.md            IGNORED   untriaged draft — written by create, local-only
  tasks/{slug}.md            IGNORED   spec — promoted by triage; copied into each worktree
  results/{slug}.agent.md    IGNORED   agent outcome — written on trunk by the orchestrator
  results/{slug}.merge.md    IGNORED   merge outcome — written on trunk after the merge
  chains/{chain}.md          IGNORED   chain definition — written on trunk at completion
  epics/{epic}.md            TRACKED   epic definition with `members: a,b,c`
  task-config.sh             TRACKED   build/test commands
  .running/{slug}.run        IGNORED   run-record — liveness (pid) + worktree location
  .archived/                 IGNORED   physical copies made at archive time
  *.log .version             IGNORED
```

Only `epics/` and `task-config.sh` are tracked. Everything a run produces is
ignored, so a task costs trunk **exactly one commit**: the squash-merge of the
agent's work. Specs and results are still durable on disk and in `.archived/`;
they simply never enter git history.

Phase is computed by the reporter from file presence:

| Files present | Phase |
|---|---|
| draft in `inbox/` only | draft (untriaged) |
| spec in `tasks/` | pending |
| run-record + live PID | running |
| run-record + dead PID + no `merge.md` | crashed (result read from the worktree) |
| `agent.md` + `merge.md` | done (classified success/failure) |

### In-session implementation (no run)

A spec does not have to go to a headless run. A session — the one that triaged it, or a
later one that picked it up — can implement the plan directly in the conversation. There
is no run-record and no `results/` file, so the reporter keeps classifying the spec as
`pending` until it is archived. The sanctioned close-out is:

```bash
bash .claude/skills/todo-task/archive.sh --merged {slug}
```

`--merged` means "the operator asserts this work reached trunk." It takes any non-running
task, including a spec that never ran, and archives it as a success. Commit the actual
work first (the user does this); an in-session implementation carries no separate spec
commit, and the one-commit-per-task guarantee is specific to the headless route — a hand
implementation commits however the user wants.

### Spec-to-git rule

The spec never enters git. `execute-plan.sh` copies it into the agent's worktree, and
`execute-chain.sh` copies every phase spec into the chain worktree, because `git worktree
add` gives a fresh checkout that carries no ignored files. The path is ignored inside the
worktree too, so an agent cannot commit a spec even by accident.

`report.sh` is the **only** component that walks the filesystem and classifies state.
`status.sh`, `monitor.sh`, and `list-pending.sh` are pure renderers over its TSV output.
`archive.sh` is the **only** component that removes files.

## Manual Merge Conflict Resolution

When you manually resolve a merge conflict from an agent (auto-merge failed, so no
`merge.md` was written and the worktree was kept), clean up afterwards:

1. **Remove the worktree** (path shown in `status.sh` and in `.todo-tasks/.running/{slug}.run`):
   ```bash
   git worktree remove <worktree-path>
   ```

2. **Delete the agent branch** (it's already merged):
   ```bash
   git branch -d {trunk}_claude_{slug}
   ```

3. **Archive the task:**
   ```bash
   bash .claude/skills/todo-task/archive.sh {slug}
   ```

If you skip these steps, future sessions will see stale worktrees in status output.

### Finalizing a deferred chain

When a chain defers its merge (`awaiting-merge` or `conflict`) and you complete the merge
by hand, the run-record lingers and the chain shows as `finalizable` on the dashboard.
After you finish the merge, run:

```bash
bash .claude/skills/todo-task/finalize-chain.sh <chain-name>
```

This writes the chain definition to trunk, removes the worktree and branch, and clears the
run-record. `archive.sh` then sweeps it as complete on the next run.

The script refuses to act if the chain's phase results are not yet present on trunk HEAD —
it will print the merge command and exit 1 without touching anything.

### Recovering a stranded chain (`failed` with all phases done)

If a chain shows `failed` but every phase's result already classifies success (a crash
after the last phase merged, before the chain's own trunk merge completed), just re-run
the same `launch-chain.sh` command with the same chain name and phases. Completed phases
are skipped and only the final chain→trunk merge is re-attempted — no manual git needed.

## Rules

- `create` only writes `inbox/{slug}.md` (gitignored draft). Never commit it.
- `triage` promotes the draft → `tasks/{slug}.md` and deletes the inbox draft (and may add a slug to an epic's `members:` list). Do not commit the spec — the orchestrator commits it at launch.
- `execute` launches agents via shell scripts; it never moves files between directories.
- A spec implemented **in-session** is closed with `archive.sh --merged {slug}` once the user has committed the work — same exit as a hand-finished run.
- **Never hand-commit task specs** — `execute-plan.sh`/`execute-chain.sh` commit them automatically before cutting the worktree. An in-session implementation never commits the spec at all; the user commits the work.
- **Never hand-edit `results/*.agent.md`** — it is worktree-owned and carried by the merge.
- **Never write to `.running/`** — the run-record is the orchestrator's; the reporter only reads it.
- **Never hand-move files** to archive — run `archive.sh` (it copies to `.archived/`, then removes).
- **After manually resolving a merge conflict, always clean up** (remove worktree, delete branch, `archive.sh {slug}`).
