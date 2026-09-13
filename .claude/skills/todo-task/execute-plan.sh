#!/usr/bin/env bash
set -uo pipefail

# ─── Plan Executor Orchestrator ───────────────────────────────────────────────
# Creates a worktree, runs headless Claude to implement a plan, verifies, merges.
#
# Usage: execute-plan.sh <plan-name> [options]
#   plan-name: filename (without .md) in .todo-tasks/
#   --no-merge: leave branch ready for manual merge instead of auto-merging
#   --trunk-dir <path>: merge back into this directory instead of repo root
#   --trunk-branch <name>: branch name to treat as trunk (for worktree-based chains)
#   --no-guard: skip the dirty-tree check (caller guarantees a clean trunk)

# ─── Parse Arguments ──────────────────────────────────────────────────────────

PLAN_SLUG=""
NO_MERGE=false
VALIDATE_ONLY=false
TRUNK_DIR=""
TRUNK_BRANCH=""
NO_GUARD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-merge) NO_MERGE=true ;;
    --validate-only) VALIDATE_ONLY=true ;;
    --no-guard) NO_GUARD=true ;;
    --trunk-dir) TRUNK_DIR="$2"; shift ;;
    --trunk-branch) TRUNK_BRANCH="$2"; shift ;;
    -*) echo "Unknown option: $1"; exit 1 ;;
    *) PLAN_SLUG="$1" ;;
  esac
  shift
done

if [[ -z "$PLAN_SLUG" ]]; then
  echo "Usage: execute-plan.sh <plan-name> [--no-merge] [--trunk-dir <path>] [--trunk-branch <name>] [--no-guard]"
  echo ""
  echo "Available plans:"
  ls .todo-tasks/tasks/*.md 2>/dev/null | sed 's|.*/||;s|\.md$||' | sed 's/^/  /'
  exit 1
fi

# ─── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "${SCRIPT_DIR}/lib.sh"
source_task_config

# ─── Provider adapter selection ──────────────────────────────────────────────
# TODO_TASK_PROVIDER selects skills/todo-task/providers/<name>.sh, a sourced
# bash file defining provider_run_session, provider_resume_session, and
# provider_run_fresh_session (see providers/claude.sh for the contract).
PROVIDER_FILE="${SCRIPT_DIR}/providers/${TODO_TASK_PROVIDER}.sh"
if [[ ! -f "$PROVIDER_FILE" ]]; then
  echo "ERROR: Unknown provider '${TODO_TASK_PROVIDER}' — no such file: providers/${TODO_TASK_PROVIDER}.sh"
  echo "Available providers:"
  ls "${SCRIPT_DIR}/providers/"*.sh 2>/dev/null | sed 's|.*/||;s|\.sh$||' | sed 's/^/  /'
  exit 1
fi
source "$PROVIDER_FILE"

# Initialize trunk state early so emergency_finalize always has a value under set -u
TRUNK_STATE="$SM_TRUNK_UNCHANGED"
TRUNK_HEAD_BEFORE=""
SURFACE_DEVIATIONS="none"
SESSION_TURNS=""
SESSION_COST=""
UNCOMMITTED_SUMMARY="none"
TURNS_FIELD=""
COST_FIELD=""

# Use caller-specified trunk or detect from current branch
if [[ -n "$TRUNK_BRANCH" ]]; then
  TRUNK="$TRUNK_BRANCH"
else
  TRUNK="$(git branch --show-current)"
fi

# Use caller-specified trunk directory or default to repo root
if [[ -n "$TRUNK_DIR" ]]; then
  MERGE_DIR="$(cd "$TRUNK_DIR" && pwd)"
else
  MERGE_DIR="$REPO_ROOT"
fi

BRANCH="${TRUNK}_claude_${PLAN_SLUG}"
WORKTREE_DIR="${REPO_ROOT}/../${WORKTREE_PREFIX}-${REPO_NAME}-${PLAN_SLUG}"
PLAN_SOURCE_FILE="${REPO_ROOT}/.todo-tasks/tasks/${PLAN_SLUG}.md"

