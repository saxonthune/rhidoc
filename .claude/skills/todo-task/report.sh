#!/usr/bin/env bash
set -uo pipefail

# ─── Reporter ─────────────────────────────────────────────────────────────────
# The ONE component that walks the filesystem and classifies state. Every other
# script (status.sh, monitor.sh, list-pending.sh) is a pure renderer that
# consumes this output and never touches the filesystem or parses formats.
#
# Output: TSV, one record per line. The first column is the record type; each
# renderer splits on it. Schemas (tab-separated):
#
#   task     <slug> <phase> <overall> <bucket> <commits> <worktree> <branch> <age> <notes>
#   chain    <name> <status> <done_n> <total> <current> <phases_csv> <worktree> <branch> <progress> <age>
#   epic     <name> <total> <done_n> <running_n> <failed_n> <members_csv>
#   stale    <slug> <worktree>
#   archived <slug> <overall> <commits> <age> <notes>
#
#   phase   ∈ {pending, running, crashed, done}
#   status  ∈ {running, waiting, awaiting-merge, conflict, finalizable, complete, failed}
#   age     is seconds since the relevant file was last touched
#
# This script is strictly read-only. Usage:
#   report.sh            — emit all live record types (task|chain|epic|stale)
#   report.sh task       — emit only task records (similarly chain|epic|stale)
#   report.sh archived   — emit archived records (NOT included in the default
#                          `all` output, since walking .archived/ is costly and
#                          only the monitor consumes it)

REPO_ROOT="$(git rev-parse --show-toplevel)"
TODO="${REPO_ROOT}/.todo-tasks"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source_task_config

shopt -s nullglob

WANT="${1:-all}"
NONE="-"
NOW="$(date +%s)"

mtime() { stat -c %Y "$1" 2>/dev/null || echo "$NOW"; }
age_of() { echo "$(( NOW - $(mtime "$1") ))"; }

# resolve_agent_md <slug> <run_file>
# Echoes the path to the slug's agent.md, preferring trunk, then the worktree
# named in the run-record (the stranded-result fix). Empty if not found.
resolve_agent_md() {
  local slug="$1" run_file="$2"
  local trunk_a="${TODO}/results/${slug}.agent.md"
  if [[ -f "$trunk_a" ]]; then
    echo "$trunk_a"; return
  fi
  if [[ -n "$run_file" && -f "$run_file" ]]; then
    local wt; wt="$(read_run_field "$run_file" worktree)"
    local wt_a="${wt}/.todo-tasks/results/${slug}.agent.md"
    [[ -n "$wt" && -f "$wt_a" ]] && echo "$wt_a"
  fi
}

