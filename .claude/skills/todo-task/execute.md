# todo-task: execute mode

Launch a headless agent to implement a triaged plan.

This mode is the **headless** route only. To implement a spec in the current
conversation instead, do not use `execute` — implement the plan directly, let the user
commit, then run `archive.sh --merged {slug}` (see `triage.md` Step 7 and `REFERENCE.md`).

**Input**: `$ARGUMENTS[1]` is the task slug. If empty, list pending tasks and ask. Supports `--no-merge` and `--chain`.

## Single plan execution

1. **Select** — If no slug, list available plans:
   ```bash
   bash .claude/skills/todo-task/list-pending.sh
   ```
   Ask the user which plan to execute.

2. **Confirm** — Show the plan summary and ask user to confirm.

3. **Launch** — Run `launch.sh`. It validates preconditions synchronously (plan exists, clean tree, correct branch) and only backgrounds the real run if validation passes. Do NOT manually run `execute-plan.sh --validate-only` or hand-roll `nohup` — `launch.sh` handles both.

   ```bash
   bash .claude/skills/todo-task/launch.sh {slug}
   ```

   If the command exits non-zero, validation failed — show the error to the user and tell them what to fix. Do NOT retry.

4. **Auto-watch** — Immediately after a successful launch, start `wait.sh {slug}` as a
   background process:
   ```bash
   bash .claude/skills/todo-task/wait.sh {slug}
   ```
   `wait.sh` blocks polling `report.sh` until the run reaches a terminal state, then exits
   0 on success or non-zero otherwise. Run it with whatever backgrounding your harness
   provides so the harness notifies you when it exits (in Claude Code, the Bash tool's
   `run_in_background`). When it exits you are re-invoked — read its exit and report the
   outcome to the user without being asked. Do NOT poll on your own; the one `wait.sh`
   process is the signal. Use `--timeout SECONDS` if you want a bound.

5. **Report** — Tell the user:
   - Agent is running in the background, and you are watching it via `wait.sh`
   - Check progress live: `tail -f .todo-tasks/.running/{slug}.log`
   - Check results: `.todo-tasks/results/{slug}.agent.md` (+ `.merge.md` after merge)
   - Check status: `/todo-task status`

## Options

- `--no-merge` — leave branch for manual review instead of auto-merging:
  ```bash
  bash .claude/skills/todo-task/launch.sh {slug} --no-merge
  ```

## Chain execution

If `--chain` is passed with multiple slugs, call `launch-chain.sh`:
```bash
bash .claude/skills/todo-task/launch-chain.sh {chain-name} {slug1} {slug2} ...
```

Then **auto-watch the whole chain** the same way as a single plan: start
`wait.sh {chain-name}` as a background process. `wait.sh` auto-detects a chain by name and
blocks until every phase has run and the chain merges (or fails), so one watcher covers the
entire chain — you do not watch phases individually. When it exits, report the chain outcome.

To queue a chain to start after a running or pending standalone task completes and merges, pass `--after <predecessor-slug>`:
```bash
bash .claude/skills/todo-task/launch-chain.sh {chain-name} {slug1} {slug2} ... --after {predecessor-slug}
```

The predecessor must be a standalone task (not part of the chain). It merges to trunk independently; the chain waits for it to complete and merge successfully before cutting its worktree from the now-updated trunk. If the predecessor fails or does not produce a result, the chain aborts. The predecessor slug must exist in pending, running, or done at launch time.