# ─── Emergency Finalizer ─────────────────────────────────────────────────────
# Runs on unexpected EXIT. We no longer move any files: the reporter's crashed
# rule (run-record present + dead PID + no merge.md) already covers abrupt
# exits. The only best-effort action is to leave a stub agent.md in the worktree
# if one was never composed, so the reporter has something to classify.

emergency_finalize() {
  [[ -z "${PLAN_SLUG:-}" ]] && return
  # A completed merge means we finished normally — nothing to do.
  [[ -f "${MERGE_DIR:-$REPO_ROOT}/.todo-tasks/results/${PLAN_SLUG}.merge.md" ]] && return

  local wt_results="${WORKTREE_DIR:-}/.todo-tasks/results"
  local agent_md="${wt_results}/${PLAN_SLUG}.agent.md"
  if [[ -n "${WORKTREE_DIR:-}" && -d "${WORKTREE_DIR}" && ! -f "$agent_md" ]]; then
    mkdir -p "$wt_results"
    write_agent_result "$agent_md" "$PLAN_SLUG" \
      "$SM_SESSION_FAILED" "$SM_VERIFY_FAILED" 0 "(none)" "${BRANCH:-unknown}" "" \
      "Script exited unexpectedly." "" "phase: ${CURRENT_PHASE:-unknown}" "none"
  fi
}

trap 'emergency_finalize' EXIT

# ─── Phase Functions ──────────────────────────────────────────────────────────

# phase_validate
# Checks plan exists, trunk branch is valid, working tree is clean.
# Exits 0 early if --validate-only.
phase_validate() {
  echo "═══ Plan Executor: ${PLAN_SLUG} ═══"
  echo ""

  if [[ ! -f "${PLAN_SOURCE_FILE}" ]]; then
    echo "ERROR: Plan file not found: .todo-tasks/tasks/${PLAN_SLUG}.md"
    exit 1
  fi

  # The trunk-branch and clean-tree guards protect worktree creation and merge,
  # neither of which --validate-only performs — skip them so a spec can be
  # validated from inside a chain-phase worktree (whose own branch legitimately
  # carries a '_claude' suffix) without a real trunk checkout.
  if [[ "$VALIDATE_ONLY" == "false" ]]; then
    if [[ "$TRUNK" == *_claude* ]]; then
      echo "ERROR: Must run from trunk branch (current: ${TRUNK})"
      echo "Switch to a branch without '_claude' suffix first."
      exit 1
    fi

    # Guard: refuse to launch if the working tree is dirty (unless caller says skip).
    # `.todo-tasks/` is excluded — its files are orchestrator-managed (uncommitted
    # specs, run-records, stranded results) and never endanger the worktree merge.
    # The spec itself is committed by phase_commit_spec before the worktree is cut.
    if [[ "$NO_GUARD" == "false" ]]; then
      if ! git -C "$MERGE_DIR" diff --quiet -- . ':(exclude).todo-tasks' \
         || ! git -C "$MERGE_DIR" diff --cached --quiet -- . ':(exclude).todo-tasks' \
         || [[ -n "$(git -C "$MERGE_DIR" ls-files --others --exclude-standard -- . ':(exclude).todo-tasks')" ]]; then
        echo "ERROR: Working tree has uncommitted changes (outside .todo-tasks/)."
        echo ""
        echo "The agent runs in a worktree branched from HEAD. Any uncommitted"
        echo "changes won't be in the worktree and will likely cause merge"
        echo "conflicts when the agent's branch merges back."
        echo ""
        echo "Commit your current changes before re-launching."
        echo "If the user prefers manual git operations, prompt them"
        echo "to commit or stash their changes, then re-launch."
        exit 1
      fi
    fi
  fi

  # Validate that the plan has a parseable ## Verification fenced block
  if ! VERIFY_SCRIPT=$(parse_verification_commands "${PLAN_SOURCE_FILE}"); then
    exit 1
  fi

  # Validation passed — exit early if that's all we were asked to do
  if [[ "$VALIDATE_ONLY" == "true" ]]; then
    echo "Validation passed."
    exit 0
  fi
}