# classify_slug <slug>
# Runs the per-task ladder (contracts §Reporter algorithm) and echoes a
# pipe-delimited record: phase|overall|bucket|commits|worktree|branch|age|notes
# Shared by task records and epic rollups.
classify_slug() {
  local slug="$1"
  local spec="${TODO}/tasks/${slug}.md"
  local merge_md="${TODO}/results/${slug}.merge.md"
  local run_file="${TODO}/.running/${slug}.run"
  [[ -f "$run_file" ]] || run_file=""

  local agent_md; agent_md="$(resolve_agent_md "$slug" "$run_file")"

  local phase overall bucket commits worktree branch age notes
  overall="$NONE"; bucket="$NONE"; commits="$NONE"
  worktree="$NONE"; branch="$NONE"; notes=""

  if [[ -n "$run_file" ]]; then
    worktree="$(read_run_field "$run_file" worktree)"; worktree="${worktree:-$NONE}"
    branch="$(read_run_field "$run_file" branch)"; branch="${branch:-$NONE}"
  fi

  if [[ -f "$merge_md" && -n "$agent_md" ]]; then
    # Rule 2: agent.md + merge.md present → done.
    phase="done"
    overall="$(classify_task "$agent_md" "$merge_md")"
    bucket="$(state_bucket "$overall")"
    age="$(age_of "$agent_md")"
  elif [[ -n "$run_file" ]] && run_is_alive "$run_file"; then
    # Rule 3: run-record + live PID → running. Prefer .log mtime (last activity) over run-record mtime.
    phase="running"
    local logf="${TODO}/.running/${slug}.log"
    if [[ -f "$logf" ]]; then age="$(age_of "$logf")"; else age="$(age_of "$run_file")"; fi
  elif [[ -n "$run_file" && ! -f "$merge_md" ]]; then
    # Rule 4: run-record + dead PID + no merge.md → crashed.
    phase="crashed"
    overall="$(classify_task "$agent_md" "")"
    # A stranded run that passed verification but never merged is a merge
    # conflict, not a build failure — relabel so attention surfaces correctly.
    if [[ "$overall" == "$SM_OVERALL_BUILD_FAIL" && -n "$agent_md" ]]; then
      local v; v="$(parse_result_field "$agent_md" verification)"
      [[ "$v" == "$SM_VERIFY_PASSED" ]] && overall="$SM_OVERALL_CONFLICT"
    fi
    bucket="$(state_bucket "$overall")"
    age="$(age_of "$run_file")"
  elif [[ -f "$spec" ]]; then
    # Rule 5: spec present (triaged) → pending.
    phase="pending"
    age="$(age_of "$spec")"
  else
    # Rule 6: draft only (gitignored inbox, untriaged) → draft.
    phase="draft"
    age="$(age_of "${TODO}/inbox/${slug}.md")"
  fi

  # Commits + notes come from the agent.md when we have one.
  if [[ -n "$agent_md" ]]; then
    commits="$(parse_result_field "$agent_md" commits)"; commits="${commits:-0}"
    local dev err unc
    dev="$(parse_result_field "$agent_md" "surface deviations")"
    err="$(parse_result_field "$agent_md" error)"
    unc="$(parse_result_field "$agent_md" uncommitted)"
    [[ "$dev" == "declared" ]] && notes="surface deviations declared — re-triage downstream. "
    [[ -n "$unc" && "$unc" != "none" && "$unc" != "0" ]] && \
      notes="${notes}${unc} uncommitted in worktree (salvageable). "
    [[ -n "$err" ]] && notes="${notes}${err}"
  fi
  [[ -z "$notes" ]] && notes="$NONE"
  # Strip any stray tabs/newlines from notes to keep TSV intact.
  notes="${notes//$'\t'/ }"; notes="${notes//$'\n'/ }"

  echo "${phase}|${overall}|${bucket}|${commits}|${worktree}|${branch}|${age}|${notes}"
}

# ─── Task records ──────────────────────────────────────────────────────────
emit_task_record() {
  local slug="$1" rec
  rec="$(classify_slug "$slug")"
  local phase overall bucket commits worktree branch age notes
  IFS='|' read -r phase overall bucket commits worktree branch age notes <<< "$rec"
  printf 'task\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$slug" "$phase" "$overall" "$bucket" "$commits" "$worktree" "$branch" "$age" "$notes"
}

