#!/usr/bin/env bash
set -euo pipefail

# ─── Chain Executor ──────────────────────────────────────────────────────────
# Runs a sequence of plans in ONE shared worktree, committing each phase's code
# and result onto a single chain branch, then merging the whole chain to trunk
# once at the end (atomic all-or-nothing).
#
# Architecture:
#   real trunk (user's tree, may be dirty)
#     └── chain worktree (script-controlled, always clean)
#           └── task worktree (per phase, created/destroyed by execute-plan.sh)
#
# State is derived, not stored:
#   - Liveness lives in the gitignored run-record .running/chain-{name}.run
#     (worktree, branch, pid, ordered phases, optional waiting_for).
#   - Per-phase progress is derived by classifying each phase's result files in
#     the chain worktree (carried to trunk by the single final squash-merge).
#   - The chain definition chains/{name}.md is written to trunk ONLY on clean
#     completion. A failed/aborted chain leaves no definition — it is "live and
#     failed", located via its run-record.
#
# Usage: execute-chain.sh <chain-name> <plan1> <plan2> [plan3] ... [--after <slug>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
TODO="${REPO_ROOT}/.todo-tasks"

source "${SCRIPT_DIR}/lib.sh"
source_task_config

# ─── Parse Arguments ─────────────────────────────────────────────────────────

CHAIN_NAME=""
PHASES=()
AFTER=""
AFTER_NEXT=false
VALIDATE_ONLY=false

for arg in "$@"; do
  if [[ "$AFTER_NEXT" == "true" ]]; then
    AFTER="$arg"
    AFTER_NEXT=false
    continue
  fi
  case "$arg" in
    --after) AFTER_NEXT=true ;;
    --validate-only) VALIDATE_ONLY=true ;;
    *)
      if [[ -z "$CHAIN_NAME" ]]; then
        CHAIN_NAME="$arg"
      else
        PHASES+=("$arg")
      fi
      ;;
  esac
done