# phase_capture_baseline
# Records the trunk tip before the agent runs, so phase_verify's trunk-leak
# check has something to compare against.
#
# This used to also commit the spec, to keep the squash-merge from colliding
# with an untracked spec file. `.todo-tasks/tasks/` is now ignored, so no such
# collision is possible and the commit is gone — a task costs trunk one commit.
phase_capture_baseline() {
  TRUNK_HEAD_BEFORE=$(git -C "$MERGE_DIR" rev-parse "${TRUNK}" 2>/dev/null || echo "")
}

# phase_record_run
# Writes the gitignored run-record (liveness + worktree location). The spec is
# NOT moved — lifecycle is derived from file presence, never directory moves.
phase_record_run() {
  write_run_record "$PLAN_SLUG" "$WORKTREE_DIR" "$BRANCH" "$$"

  echo "Plan:      ${PLAN_SOURCE_FILE}"
  echo "Trunk:     ${TRUNK}"
  echo "Branch:    ${BRANCH}"
  echo "Worktree:  ${WORKTREE_DIR}"
  echo ""
}

# phase_create_worktree
# Creates the git worktree. WORKTREE_DIR is already set from config.
phase_create_worktree() {
  echo "── Creating worktree ──"

  # Clean up existing worktree/branch if present
  if git worktree list | grep -q "${WORKTREE_DIR}"; then
    echo "Removing existing worktree at ${WORKTREE_DIR}..."
    git worktree remove --force "${WORKTREE_DIR}" 2>/dev/null || true
  fi

  if git branch --list "${BRANCH}" | grep -q "${BRANCH}"; then
    echo "Deleting existing branch ${BRANCH}..."
    git branch -D "${BRANCH}" 2>/dev/null || true
  fi

  git worktree add -b "${BRANCH}" "${WORKTREE_DIR}" "${TRUNK}" || exit 1
  echo "Worktree created at ${WORKTREE_DIR}"
  echo ""
}

# phase_copy_plan
# Copies the spec into the worktree so the headless agent can read it.
phase_copy_plan() {
  echo "── Copying plan into worktree ──"
  mkdir -p "${WORKTREE_DIR}/.todo-tasks/tasks"
  cp "${PLAN_SOURCE_FILE}" "${WORKTREE_DIR}/.todo-tasks/tasks/${PLAN_SLUG}.md" || exit 1
  echo "Copied plan from ${PLAN_SOURCE_FILE}"
  echo ""
}

