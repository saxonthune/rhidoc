# todo-task: create mode

File a task as a durable markdown note. Two first-class uses:

- **Park work** so the current session can continue its primary task.
- **Hand off** context to a later session — one session records an intention with enough
  detail that a different session can triage it, discuss it with the user, and implement
  it. The inbox draft is shared memory between sessions, not only a note-to-self.

**Input**: everything after `create` is the task description. If empty, ask the user what to file.

## Step 1: Generate a slug

Format: `{slug}.md` — kebab-case, descriptive.

Examples: `fix-login-timeout.md`, `add-user-search.md`, `stale-cache-after-deploy.md`

## Step 2: Write the draft

Write to `.todo-tasks/inbox/{slug}.md`. The inbox is **gitignored** — a filed idea is not yet work, so it never touches git. Do NOT commit. (Triage later promotes it to a tracked `tasks/{slug}.md`.)

```markdown
# {Title}

## Motivation

{Why this task exists. 2-3 sentences. Include how it was discovered if relevant.}

## Description

{What needs to happen. Be concrete about the problem/feature. Reference specific files, functions, or behaviors if known.}

## Scope

- {Bullet list of what's in scope}
- {Be specific enough that a triage step can act on it}

## Out of Scope

- {Anything explicitly NOT part of this task}

## Notes

- {Optional. Context that would help the triage step: related files, prior attempts, links to related tasks.}
```

## Step 3: Confirm

Tell the user the file was created and they (or a later session) can triage it with
`/todo-task triage {slug}`. If the task is a handoff meant for another session, say so —
the draft holds until that session reads it.

## Guidelines

- **Be concrete.** "Login times out after 30s on slow connections" > "login issues"
- **Include reproduction context.** What you were doing, what file, what symptoms.
- **Reference files.** If you know which files are involved, list them.
- **One task per file.** Three bugs = three tasks.
- **Don't over-specify the solution.** Describe the problem and desired outcome.
- **Check for duplicates.** Scan `.todo-tasks/inbox/` and `.todo-tasks/tasks/` first.

## Epic Tasks

Epic membership is an **explicit slug list**, not a filename prefix. If the task belongs to an existing epic (`.todo-tasks/epics/{epic}.md`), write the task as a normal `tasks/{slug}.md`, then add its slug to that epic's `members:` line (comma-separated). The slug is the stable id — references never break.