if [[ -z "$CHAIN_NAME" || ${#PHASES[@]} -lt 2 ]]; then
  echo "Usage: execute-chain.sh <chain-name> <plan1> <plan2> [plan3] ..."
  echo "  Requires at least 2 plans to form a chain."
  exit 1
fi

REAL_TRUNK="$(git branch --show-current)"

if [[ "$REAL_TRUNK" == *_claude* ]]; then
  echo "ERROR: Must run from trunk branch (current: ${REAL_TRUNK})"
  echo "Switch to a branch without '_claude' suffix first."
  exit 1
fi

CHAIN_BRANCH="chain-${CHAIN_NAME}"
CHAIN_WORKTREE="${REPO_ROOT}/../${WORKTREE_PREFIX}-${REPO_NAME}-chain-${CHAIN_NAME}"
CHAIN_RESULTS="${CHAIN_WORKTREE}/.todo-tasks/results"
RUN_FILE="$(run_record_path "$CHAIN_NAME" chain)"

PHASES_CSV="$(IFS=,; echo "${PHASES[*]}")"

# ─── Wait for predecessor (if --after was given) ─────────────────────────────
# Resume/liveness is derived from the reporter; we poll its task records for the
# predecessor reaching phase=done with overall=success.

if [[ -n "${AFTER}" ]]; then
  echo "Waiting for predecessor '${AFTER}' to complete and merge..."

  while true; do
    pred_rec="$(bash "${SCRIPT_DIR}/report.sh" task | awk -F'\t' -v s="$AFTER" '$2==s {print $3"\t"$4}')"
    pred_phase="$(echo "$pred_rec" | cut -f1)"
    pred_overall="$(echo "$pred_rec" | cut -f2)"

    if [[ "$pred_phase" == "done" && "$pred_overall" == "$SM_OVERALL_SUCCESS" ]]; then
      echo "Predecessor '${AFTER}' succeeded. Proceeding with chain..."
      break
    elif [[ "$pred_phase" == "done" || "$pred_phase" == "crashed" ]]; then
      echo "ERROR: Predecessor '${AFTER}' did not succeed (phase: ${pred_phase}, state: ${pred_overall}). Aborting chain."
      exit 1
    fi
    sleep 15
  done
fi

# ─── Guard: dirty tree check (once, at chain start) ─────────────────────────

# `.todo-tasks/` is excluded — orchestrator-managed; phase specs are committed
# below before the chain worktree is cut.
if ! git diff --quiet -- . ':(exclude).todo-tasks' \
   || ! git diff --cached --quiet -- . ':(exclude).todo-tasks' \
   || [[ -n "$(git ls-files --others --exclude-standard -- . ':(exclude).todo-tasks')" ]]; then
  echo "ERROR: Working tree has uncommitted changes (outside .todo-tasks/)."
  echo ""
  echo "The chain creates a worktree from HEAD. Uncommitted changes won't"
  echo "be included and may cause conflicts when merging back."
  echo ""
  echo "Commit or stash your changes first, then re-launch."
  exit 1
fi

# ─── Validate All Plans Exist ────────────────────────────────────────────────

echo "═══ Chain Executor: ${CHAIN_NAME} ═══"
echo ""
echo "Phases: ${PHASES[*]}"
echo "Chain branch: ${CHAIN_BRANCH}"
echo "Chain worktree: ${CHAIN_WORKTREE}"
echo ""

for slug in "${PHASES[@]}"; do
  if [[ ! -f "${TODO}/tasks/${slug}.md" ]]; then
    echo "ERROR: Plan '${slug}' not found at .todo-tasks/tasks/${slug}.md"
    exit 1
  fi
done

if [[ "$VALIDATE_ONLY" == "true" ]]; then
  echo "Validation passed."
  exit 0
fi


# ─── Create Chain Worktree ──────────────────────────────────────────────────

RESUME_CHAIN=false
if git worktree list | grep -q "${CHAIN_WORKTREE}" && [[ -d "${CHAIN_RESULTS}" ]]; then
  for slug in "${PHASES[@]}"; do
    if [[ "$(classify_task "${CHAIN_RESULTS}/${slug}.agent.md" "${CHAIN_RESULTS}/${slug}.merge.md")" == "$SM_OVERALL_SUCCESS" ]]; then
      RESUME_CHAIN=true
      break
    fi
  done
fi

echo "── Creating chain worktree ──"

if [[ "$RESUME_CHAIN" == "true" ]]; then
  echo "Existing chain worktree has completed phases — resuming and preserving work."
  echo "Chain worktree: ${CHAIN_WORKTREE}"
  echo ""
else
  if git worktree list | grep -q "${CHAIN_WORKTREE}"; then
    echo "Removing existing chain worktree..."
    git worktree remove --force "${CHAIN_WORKTREE}" 2>/dev/null || true
  fi

  if git branch --list "${CHAIN_BRANCH}" | grep -q "${CHAIN_BRANCH}"; then
    echo "Deleting existing chain branch..."
    git branch -D "${CHAIN_BRANCH}" 2>/dev/null || true
  fi

  git worktree add -b "${CHAIN_BRANCH}" "${CHAIN_WORKTREE}" "${REAL_TRUNK}"
  echo "Chain worktree created at ${CHAIN_WORKTREE}"
  echo ""
fi

# ─── Copy Phase Specs into the Chain Worktree ────────────────────────────────
# From phase 2 on, execute-plan.sh is launched with the chain worktree as its
# CWD, so its own `git rev-parse --show-toplevel` resolves there and it looks
# for the spec under the chain worktree rather than the real trunk. The specs
# are ignored and so absent from a fresh worktree — copy them in.
#
# This replaces committing the specs to trunk, which is how they used to reach
# the chain worktree and which cost trunk a commit per chain.

echo "── Copying ${#PHASES[@]} phase spec(s) into chain worktree ──"
mkdir -p "${CHAIN_WORKTREE}/.todo-tasks/tasks"
for slug in "${PHASES[@]}"; do
  src="${TODO}/tasks/${slug}.md"
  [[ -f "$src" ]] && cp "$src" "${CHAIN_WORKTREE}/.todo-tasks/tasks/${slug}.md"
done
echo ""

# ─── Write Chain Run-record ──────────────────────────────────────────────────

write_run_record "$CHAIN_NAME" "$CHAIN_WORKTREE" "$CHAIN_BRANCH" "$$" chain
{
  echo "phases: ${PHASES_CSV}"
  [[ -n "$AFTER" ]] && echo "waiting_for: ${AFTER}"
} >> "$RUN_FILE"

echo "Run-record: ${RUN_FILE}"
echo ""

# ─── Execute Phases ──────────────────────────────────────────────────────────

for i in "${!PHASES[@]}"; do
  slug="${PHASES[$i]}"
  phase_num=$((i + 1))
  total=${#PHASES[@]}

  echo "── Phase ${phase_num}/${total}: ${slug} ──"

  # Resume: skip a phase whose result already classifies success in the chain
  # worktree (supports re-running a partially completed chain).
  if [[ "$(classify_task "${CHAIN_RESULTS}/${slug}.agent.md" "${CHAIN_RESULTS}/${slug}.merge.md")" == "$SM_OVERALL_SUCCESS" ]]; then
    echo "Already completed successfully, skipping."
    echo ""
    continue
  fi

  # Launch this phase — execute-plan merges into the chain worktree, not trunk.
  echo "Launching execute-plan.sh ${slug} (trunk: chain worktree)..."

  if bash "${SCRIPT_DIR}/execute-plan.sh" "${slug}" \
       --trunk-dir "${CHAIN_WORKTREE}" \
       --trunk-branch "${CHAIN_BRANCH}" \
       --no-guard; then
    echo "Phase ${slug} succeeded."
  elif [[ "$(classify_task "${CHAIN_RESULTS}/${slug}.agent.md" "${CHAIN_RESULTS}/${slug}.merge.md")" == "$SM_OVERALL_SUCCESS" ]]; then
    echo "Phase ${slug} exited non-zero but its result files classify success"
    echo "(merged cleanly into the chain branch). Treating phase as succeeded and continuing."
  else
    echo "Phase ${slug} failed. Stopping chain."
    echo ""
    echo "═══ Chain ${CHAIN_NAME} stopped at phase ${phase_num}/${total} ═══"
    echo "Failed phase: ${slug}"
    echo "Remaining: ${PHASES[*]:$((i+1))}"
    # Leave the run-record in place: the chain is "live and failed", located
    # via its run-record. Do NOT write the chain definition to trunk.
    exit 1
  fi

  # ── Pull trunk commits into chain worktree ──────────────────────────────
  echo "── Syncing trunk into chain worktree ──"
  cd "${CHAIN_WORKTREE}"

  if ! git merge "${REAL_TRUNK}" -m "chain: sync trunk into ${CHAIN_BRANCH} after ${slug}"; then
    echo "Merge conflict pulling trunk changes into chain worktree."
    echo "Attempting auto-resolution with Claude..."

    unset CLAUDECODE 2>/dev/null || true

    CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")
    RESOLVE_PROMPT="You are in a git worktree. There are merge conflicts after merging trunk into the chain branch.
Conflicted files: ${CONFLICT_FILES}

Resolve all merge conflicts. For each file, read it, understand both sides, pick the correct resolution.
Then stage the resolved files with 'git add' and commit with 'git commit --no-edit'.
Do NOT abort the merge."

    if claude -p \
      --allowedTools "Read,Write,Edit,Glob,Grep,Bash" \
      --permission-mode bypassPermissions \
      --output-format text \
      --max-turns 20 \
      --model sonnet \
      --max-budget-usd "1.00" \
      "${RESOLVE_PROMPT}" 2>&1; then
      echo "Trunk sync resolved."
    else
      echo "WARNING: Failed to auto-resolve trunk sync. Chain continuing with unmerged trunk changes."
      git merge --abort 2>/dev/null || true
    fi
  else
    echo "Trunk synced (no conflicts)."
  fi

  cd "${REPO_ROOT}"
  echo ""
done

# ─── Merge Chain Branch into Trunk ──────────────────────────────────────────

echo "── Merging chain into trunk ──"

cd "${CHAIN_WORKTREE}"
# Final sync: merge trunk into chain one more time before merging back
if ! git merge "${REAL_TRUNK}" -m "chain: final trunk sync before merge" 2>/dev/null; then
  unset CLAUDECODE 2>/dev/null || true
  CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")
  RESOLVE_PROMPT="Resolve all merge conflicts. Conflicted files: ${CONFLICT_FILES}
Read each file, resolve correctly, git add, and git commit --no-edit."

  claude -p \
    --allowedTools "Read,Write,Edit,Glob,Grep,Bash" \
    --permission-mode bypassPermissions \
    --output-format text \
    --max-turns 20 \
    --model sonnet \
    --max-budget-usd "1.00" \
    "${RESOLVE_PROMPT}" 2>&1 || true
fi
cd "${REPO_ROOT}"

MERGE_STATUS="failed"

# Compute files changed by this chain (pathspec for commit + breadcrumb).
mapfile -t CHAIN_PATHS < <(git diff --name-only "${REAL_TRUNK}...${CHAIN_BRANCH}" 2>/dev/null || true)

# Post-success: write chain definition, clean up worktree/branch/run-record.
do_post_merge_success() {
  local chain_def="${TODO}/chains/${CHAIN_NAME}.md"
  write_chain_definition "$chain_def" "$CHAIN_NAME" "$PHASES_CSV" "$AFTER"
  echo "Wrote chain definition: ${chain_def}"

  echo "── Cleaning up chain worktree ──"
  git worktree remove --force "${CHAIN_WORKTREE}" 2>/dev/null || true
  git branch -D "${CHAIN_BRANCH}" 2>/dev/null || true
  clear_run_record "$CHAIN_NAME" chain
  rm -f "${TODO}/.running/chain-${CHAIN_NAME}.log"
  echo "Removed chain worktree, branch, and run-record"
}

# Probe for content conflicts without touching the working tree (git ≥ 2.38).
_probe_exit=0
_probe_out="$(git merge-tree --write-tree "${REAL_TRUNK}" "${CHAIN_BRANCH}" 2>&1)" || _probe_exit=$?

if [[ "$_probe_exit" -ne 0 ]]; then
  if echo "$_probe_out" | grep -qi "unknown option\|unrecognized\|invalid option"; then
    # git < 2.38: --write-tree unsupported. Fall through to real merge.
    _probe_exit=0
  else
    # Genuine content conflict against committed trunk.
    MERGE_STATUS="${SM_CHAIN_CONFLICT}"
    echo "merge_state: ${MERGE_STATUS}" >> "$(run_record_path "${CHAIN_NAME}" chain)"
    write_chain_merge_note \
      "${CHAIN_WORKTREE}/.todo-tasks/results" \
      "${CHAIN_NAME}" "${CHAIN_BRANCH}" "${MERGE_STATUS}" \
      "$(printf '%s\n' "${CHAIN_PATHS[@]}")" \
      "${#CHAIN_PATHS[@]} files changed across ${#PHASES[@]} phases"
    echo "Content conflict merging ${CHAIN_BRANCH} into ${REAL_TRUNK}."
    echo "Chain branch and worktree left intact. Resolve then:"
    echo "  git merge --squash ${CHAIN_BRANCH} && git commit -m 'feat: chain-${CHAIN_NAME} (agent)'"
    echo "After completing the merge, finalize: bash .claude/skills/todo-task/finalize-chain.sh ${CHAIN_NAME}"
    echo ""
    echo "See: ${CHAIN_WORKTREE}/.todo-tasks/results/${CHAIN_NAME}.conflict.md"
    exit 1
  fi
fi

# Attempt the real merge (probe confirmed clean, or probe unavailable).
if git merge --squash "${CHAIN_BRANCH}"; then
  if [[ ${#CHAIN_PATHS[@]} -gt 0 ]]; then
    git commit -m "feat: chain-${CHAIN_NAME} (agent)" -- "${CHAIN_PATHS[@]}"
  else
    git commit -m "feat: chain-${CHAIN_NAME} (agent)"
  fi
  MERGE_STATUS="success"
  echo "Chain merged into ${REAL_TRUNK}"
  do_post_merge_success
else
  # Merge refused — a chain-touched file is uncommitted-dirty in the working tree.
  # Git makes no changes on refusal; nothing to abort or reset.
  MERGE_STATUS="${SM_CHAIN_AWAITING_MERGE}"
  _dirty_paths="$(git status --porcelain 2>/dev/null | sed 's/^...//' | sed 's/^ *//' || true)"
  _overlap=""
  for _cp in "${CHAIN_PATHS[@]}"; do
    if echo "$_dirty_paths" | grep -qF "$_cp" 2>/dev/null; then
      _overlap="${_overlap}${_cp}"$'\n'
    fi
  done
  echo "merge_state: ${MERGE_STATUS}" >> "$(run_record_path "${CHAIN_NAME}" chain)"
  write_chain_merge_note \
    "${CHAIN_WORKTREE}/.todo-tasks/results" \
    "${CHAIN_NAME}" "${CHAIN_BRANCH}" "${MERGE_STATUS}" \
    "${_overlap%$'\n'}" \
    "${#CHAIN_PATHS[@]} files changed across ${#PHASES[@]} phases"
  echo "Merge deferred — a chain-touched file is uncommitted in the working tree."
  echo "Commit or stash the overlapping change, then:"
  echo "  git merge --squash ${CHAIN_BRANCH} && git commit -m 'feat: chain-${CHAIN_NAME} (agent)'"
  echo "After completing the merge, finalize: bash .claude/skills/todo-task/finalize-chain.sh ${CHAIN_NAME}"
  echo ""
  echo "See: ${CHAIN_WORKTREE}/.todo-tasks/results/${CHAIN_NAME}.conflict.md"
  exit 1
fi

# ─── Chain Complete ──────────────────────────────────────────────────────────

echo ""
echo "═══ Chain ${CHAIN_NAME} complete! All ${#PHASES[@]} phases succeeded. ═══"
echo "Completed: ${PHASES[*]}"
echo "Merge: ${MERGE_STATUS}"