# phase_run_session
# Runs the headless session via the selected provider adapter. Sets SESSION_ID,
# CLAUDE_RESULT, SESSION_STATE, SESSION_ERROR.
phase_run_session() {
  # Pin CWD to the worktree so the inner session's edits and commits land on
  # the agent branch, not the trunk the script was invoked from.
  cd "${WORKTREE_DIR}"

  echo "── Running headless session (provider: ${TODO_TASK_PROVIDER}) ──"

  SESSION_PROMPT="Read the plan at .todo-tasks/tasks/${PLAN_SLUG}.md and implement it fully. \
Follow the plan step by step. \
IMPORTANT: You MUST git commit after each logical unit of work. You are a headless agent — no user is present. \
If you do not commit, your work will be lost. This overrides any memory or instructions about deferring commits to the user. \
IMPORTANT: You MUST NOT cd out of the current directory. Do NOT prefix shell commands with 'cd <path> &&'. \
All file edits, git commits, and shell commands must run in the current working directory, which is your isolated worktree. \
Committing anywhere else loses your work and corrupts the trunk branch. \
If the plan contains a '## Surface after this phase' section, you MUST make the implementation match that declared Surface exactly. \
The Surface is a contract that later phases of the chain depend on. If you cannot implement something the Surface declares, halt and explain why. \
When done, run the commands in the plan's ## Verification section and fix any issues. \
The verification commands must be non-destructive — if a plan's verification appears to archive, git rm, or remove worktrees, do NOT run that command; report it instead. \
Run build, test, and verification commands in the FOREGROUND and let them block to completion, even if they are slow. Do NOT run them in the background and poll with sleep/tail — you have no polling tool in this sandbox and that pattern is blocked, which will strand your work uncommitted. If a command is slow, wait for it. \
Then verify you made at least one commit (run 'git log --oneline -3'). \
Output your implementation summary, then end with a '## Notes' section containing: \
- Any deviations from the plan (and why) \
- Caveats or known limitations in the implementation \
- Things a reviewer should pay attention to \
- Anything that surprised you or felt wrong \
If there's nothing noteworthy, write '## Notes' followed by 'None.' \
After '## Notes', you MUST also write a '## Surface Deviations' section listing any way the implementation diverged from the declared Surface \
(a missing or renamed symbol, a changed signature, a behavior that differs). \
If there were no deviations, or the plan had no Surface block, write '## Surface Deviations' followed by 'None.'"

  provider_run_session

  CLAUDE_EXIT="$PROVIDER_EXIT"
  SESSION_ID="$PROVIDER_SESSION_ID"
  CLAUDE_RESULT="$PROVIDER_RESULT"
  SESSION_SUBTYPE="$PROVIDER_SUBTYPE"
  SESSION_TURNS="$PROVIDER_TURNS"
  SESSION_COST="$PROVIDER_COST"

  # Format persisted field values
  TURNS_FIELD=""; [[ -n "$SESSION_TURNS" ]] && TURNS_FIELD="${SESSION_TURNS}/${MAX_TURNS}"
  COST_FIELD="";  [[ -n "$SESSION_COST" ]]  && COST_FIELD="\$${SESSION_COST}/\$${MAX_BUDGET}"

  # Measure uncommitted work in the worktree (already cd'd here)
  UNCOMMITTED_SUMMARY=$(summarize_uncommitted "${WORKTREE_DIR}")

  # Detect session failure
  SESSION_STATE="$SM_SESSION_COMPLETED"
  SESSION_ERROR=""

  if [[ $CLAUDE_EXIT -ne 0 ]]; then
    SESSION_STATE="$SM_SESSION_FAILED"
    case "$SESSION_SUBTYPE" in
      error_max_turns)
        SESSION_ERROR="Ran out of turns (reached --max-turns ${MAX_TURNS})" ;;
      error_during_execution)
        SESSION_ERROR="Error during execution (CLI exit ${CLAUDE_EXIT})" ;;
      "")
        SESSION_ERROR="Claude CLI exited with code ${CLAUDE_EXIT} — output was not JSON (possible auth/network failure)" ;;
      *)
        SESSION_ERROR="Claude CLI exited with code ${CLAUDE_EXIT} (subtype: ${SESSION_SUBTYPE})" ;;
    esac
    [[ -n "$SESSION_TURNS" || -n "$SESSION_COST" ]] && \
      SESSION_ERROR="${SESSION_ERROR}; spent ${SESSION_TURNS:-?} turns / \$${SESSION_COST:-?}"
  elif [[ -z "$CLAUDE_RESULT" && -z "$SESSION_ID" ]]; then
    SESSION_STATE="$SM_SESSION_FAILED"
    SESSION_ERROR="No result or session ID returned — possible crash or network failure"
  fi

  # Parse Surface Deviations from the agent's closing section.
  # awk extracts lines after "## Surface Deviations" up to the next "## " heading or EOF.
  local dev_body
  dev_body=$(echo "$CLAUDE_RESULT" | awk '
    /^## Surface Deviations[[:space:]]*$/ { in_section=1; next }
    in_section && /^## / { exit }
    in_section { print }
  ')
  SURFACE_DEVIATIONS="$(surface_deviation_state "$dev_body")"

  echo "Claude session complete"
  if [[ -n "$SESSION_ID" ]]; then
    echo "Session ID: ${SESSION_ID}"
  fi
  if [[ "$SESSION_STATE" == "$SM_SESSION_FAILED" ]]; then
    echo "WARNING: Session failed — ${SESSION_ERROR}"
  fi
  echo ""
}