emit_tasks() {
  declare -A seen=()
  local spec draft slug
  # Triaged specs (tracked) — pending / running / crashed / done.
  for spec in "$TODO"/tasks/*.md; do
    slug="$(basename "$spec" .md)"
    seen[$slug]=1
    emit_task_record "$slug"
  done
  # Untriaged drafts (gitignored inbox) not yet promoted to a spec.
  for draft in "$TODO"/inbox/*.md; do
    slug="$(basename "$draft" .md)"
    [[ -n "${seen[$slug]:-}" ]] && continue
    emit_task_record "$slug"
  done
}

# ─── Chain records ─────────────────────────────────────────────────────────
# phase_success <results_dir> <phase_slug> — true if that phase classifies success.
phase_success() {
  local dir="$1" p="$2"
  local a="${dir}/${p}.agent.md" m="${dir}/${p}.merge.md"
  [[ -f "$a" ]] || return 1
  [[ "$(classify_task "$a" "$m")" == "$SM_OVERALL_SUCCESS" ]]
}

emit_chains() {
  local run name phases worktree branch waiting_for results_dir
  local total done_n current status p

  # Live / failed / waiting chains come from the run-record.
  for run in "$TODO"/.running/chain-*.run; do
    name="$(basename "$run" .run)"; name="${name#chain-}"
    phases="$(read_run_field "$run" phases)"
    worktree="$(read_run_field "$run" worktree)"; worktree="${worktree:-$NONE}"
    branch="$(read_run_field "$run" branch)"; branch="${branch:-$NONE}"
    waiting_for="$(read_run_field "$run" waiting_for)"
    results_dir="${worktree}/.todo-tasks/results"

    total="$(echo "$phases" | tr ',' '\n' | grep -c . || echo 0)"
    done_n=0; current="$NONE"
    for p in ${phases//,/ }; do
      if phase_success "$results_dir" "$p"; then
        done_n=$((done_n + 1))
      else
        [[ "$current" == "$NONE" ]] && current="$p"
      fi
    done

    local alive merge_state waiting_unsatisfied merged_on_trunk progress
    if run_is_alive "$run"; then alive="true"; else alive="false"; fi
    merge_state="$(read_run_field "$run" merge_state)"
    waiting_unsatisfied="false"
    if [[ -n "$waiting_for" ]] && [[ "$(classify_slug "$waiting_for" | cut -d'|' -f2)" != "$SM_OVERALL_SUCCESS" ]]; then
      waiting_unsatisfied="true"
    fi
    if chain_merged_on_trunk "$REPO_ROOT" "$branch"; then
      merged_on_trunk="true"
    else
      merged_on_trunk="false"
    fi
    status="$(derive_chain_state "$alive" "$done_n" "$total" "$merge_state" "$waiting_unsatisfied" "$merged_on_trunk")"
    progress="$(chain_progress "$status" "$done_n" "$total")"
    if [[ "$status" == "$SM_CHAIN_WAITING" ]]; then
      current="after ${waiting_for}"
    fi

    local cage logf="${TODO}/.running/chain-${name}.log"
    if [[ -f "$logf" ]]; then cage="$(age_of "$logf")"; else cage="$(age_of "$run")"; fi

    printf 'chain\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$status" "$done_n" "$total" "$current" "$phases" "$worktree" "$branch" "$progress" "$cage"
  done

  # Completed chains come from the trunk definition (run-record already gone).
  local def
  for def in "$TODO"/chains/*.md; do
    name="$(basename "$def" .md)"
    [[ -f "$TODO/.running/chain-${name}.run" ]] && continue
    phases="$(parse_result_field "$def" phases)"
    total="$(echo "$phases" | tr ',' '\n' | grep -c . || echo 0)"
    local cprogress; cprogress="$(chain_progress "$SM_CHAIN_COMPLETE" "$total" "$total")"
    # finalize-chain.sh writes this definition at completion, so its mtime is
    # the chain's finish time.
    printf 'chain\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "complete" "$total" "$total" "$NONE" "$phases" "$NONE" "$NONE" "$cprogress" "$(age_of "$def")"
  done
}

# ─── Epic records ──────────────────────────────────────────────────────────
emit_epics() {
  local def name members total done_n running_n failed_n m rec phase bucket
  for def in "$TODO"/epics/*.md; do
    name="$(basename "$def" .md)"
    members="$(parse_result_field "$def" members)"
    total=0; done_n=0; running_n=0; failed_n=0
    for m in ${members//,/ }; do
      [[ -z "$m" ]] && continue
      total=$((total + 1))
      rec="$(classify_slug "$m")"
      phase="$(echo "$rec" | cut -d'|' -f1)"
      bucket="$(echo "$rec" | cut -d'|' -f3)"
      case "$phase" in
        done)
          if [[ "$bucket" == "$SM_BUCKET_SUCCESS" || "$bucket" == "$SM_BUCKET_READY" ]]; then
            done_n=$((done_n + 1))
          else
            failed_n=$((failed_n + 1))
          fi ;;
        running) running_n=$((running_n + 1)) ;;
        crashed) failed_n=$((failed_n + 1)) ;;
      esac
    done
    printf 'epic\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$total" "$done_n" "$running_n" "$failed_n" "$members"
  done
}

# ─── Stale worktrees ───────────────────────────────────────────────────────
# A worktree whose slug has no live run-record. The reporter names it; archive
# (or the user) removes it.
emit_stale() {
  local line wt_path wt_dir slug
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    wt_path="$(echo "$line" | awk '{print $1}')"
    wt_dir="$(basename "$wt_path")"
    case "$wt_dir" in
      "${WORKTREE_PREFIX}-${REPO_NAME}-"*) slug="${wt_dir#"${WORKTREE_PREFIX}-${REPO_NAME}-"}" ;;
      *) continue ;;
    esac
    # Chain worktrees: skip while a chain run-record is live.
    if [[ "$slug" == chain-* ]]; then
      local cn="${slug#chain-}"
      local cr="${TODO}/.running/chain-${cn}.run"
      [[ -f "$cr" ]] && run_is_alive "$cr" && continue
    else
      local r="${TODO}/.running/${slug}.run"
      [[ -f "$r" ]] && run_is_alive "$r" && continue
    fi
    printf 'stale\t%s\t%s\n' "$slug" "$wt_path"
  done < <(git worktree list 2>/dev/null)
}

# ─── Archived records ──────────────────────────────────────────────────────
# Archived files live in the gitignored .archived/ as `${YYYYMMDD}-${slug}.md`
# (plus sibling .agent.md / .merge.md). The archive date prefix is stripped to
# recover the slug; the copy's mtime (cp does not preserve it) approximates the
# archive time, so `age` orders by most-recently-archived. Old-format archives
# that predate the agent/merge split have no classifiable result → overall "-".
emit_archived() {
  local spec base stem ts slug agent_md merge_md overall commits age notes dev err disp_file
  for spec in "$TODO"/.archived/*.md; do
    base="$(basename "$spec")"
    # Only the spec copy keys a record; skip the derived result files.
    case "$base" in
      *.agent.md|*.merge.md|*.result.md) continue ;;
    esac
    stem="${base%.md}"        # 20260407-installer-versioning
    ts="${stem%%-*}"          # 20260407
    slug="${stem#*-}"         # installer-versioning
    agent_md="${TODO}/.archived/${ts}-${slug}.agent.md"
    merge_md="${TODO}/.archived/${ts}-${slug}.merge.md"
    [[ -f "$agent_md" ]] || agent_md=""
    [[ -f "$merge_md" ]] || merge_md=""

    overall="$NONE"; commits="$NONE"; notes=""
    disp_file="${TODO}/.archived/${ts}-${slug}.disposition"
    if [[ -f "$disp_file" ]]; then
      overall="$(<"$disp_file")"; overall="${overall//[$'\t\r\n ']/}"
    elif [[ -n "$agent_md" ]]; then
      # Old archive, no stamp: best-effort — a genuine success stays success; any
      # non-success archived task is shown as abandoned/done (we cannot retroactively
      # know it was resolved).
      if [[ "$(classify_task "$agent_md" "$merge_md")" == "$SM_OVERALL_SUCCESS" ]]; then
        overall="$SM_OVERALL_SUCCESS"
      else
        overall="$SM_ARCHIVE_ABANDONED"
      fi
    fi
    if [[ -n "$agent_md" ]]; then
      commits="$(parse_result_field "$agent_md" commits)"; commits="${commits:-0}"
      dev="$(parse_result_field "$agent_md" "surface deviations")"
      err="$(parse_result_field "$agent_md" error)"
      [[ "$dev" == "declared" ]] && notes="surface deviations declared — re-triage downstream. "
      [[ -n "$err" ]] && notes="${notes}${err}"
    fi
    age="$(age_of "$spec")"
    [[ -z "$notes" ]] && notes="$NONE"
    notes="${notes//$'\t'/ }"; notes="${notes//$'\n'/ }"

    printf 'archived\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$overall" "$commits" "$age" "$notes"
  done
}

# ─── Dispatch ──────────────────────────────────────────────────────────────
case "$WANT" in
  task)     emit_tasks ;;
  chain)    emit_chains ;;
  epic)     emit_epics ;;
  stale)    emit_stale ;;
  archived) emit_archived ;;
  all)      emit_tasks; emit_chains; emit_epics; emit_stale ;;
  *) echo "Usage: report.sh [task|chain|epic|stale|archived]" >&2; exit 1 ;;
esac
