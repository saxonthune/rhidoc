#!/usr/bin/env bash
# ─── Provider adapter: claude ─────────────────────────────────────────────────
# A provider adapter is a sourced bash file defining three functions. This
# comment block is the contract every adapter must implement — copy this shape
# for a new provider (e.g. providers/codex.sh).
#
# provider_run_session — run the main headless session.
#   Reads (caller-set globals): SESSION_PROMPT (the full prompt), MAX_TURNS,
#     MAX_BUDGET, and the current working directory (already cd'd to the
#     worktree).
#   Behavior: streams a concise live digest to stdout.
#   Sets (normalized outputs): PROVIDER_EXIT (int), PROVIDER_SESSION_ID,
#     PROVIDER_RESULT (the agent's final text), PROVIDER_SUBTYPE,
#     PROVIDER_TURNS, PROVIDER_COST.
#
# provider_resume_session — retry continuing an existing session.
#   Reads: SESSION_PROMPT (the retry prompt), PROVIDER_SESSION_ID (the session
#     to resume), RETRY_BUDGET.
#   Sets: PROVIDER_RETRY_OUTPUT (raw text for the caller to log) and an
#     updated PROVIDER_SESSION_ID.
#
# provider_run_fresh_session — retry with no prior session.
#   Reads: SESSION_PROMPT, RETRY_BUDGET.
#   Sets: PROVIDER_RETRY_OUTPUT (raw text for the caller to log) and
#     PROVIDER_SESSION_ID, if the retry produced one.

# format_stream_events — reads NDJSON events on stdin, prints a concise digest line per event.
# Used to provide live progress during a headless session. Malformed lines are silently skipped.
format_stream_events() {
  jq -r --unbuffered '
    if .type == "assistant" then
      (.message.content[]? |
        if .type == "text" then
          "  " + (.text | gsub("\n"; " ") | .[0:100])
        elif .type == "tool_use" then
          "→ " + .name + ": " +
            (.input.command // .input.file_path // .input.pattern // .input.path // "" | tostring | .[0:80])
        else empty end)
    elif .type == "result" then "✓ session complete"
    else empty end
  ' 2>/dev/null || true
}

provider_run_session() {
  # Unset CLAUDECODE to allow nested claude invocations from parent sessions
  unset CLAUDECODE

  local stream_raw stream_err
  stream_raw="$(mktemp)"; stream_err="$(mktemp)"

  claude -p \
    --allowedTools "Read,Write,Edit,Glob,Grep,Bash" \
    --permission-mode bypassPermissions \
    --output-format stream-json --verbose \
    --max-turns "${MAX_TURNS}" \
    --model sonnet \
    --max-budget-usd "${MAX_BUDGET}" \
    "${SESSION_PROMPT}" 2>"$stream_err" \
    | tee "$stream_raw" \
    | format_stream_events
  PROVIDER_EXIT=${PIPESTATUS[0]}

  # Extract session ID, result, and richer metadata from the final result event
  PROVIDER_SESSION_ID=$(jq -r 'select(.type=="result") | .session_id // empty' "$stream_raw" 2>/dev/null | tail -1)
  PROVIDER_RESULT=$(jq -r 'select(.type=="result") | .result // empty' "$stream_raw" 2>/dev/null | tail -1)
  PROVIDER_SUBTYPE=$(jq -r 'select(.type=="result") | .subtype // empty' "$stream_raw" 2>/dev/null | tail -1 || echo "")
  PROVIDER_TURNS=$(jq -r 'select(.type=="result") | .num_turns // empty' "$stream_raw" 2>/dev/null | tail -1 || echo "")
  PROVIDER_COST=$(jq -r 'select(.type=="result") | .total_cost_usd // empty' "$stream_raw" 2>/dev/null | tail -1 || echo "")

  # Fallback: if PROVIDER_RESULT is empty (crash before result event), use stderr tail
  if [[ -z "$PROVIDER_RESULT" ]]; then
    PROVIDER_RESULT="$(tail -5 "$stream_err" 2>/dev/null || true)"
  fi

  rm -f "$stream_raw" "$stream_err"
}

provider_resume_session() {
  PROVIDER_RETRY_OUTPUT=$(claude -p \
    --resume "${PROVIDER_SESSION_ID}" \
    --permission-mode bypassPermissions \
    --output-format json \
    --max-turns 50 \
    --max-budget-usd "${RETRY_BUDGET}" \
    "${SESSION_PROMPT}" 2>&1) || true

  local new_session_id
  new_session_id=$(echo "${PROVIDER_RETRY_OUTPUT}" | jq -r '.session_id // empty' 2>/dev/null || echo "")
  if [[ -n "$new_session_id" ]]; then
    PROVIDER_SESSION_ID="$new_session_id"
  fi
}

provider_run_fresh_session() {
  PROVIDER_RETRY_OUTPUT=$(claude -p \
    --allowedTools "Read,Write,Edit,Glob,Grep,Bash" \
    --permission-mode bypassPermissions \
    --output-format json \
    --max-turns 50 \
    --model sonnet \
    --max-budget-usd "${RETRY_BUDGET}" \
    "${SESSION_PROMPT}" 2>&1) || true

  local new_session_id
  new_session_id=$(echo "${PROVIDER_RETRY_OUTPUT}" | jq -r '.session_id // empty' 2>/dev/null || echo "")
  if [[ -n "$new_session_id" ]]; then
    PROVIDER_SESSION_ID="$new_session_id"
  fi
}