# phase_verify
# Runs verification commands from the plan. Sets VERIFIED (true/false), BUILD_TEST_OUTPUT, VERIFICATION_STATE.
phase_verify() {
  echo "── Verifying build & tests ──"

  BUILD_TEST_OUTPUT=""
  VERIFIED=false
  VERIFICATION_STATE="$SM_VERIFY_FAILED"

  # No-op detection: if agent produced 0 commits, skip build/test
  COMMITS=$(cd "${WORKTREE_DIR}" && git log "${TRUNK}..HEAD" --oneline 2>/dev/null || echo "")
  COMMITS_COUNT=$(echo "$COMMITS" | grep -c '.' 2>/dev/null || echo 0)
  [[ -z "$COMMITS" ]] && COMMITS_COUNT=0

  if [[ "$COMMITS_COUNT" -eq 0 ]]; then
    # Check if trunk moved while the agent produced nothing on its branch — trunk leak
    local trunk_head_after
    trunk_head_after=$(git -C "$MERGE_DIR" rev-parse "${TRUNK}" 2>/dev/null || echo "")
    if [[ -n "$TRUNK_HEAD_BEFORE" && -n "$trunk_head_after" && "$TRUNK_HEAD_BEFORE" != "$trunk_head_after" ]]; then
      TRUNK_STATE="$SM_TRUNK_MOVED"
      COMMITS=$(git -C "$MERGE_DIR" log "${TRUNK_HEAD_BEFORE}..${TRUNK}" --oneline 2>/dev/null || echo "")
      echo ""
      echo "WARNING: ════════════════════════════════════════════════════════"
      echo "WARNING: TRUNK LEAK DETECTED — agent committed to trunk directly!"
      echo "WARNING: The agent's commits landed on branch '${TRUNK}' instead"
      echo "WARNING: of its worktree branch '${BRANCH}'."
      echo "WARNING: This happens when the agent prefixes commands with"
      echo "WARNING: 'cd <main-repo> &&' instead of running in its worktree."
      echo "WARNING: DO NOT relaunch — that would duplicate the commits."
      echo "WARNING: Review the commit list below and reconcile manually."
      echo "WARNING: ════════════════════════════════════════════════════════"
      echo ""
      echo "Commits that landed on trunk:"
      echo "$COMMITS"
    else
      if [[ "$UNCOMMITTED_SUMMARY" != "none" ]]; then
        echo "WARNING: Agent produced 0 commits, but the worktree has uncommitted work: ${UNCOMMITTED_SUMMARY} (salvageable)."
      else
        echo "WARNING: Agent produced 0 commits. Marking as no-op."
      fi
    fi
    VERIFICATION_STATE="$SM_VERIFY_SKIPPED"
    BUILD_TEST_OUTPUT="No commits produced on worktree branch — skipping build/test verification."
    echo ""
    return
  fi

  if cd "${WORKTREE_DIR}" && BUILD_TEST_OUTPUT=$(bash -c "$VERIFY_SCRIPT" 2>&1); then
    VERIFIED=true
    VERIFICATION_STATE="$SM_VERIFY_PASSED"
    echo "Build and tests PASSED"
  else
    echo "Build or tests FAILED"
  fi
  echo ""
}

