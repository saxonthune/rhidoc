#!/usr/bin/env bash
set -euo pipefail

# Launch execute-plan.sh in the background with log capture.
# Usage: launch.sh <plan-name> [--no-merge] [--watch]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

PLAN_SLUG=""
EXTRA_ARGS=""
WATCH=false

for arg in "$@"; do
  case "$arg" in
    --no-merge) EXTRA_ARGS+=" --no-merge" ;;
    --watch) WATCH=true ;;
    -*) echo "Unknown option: $arg"; exit 1 ;;
    *) PLAN_SLUG="$arg" ;;
  esac
done

if [[ -z "$PLAN_SLUG" ]]; then
  echo "Usage: launch.sh <plan-name> [--no-merge] [--watch]"
  exit 1
fi

# Fast-fail on preconditions before backgrounding.
# Runs execute-plan.sh --validate-only synchronously; if it exits non-zero,
# the error message is printed to stderr and we bail without creating a log.
if ! bash "${SCRIPT_DIR}/execute-plan.sh" "${PLAN_SLUG}" --validate-only; then
  echo ""
  echo "Validation failed. Not launching."
  exit 1
fi

mkdir -p "${REPO_ROOT}/.todo-tasks/.running"
LOG="${REPO_ROOT}/.todo-tasks/.running/${PLAN_SLUG}.log"

# Detach into a new session so the agent survives a harness that tears down
# the process tree of the shell that launched it (e.g. a sandboxed PID
# namespace reaping backgrounded children when the launch command returns).
if command -v setsid >/dev/null 2>&1; then
  setsid nohup bash "${SCRIPT_DIR}/execute-plan.sh" "${PLAN_SLUG}" ${EXTRA_ARGS} > "${LOG}" 2>&1 &
else
  nohup bash "${SCRIPT_DIR}/execute-plan.sh" "${PLAN_SLUG}" ${EXTRA_ARGS} > "${LOG}" 2>&1 &
fi
AGENT_PID=$!

# Re-check liveness before trusting the launch. A backgrounded child that
# gets reaped the instant this script exits would otherwise print a
# phantom "launched" message.
sleep 0.1
if ! kill -0 "$AGENT_PID" 2>/dev/null; then
  echo "ERROR: agent process ${AGENT_PID} is already gone — launch did not survive." >&2
  if [[ "$AGENT_PID" -lt 100 ]]; then
    echo "  (pid ${AGENT_PID} is suspiciously low — this shell looks sandboxed in its own" >&2
    echo "   PID namespace, which reaps background children when the launch command returns." >&2
    echo "   Run the launch from a persistent shell, or use a detaching launcher.)" >&2
  fi
  echo "  Log: ${LOG}" >&2
  exit 1
fi

echo "Agent launched: ${PLAN_SLUG} (pid ${AGENT_PID})"
echo "Log: tail -f ${LOG}"
echo "Results: .todo-tasks/results/${PLAN_SLUG}.agent.md (+ .merge.md after merge)"

if [[ "$WATCH" == "true" ]]; then
  echo ""
  echo "Watching until ${PLAN_SLUG} reaches a terminal state..."
  exec bash "${SCRIPT_DIR}/wait.sh" "${PLAN_SLUG}"
fi
