#!/usr/bin/env bash
set -uo pipefail

# ─── Archive ─────────────────────────────────────────────────────────────────
# The ONLY component that removes files: a physical copy lands in .archived/,
# then the active spec and results are deleted. Every path involved is ignored,
# so no commit is made. Serial, single-writer, conflict-free.
#
# Usage:
#   archive.sh                 archive every auto-eligible outcome
#   archive.sh <slug> [...]    archive specific task slug(s)
#   archive.sh --force-failed  also archive failures (build/session/no-op/leak)
#   archive.sh --merged <slug> archive slug(s) the operator merged/resolved by hand
#                               (bypasses outcome eligibility, e.g. salvageable;
#                               still skips a slug that is still running; requires
#                               at least one explicit slug — never a sweep)
#
# Auto-eligibility (per outcome):
#   success                              → yes
#   chain complete                       → yes (definition + member files)
#   ready_for_review (--no-merge)        → no (awaiting human merge)
#   merge_conflict / merged_with_markers → no (keep worktree for resolution)
#   build_failure/session_failed/no_op/  → no; only with --force-failed
#     trunk_leak / chain failed
#
# An explicit `archive.sh <slug>` also archives a legacy root-level
# `.todo-tasks/<slug>.md` (a task filed before the tasks/ subdirectory existed),
# always as a success disposition. The unscoped sweep never picks these up.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
TODO="${REPO_ROOT}/.todo-tasks"
source "${SCRIPT_DIR}/lib.sh"

TS="$(date +%Y%m%d)"
FORCE_FAILED=false
MERGED=false
SLUGS=()
for arg in "$@"; do
  case "$arg" in
    --force-failed) FORCE_FAILED=true ;;
    --merged) MERGED=true ;;
    -*) echo "Unknown option: $arg"; exit 1 ;;
    *) SLUGS+=("$arg") ;;
  esac
done