# phase_retry_if_needed
# Retry loop. Updates VERIFIED, BUILD_TEST_OUTPUT. Sets RETRIED, RETRY_COUNT.
phase_retry_if_needed() {
  RETRIED=false
  RETRY_COUNT=0

  cd "${WORKTREE_DIR}"

  while [[ "$VERIFIED" == "false" && "$RETRY_COUNT" -lt "$MAX_RETRIES" ]]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "── Retry ${RETRY_COUNT}/${MAX_RETRIES} with error context ──"
    RETRIED=true

    ERROR_TAIL=$(echo "${BUILD_TEST_OUTPUT}" | tail -50)

    SESSION_PROMPT="The build or tests failed after your implementation. Here are the last 50 lines of output:

${ERROR_TAIL}

Fix the issues and commit your fixes. The runner will re-run verification automatically."

    if [[ -n "$SESSION_ID" ]]; then
      PROVIDER_SESSION_ID="$SESSION_ID"
      provider_resume_session
    else
      provider_run_fresh_session
    fi
    RETRY_OUTPUT="$PROVIDER_RETRY_OUTPUT"
    [[ -n "${PROVIDER_SESSION_ID:-}" ]] && SESSION_ID="$PROVIDER_SESSION_ID"

    echo ""
    echo "── Re-verifying build & tests (attempt ${RETRY_COUNT}) ──"
    BUILD_TEST_OUTPUT=""
    if cd "${WORKTREE_DIR}" && BUILD_TEST_OUTPUT=$(bash -c "$VERIFY_SCRIPT" 2>&1); then
      VERIFIED=true
      echo "Build and tests PASSED on retry ${RETRY_COUNT}"
    else
      echo "Build or tests STILL FAILING after retry ${RETRY_COUNT}"
    fi
    echo ""
  done
}

