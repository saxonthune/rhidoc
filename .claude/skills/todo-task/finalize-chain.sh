#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
TODO="${REPO_ROOT}/.todo-tasks"
source "${SCRIPT_DIR}/lib.sh"

name="${1:-}"
if [[ -z "$name" ]]; then
  echo "Usage: finalize-chain.sh <chain-name>"
  exit 1
fi

run="${TODO}/.running/chain-${name}.run"

if [[ ! -f "$run" ]]; then
  echo "No run-record for chain '${name}' (already finalized?)"
  exit 0
fi

if run_is_alive "$run"; then
  echo "Chain '${name}' is still running."
  exit 1
fi

phases="$(read_run_field "$run" phases)"
worktree="$(read_run_field "$run" worktree)"
branch="$(read_run_field "$run" branch)"
after="$(read_run_field "$run" waiting_for)"

if ! chain_merged_on_trunk "$REPO_ROOT" "$branch"; then
  echo "Chain '${name}' does not appear merged on trunk (trunk still differs from ${branch})."
  echo "Merge it first, then re-run finalize-chain:"
  echo "  git merge --squash ${branch} && git commit -m 'feat: chain-${name} (agent)'"
  exit 1
fi

write_chain_definition "${TODO}/chains/${name}.md" "$name" "$phases" "$after"

[[ -n "$worktree" && -d "$worktree" ]] && git worktree remove --force "$worktree" 2>/dev/null || true
[[ -n "$branch" ]] && git branch -D "$branch" 2>/dev/null || true

clear_run_record "$name" chain
rm -f "${TODO}/.running/chain-${name}.log"

echo "Finalized chain '${name}' — definition written, worktree/branch/run-record cleared. Run /todo-task status; archive.sh will sweep it as complete."
