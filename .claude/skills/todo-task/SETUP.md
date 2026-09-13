# todo-task first-run setup

The todo-task skill calls a small set of read-only scripts (`list-drafts.sh`,
`list-pending.sh`, `report.sh`, `status.sh`) every time you run `triage`, `execute`, or
`status`. Without an allowlist entry, Claude will prompt for approval on each call.

## Suggested allowlist

Add the entries below to your project's `.claude/settings.local.json` (create the file if
it doesn't exist). This is a suggestion — the skill never edits settings itself. You decide
what to allow.

```jsonc
{
  "permissions": {
    "allow": [
      "Bash(bash .claude/skills/todo-task/list-drafts.sh:*)",
      "Bash(bash .claude/skills/todo-task/list-pending.sh:*)",
      "Bash(bash .claude/skills/todo-task/report.sh:*)",
      "Bash(bash .claude/skills/todo-task/status.sh:*)"
    ]
  }
}
```

These three are strictly read-only (`report.sh` is the sole state-reader; `status.sh` and
`list-pending.sh` are pure renderers over it).

`archive.sh` mutates state — it deletes specs and results after copying them — so it is intentionally left out
of the suggested allowlist. If you want one-keystroke archiving, add it yourself:

```jsonc
"Bash(bash .claude/skills/todo-task/archive.sh:*)"
```

All other scripts (`launch.sh`, `execute-plan.sh`, `execute-chain.sh`) are left unapproved so
you retain explicit control over anything that launches agents or mutates state.