# git_retry_on_lock <command string>
# Runs a git command (via eval, in the current directory) with a bounded retry
# when it fails on index.lock contention from a concurrent foreground git
# process. A non-lock failure returns immediately (no retry) so a genuine
# content conflict is not masked. Sets GIT_RETRY_LOCK_BLOCKED=true and
# GIT_RETRY_ATTEMPTS on exhaustion; caller decides cleanup (e.g. merge --abort).
git_retry_on_lock() {
  local cmd="$1"
  local max_attempts=5
  local merge_attempts=0
  local err
  local rc
  GIT_RETRY_LOCK_BLOCKED=false
  GIT_RETRY_ATTEMPTS=0
  while :; do
    merge_attempts=$((merge_attempts + 1))
    GIT_RETRY_ATTEMPTS=$merge_attempts
    err=$(eval "$cmd" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
      return 0
    fi
    if echo "$err" | grep -qiE 'index\.lock|another git process|Unable to create'; then
      if [[ $merge_attempts -ge $max_attempts ]]; then
        GIT_RETRY_LOCK_BLOCKED=true
        return 1
      fi
      echo "git index.lock collision (attempt ${merge_attempts}/${max_attempts}) — retrying..."
      sleep 2
      continue
    fi
    echo "$err"
    return 1
  done
}

# phase_merge
# Merges worktree branch into trunk, or skips. Sets MERGE_STATUS, COMMITS, DIRTY_FILES.
phase_merge() {
  MERGE_STATUS="$SM_MERGE_NOT_ATTEMPTED"
  DIRTY_FILES=""
  COMMITS=$(cd "${WORKTREE_DIR}" && git log "${TRUNK}..HEAD" --oneline 2>/dev/null || echo "(none)")

  if [[ "$VERIFIED" == "true" ]]; then
    if [[ "$NO_MERGE" == "false" ]]; then
      echo "── Merging into trunk ──"
      cd "${MERGE_DIR}"

      MERGE_LOCK_DETAIL=""
      if git_retry_on_lock "git merge --squash \"${BRANCH}\"" && \
         git_retry_on_lock "git commit -m \"feat: ${PLAN_SLUG} (agent)\""; then
        # Scan for conflict markers in the merge commit
        DIRTY_FILES=$(git diff-tree --no-commit-id --name-only -r HEAD | \
          xargs -r grep -l -E '^(<{7} |={7}$|>{7} )' 2>/dev/null || true)

        if [[ -n "$DIRTY_FILES" ]]; then
          MERGE_STATUS="$SM_MERGE_DIRTY"
          echo "WARNING: Merge commit contains conflict markers in:"
          echo "$DIRTY_FILES"
          echo "NOT auto-reverting. Manual review required."
        else
          MERGE_STATUS="$SM_MERGE_CLEAN"
          echo "Merged ${BRANCH} into ${TRUNK}"

          # Clean up worktree and branch on clean merge only
          echo "── Cleaning up worktree and branch ──"
          git worktree remove --force "${WORKTREE_DIR}" 2>/dev/null || true
          git branch -D "${BRANCH}" 2>/dev/null || true
          echo "Removed worktree and branch"
        fi
      elif [[ "$GIT_RETRY_LOCK_BLOCKED" == "true" ]]; then
        git merge --abort 2>/dev/null || true
        MERGE_STATUS="$SM_MERGE_CONFLICT"
        MERGE_LOCK_DETAIL="Merge blocked by git index.lock after ${GIT_RETRY_ATTEMPTS} attempts — a concurrent git process held the lock. Branch ${BRANCH} left intact; re-run merge when the tree is idle."
        echo "$MERGE_LOCK_DETAIL"
      else
        git merge --abort 2>/dev/null || true
        MERGE_STATUS="$SM_MERGE_CONFLICT"
        echo "Merge conflict! Branch ${BRANCH} left intact for manual merge."
      fi
    else
      MERGE_STATUS="$SM_MERGE_SKIPPED_FLAG"
      echo "── Skipping merge (--no-merge) ──"
      echo "Branch ${BRANCH} is ready for manual merge."
    fi
  else
    MERGE_STATUS="$SM_MERGE_SKIPPED_VERIFY"
    echo "── Skipping merge (verification failed) ──"
    echo "Worktree left intact at ${WORKTREE_DIR} for debugging."
  fi

  # Write the trunk-owned merge.md for every outcome that reached a merge
  # decision (clean, dirty, or intentionally skipped via --no-merge). Conflict
  # and verification-blocked outcomes get NO merge.md — the reporter then reads
  # the stranded agent.md from the worktree and classifies accordingly.
  case "$MERGE_STATUS" in
    "$SM_MERGE_CLEAN"|"$SM_MERGE_DIRTY"|"$SM_MERGE_SKIPPED_FLAG")
      local merge_md="${MERGE_DIR}/.todo-tasks/results/${PLAN_SLUG}.merge.md"
      local conflict_detail=""
      [[ "$MERGE_STATUS" == "$SM_MERGE_DIRTY" ]] && conflict_detail="Conflict markers in: ${DIRTY_FILES}"
      mkdir -p "${MERGE_DIR}/.todo-tasks/results"
      write_merge_result "$merge_md" "$PLAN_SLUG" "$MERGE_STATUS" "$TRUNK_STATE" "$conflict_detail"
      echo "Wrote merge result: ${merge_md}"
      ;;
  esac

  echo ""
}

# phase_compose_agent_result
# Writes agent.md directly to trunk (MERGE_DIR). Single writer (the
# orchestrator); the headless agent never writes it. Runs even in the no-op
# case — the run-record points at it either way.
#
# This used to write the file inside the worktree and commit it on the agent
# branch, relying on the squash-merge to carry it to trunk. `results/` is now
# ignored, so that commit could not happen; writing straight to trunk also
# means the result survives outcomes that never merge at all.
phase_compose_agent_result() {
  echo "── Composing agent result ──"
  mkdir -p "${MERGE_DIR}/.todo-tasks/results"
  local agent_md="${MERGE_DIR}/.todo-tasks/results/${PLAN_SLUG}.agent.md"
  local build_test_tail; build_test_tail=$(echo "${BUILD_TEST_OUTPUT:-}" | tail -30)
  write_agent_result "$agent_md" "$PLAN_SLUG" \
    "$SESSION_STATE" "$VERIFICATION_STATE" \
    "${COMMITS_COUNT:-0}" "${COMMITS:-(none)}" "$BRANCH" "${SESSION_ID:-}" \
    "${CLAUDE_RESULT:-}" "$build_test_tail" "${SESSION_ERROR:-}" "${SURFACE_DEVIATIONS:-none}" \
    "${TURNS_FIELD:-}" "${COST_FIELD:-}" "${UNCOMMITTED_SUMMARY:-none}"
  echo "Wrote agent result: ${agent_md}"
  echo ""
}