if [[ "$MERGED" == "true" && ${#SLUGS[@]} -eq 0 ]]; then
  echo "Usage: archive.sh --merged <slug> [...] — --merged requires explicit slug(s), it is never a sweep"
  exit 1
fi

# force_eligible <overall> — failures that --force-failed will archive.
# Note: SM_OVERALL_SALVAGEABLE is intentionally absent — never auto-rm a worktree
# that holds recoverable uncommitted work. Resolve it by hand.
force_eligible() {
  case "$1" in
    "$SM_OVERALL_BUILD_FAIL"|"$SM_OVERALL_SESSION_FAIL"|"$SM_OVERALL_NOOP"|"$SM_OVERALL_TRUNK_LEAK") return 0 ;;
    *) return 1 ;;
  esac
}

# archive_one <slug> <disposition>   disposition ∈ {success, abandoned}
archive_one() {
  local slug="$1" disposition="${2:-$SM_OVERALL_SUCCESS}"
  mkdir -p "${TODO}/.archived"

  local run="${TODO}/.running/${slug}.run" wt="" br=""
  if [[ -f "$run" ]]; then
    wt="$(read_run_field "$run" worktree)"
    br="$(read_run_field "$run" branch)"
  fi

  # Copy the trunk-side lifecycle files into the archive.
  [[ -f "${TODO}/tasks/${slug}.md" ]]           && cp "${TODO}/tasks/${slug}.md"           "${TODO}/.archived/${TS}-${slug}.md"
  [[ -f "${TODO}/results/${slug}.agent.md" ]]   && cp "${TODO}/results/${slug}.agent.md"   "${TODO}/.archived/${TS}-${slug}.agent.md"
  [[ -f "${TODO}/results/${slug}.merge.md" ]]   && cp "${TODO}/results/${slug}.merge.md"   "${TODO}/.archived/${TS}-${slug}.merge.md"
  # Capture a stranded agent.md that never reached trunk (lives in the worktree).
  if [[ ! -f "${TODO}/results/${slug}.agent.md" && -n "$wt" && -f "${wt}/.todo-tasks/results/${slug}.agent.md" ]]; then
    cp "${wt}/.todo-tasks/results/${slug}.agent.md" "${TODO}/.archived/${TS}-${slug}.agent.md"
  fi

  # Plain rm — these paths are ignored, so there is nothing to stage and no
  # archive commit to make. The copies above are the durable record.
  rm -f "${TODO}/tasks/${slug}.md" \
        "${TODO}/results/${slug}.agent.md" \
        "${TODO}/results/${slug}.merge.md"

  printf '%s\n' "$disposition" > "${TODO}/.archived/${TS}-${slug}.disposition"

  clear_run_record "$slug"
  [[ -n "$wt" && -d "$wt" ]] && git worktree remove --force "$wt" 2>/dev/null || true
  [[ -n "$br" ]] && git branch -D "$br" 2>/dev/null || true

  echo "- Archived ${slug}"
}

# archive_legacy_root <slug> — archive a task filed at the legacy root location
# .todo-tasks/<slug>.md (pre-dates the tasks/ subdirectory). No run-record,
# worktree, results, or branch exist for these, so skip archive_one's cleanup.
archive_legacy_root() {
  local slug="$1"
  mkdir -p "${TODO}/.archived"
  cp "${TODO}/${slug}.md" "${TODO}/.archived/${TS}-${slug}.md"
  printf '%s\n' "$SM_OVERALL_SUCCESS" > "${TODO}/.archived/${TS}-${slug}.disposition"
  rm -f "${TODO}/${slug}.md"
  echo "- Archived ${slug} (legacy root-level task)"
}

# archive_chain <name> — archive a completed chain's definition AND its member
# specs. A chain keeps every phase's results in its shared worktree, which is
# removed at merge, so each member's trunk-side tasks/{slug}.md never gains a
# results/ file and would otherwise linger as a false "pending" after the chain
# merges. Sweep the members (as success) so a completed chain leaves nothing behind.
archive_chain() {
  local name="$1"
  mkdir -p "${TODO}/.archived"
  local def="${TODO}/chains/${name}.md" phases=""
  [[ -f "$def" ]] && phases="$(parse_result_field "$def" phases)"
  [[ -f "$def" ]] && cp "$def" "${TODO}/.archived/${TS}-chain-${name}.md"
  rm -f "$def"
  printf '%s\n' "$SM_OVERALL_SUCCESS" > "${TODO}/.archived/${TS}-chain-${name}.disposition"
  echo "- Archived chain ${name}"

  local slug
  for slug in ${phases//,/ }; do
    [[ -f "${TODO}/tasks/${slug}.md" ]] && archive_one "$slug" "$SM_OVERALL_SUCCESS"
  done
}

archived=0

if [[ ${#SLUGS[@]} -gt 0 ]]; then
  # Explicit slug(s).
  for slug in "${SLUGS[@]}"; do
    rec="$(bash "${SCRIPT_DIR}/report.sh" task | awk -F'\t' -v s="$slug" '$2==s{print $3"\t"$4}')"
    if [[ -z "$rec" ]]; then
      if [[ -f "${TODO}/${slug}.md" ]]; then
        archive_legacy_root "$slug"; archived=$((archived+1)); continue
      fi
      echo "- Skipped ${slug} (no such task)"; continue
    fi
    phase="$(echo "$rec" | cut -f1)"; overall="$(echo "$rec" | cut -f2)"
    if [[ "$phase" == "running" ]]; then
      echo "- Skipped ${slug} (still running)"; continue
    fi
    if [[ "$MERGED" == "true" ]]; then
      echo "- Archiving ${slug} (operator asserts merged to trunk)"
      archive_one "$slug" "$SM_OVERALL_SUCCESS"; archived=$((archived+1)); continue
    fi
    if [[ "$overall" == "$SM_OVERALL_SUCCESS" ]] || { [[ "$FORCE_FAILED" == "true" ]] && force_eligible "$overall"; }; then
      disp="$SM_OVERALL_SUCCESS"
      [[ "$overall" != "$SM_OVERALL_SUCCESS" ]] && disp="$SM_ARCHIVE_ABANDONED"
      archive_one "$slug" "$disp"; archived=$((archived+1))
    else
      echo "- Skipped ${slug} (${overall}) — pass --force-failed to archive failures, or merge/resolve manually"
    fi
  done
else
  # Refuse the unscoped sweep inside a todotask agent worktree: it would delete
  # sibling tasks' specs and results out from under a run still using them.
  # Explicit `archive.sh <slug>` / `--merged` remain allowed.
  current_branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [[ "$current_branch" == *_claude* ]]; then
    echo "- Refusing sweep: running inside a todotask agent worktree (branch ${current_branch})."
    echo "  The unscoped sweep archives sibling tasks. Run archive from trunk, or name a slug."
    exit 0
  fi
  # Sweep: every auto-eligible outcome.
  while IFS=$'\t' read -r _ slug phase overall _bucket _commits _wt _br _age _notes; do
    [[ "$phase" == "done" || "$phase" == "crashed" ]] || continue
    if [[ "$overall" == "$SM_OVERALL_SUCCESS" ]] || { [[ "$FORCE_FAILED" == "true" ]] && force_eligible "$overall"; }; then
      disp="$SM_OVERALL_SUCCESS"
      [[ "$overall" != "$SM_OVERALL_SUCCESS" ]] && disp="$SM_ARCHIVE_ABANDONED"
      archive_one "$slug" "$disp"; archived=$((archived+1))
    fi
  done < <(bash "${SCRIPT_DIR}/report.sh" task)

  # Completed chains: archive the definition (members archived above as success).
  while IFS=$'\t' read -r _ name cstatus _rest; do
    [[ "$cstatus" == "complete" ]] && { archive_chain "$name"; archived=$((archived+1)); }
  done < <(bash "${SCRIPT_DIR}/report.sh" chain)
fi

if [[ $archived -eq 0 ]]; then
  echo "- Nothing to archive."
fi
exit 0