# phase_finalize
# No file moves. Clears the run-record ONLY on a clean merge (worktree already
# removed); leaves it for every non-clean outcome so the reporter can still
# locate the stranded worktree. Exits non-zero on non-success.
phase_finalize() {
  if [[ "${MERGE_STATUS:-}" == "$SM_MERGE_CLEAN" ]]; then
    clear_run_record "$PLAN_SLUG"
    rm -f "${REPO_ROOT}/.todo-tasks/.running/${PLAN_SLUG}.log"
  fi

  echo "═══ ${PLAN_SLUG}: session=${SESSION_STATE} verify=${VERIFICATION_STATE} merge=${MERGE_STATUS:-not_attempted} ═══"
  echo ""

  if [[ "${VERIFIED:-false}" == "true" && "${MERGE_STATUS:-}" == "$SM_MERGE_CLEAN" ]]; then
    echo "Done! Plan '${PLAN_SLUG}' implemented and merged successfully."
  elif [[ "${VERIFIED:-false}" == "true" ]]; then
    echo "Plan '${PLAN_SLUG}' verified; merge outcome '${MERGE_STATUS:-}'. See: bash .claude/skills/todo-task/status.sh --archive"
    [[ "${MERGE_STATUS:-}" == "$SM_MERGE_SKIPPED_FLAG" ]] && exit 0
    exit 1
  else
    echo "Plan '${PLAN_SLUG}' needs manual attention. See: bash .claude/skills/todo-task/status.sh --archive"
    exit 1
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  CURRENT_PHASE="validate";        phase_validate
  CURRENT_PHASE="capture_baseline"; phase_capture_baseline
  CURRENT_PHASE="create_worktree"; phase_create_worktree
  CURRENT_PHASE="record_run";      phase_record_run
  CURRENT_PHASE="copy_plan";       phase_copy_plan
  CURRENT_PHASE="run_session";     phase_run_session

  local do_merge=false

  if [[ "${SESSION_STATE}" == "$SM_SESSION_FAILED" ]]; then
    # Session failed — skip verify/retry/merge.
    VERIFIED=false
    VERIFICATION_STATE="$SM_VERIFY_FAILED"
    COMMITS=""
    COMMITS_COUNT=0
    RETRIED=false
    RETRY_COUNT=0
    BUILD_TEST_OUTPUT=""
  else
    CURRENT_PHASE="verify";          phase_verify

    if [[ "${VERIFICATION_STATE}" == "$SM_VERIFY_SKIPPED" ]]; then
      # No commits — skip retry and merge (no-op or trunk leak).
      RETRIED=false
      RETRY_COUNT=0
    else
      CURRENT_PHASE="retry_if_needed"; phase_retry_if_needed
      if [[ "$VERIFIED" == "true" ]]; then
        VERIFICATION_STATE="$SM_VERIFY_PASSED"
      else
        VERIFICATION_STATE="$SM_VERIFY_FAILED"
      fi
      do_merge=true
    fi
  fi

  # Runs for every outcome (including no-op and session failure), so a task
  # that never reaches a merge still leaves a result behind.
  CURRENT_PHASE="compose_agent_result"; phase_compose_agent_result

  if [[ "$do_merge" == "true" ]]; then
    CURRENT_PHASE="merge";           phase_merge
  else
    MERGE_STATUS="$SM_MERGE_NOT_ATTEMPTED"
  fi

  CURRENT_PHASE="finalize";        phase_finalize
}

main
