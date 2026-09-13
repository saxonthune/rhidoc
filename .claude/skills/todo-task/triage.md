# todo-task: triage mode

Refine a pending task from a rough idea into an executable spec that whoever implements it — a headless agent, this session, or a later session that picks it up — can follow without re-deriving the context. The bar is the same either way: every design question resolved before the spec is written. **This is interactive** — present findings, ask questions, get alignment before writing the spec.

**Input**: `$ARGUMENTS[1]` is the task slug. If empty, list pending tasks and ask.

## Step 1: List or select

Always list the untriaged drafts first — the user often gives an approximate name, not
the exact slug:
```bash
bash .claude/skills/todo-task/list-drafts.sh
```

**Resolving the slug the user gave:**

- Exact match in the list → use it.
- No exact match → look for a near match: a slug that is a substring of what they typed
  (or vice versa), shares most words, or is an obvious rewording of the same idea. If
  exactly one draft clearly fits, name it and confirm ("No `foo`; did you mean
  `foo-bar-baz`?") before proceeding.
- Several plausible matches, or none → present the candidates (or the whole list) with
  `AskUserQuestion` and let the user pick.
- The name might instead be an already-promoted spec in `tasks/` (a re-triage) — check
  there too before concluding nothing matches.

When no slug was provided at all, present the drafts with `AskUserQuestion`:

```typescript
AskUserQuestion({
  questions: [{
    question: "Which task should we triage?",
    header: "Task",
    options: [
      // one per task, label = title, description = first line of motivation
    ],
    multiSelect: false
  }]
})
```

## Step 2: Read the task

Read the draft at `.todo-tasks/inbox/{slug}.md` (or `.todo-tasks/tasks/{slug}.md` if you're re-triaging an already-promoted spec). Understand the motivation and scope. If the slug appears in any `.todo-tasks/epics/{epic}.md` `members:` list, also read that epic file for context.

## Step 3: Research the codebase

Investigate the codebase to understand what changes are needed:

1. **Check `.carta/MANIFEST.md`** — use the tag index to map task keywords to relevant docs.
2. **Find relevant files** — Use Grep/Glob to locate code related to the task. Start broad (keyword search), then narrow to specific files.
3. **Read key files** — Read the files you'll need to modify. Understand their structure, patterns, and conventions.
4. **Understand test patterns** — Find existing tests near the code you'll change. Note the test framework, assertion style, and what's already covered.
5. **Check for gotchas** — Look for related code that might break, shared state, or implicit dependencies.
6. **Read the interfaces the change touches — closely enough to quote them.** Read the actual references a decision rests on: the repo glossary or controlled vocabulary (follow the pointer in `CLAUDE.md`/`AGENTS.md`), the current CLI or API surface the task changes (`--help`, the actual signature/enum/route), and any dataflow it moves. Read each until you can quote it exactly — the signature, the enum variants that exist today, the string a command prints, the `file:line`. A skim yields a vague briefing; a quoted interface yields a recommendation.

**Chain/epic phases:** If predecessors have not merged, do not read live code for their output — triage against the predecessor spec's `## Surface after this phase` block. The Surface stands in for code that does not exist yet; a symbol absent from it does not exist.

## Step 4: Briefing

Present your findings before writing anything — this is where you and the user align. Write for a reader who does not remember the code you just read. The briefing has four parts.

### 1. Plan Summary
One paragraph restating the task's motivation and scope in your own words. Flag anything ambiguous.

### 2. Status quo
Describe what exists today, ordered by the flow of the thing you're changing — for a code path, follow control flow in execution order, not a list of symbols. Give it in two passes:

- **Plain** — the mechanism as ideas, in the repo's own terms, with no symbol names or `file:line`. A reader who knows the system but not this code should be able to approve the approach from this pass alone.
- **Grounded** — the same path in code: each step a `file:line` with the exact signature, enum, or string.

Lead with the plain pass; don't open on a symbol the reader hasn't met yet.

### 3. Recommended changes
For each design decision the task surfaces, state your recommendation as one declarative sentence that cites the status-quo fact it rests on — e.g. "Add a `catalog add` subcommand reusing the `push_emission` write path (`usecases.rs:194`), since that path already mints a work node and its aliases." End on the recommendation, not a menu of options.

When a choice depends on the user's priority, name the deciding axis, say which option wins under the priority they've given, and ask only if that priority is genuinely unstated.

Use `AskUserQuestion` only to capture a pick the briefing has already stated — never as the place a recommendation first appears.

### 4. What it changes
The interface and dataflow delta: which signatures, routes, or data paths move, before → after. This is what the reader approves.

## Step 5: Scope check — is this one headless session?

Evaluate whether the plan can be executed by a single headless agent session. A good session targets:

- **~5-8 file modifications** (edits, not reads)
- **One cohesive feature or fix**
- **Completable in a single focused pass**
- **All design decisions already resolved**

If the task is too large (10+ files, multiple independent features, needs mid-implementation judgment), propose splitting into 2-3 smaller tasks. Write each as a separate file in `.todo-tasks/` and tell the user.

## Step 6: Rewrite as executable spec

After the user has answered all questions and confirmed the approach, **promote the draft**: write the executable spec to `.todo-tasks/tasks/{slug}.md` and delete the `.todo-tasks/inbox/{slug}.md` draft. Do NOT commit — the spec stays uncommitted whichever way it gets implemented (it doesn't block launching, a run's orchestrator commits it automatically, and an in-session implementation never needs a separate spec commit). Use this structure:

````markdown
# {Title}

## Motivation

{Original motivation, refined with what you learned from research.}

## Do NOT

- {Explicit negative constraints — things the agent must avoid}
- {Scope boundaries — what NOT to touch}
- {Wrong-but-easy approaches the agent might be tempted by}

## Plan

### 1. {First logical step}

{Concrete instructions. Name specific files, functions, line ranges. Describe what to change and why.}

### 2. {Second logical step}

{Continue with specifics...}

## Files to Modify

- `path/to/file.ts` — {what changes}
- `path/to/test.ts` — {what test to add/modify}

## Verification

```bash
{commands to verify the implementation}
```

## Out of Scope

- {Anything deferred to a future task}

## Notes

- {Caveats, risks, things a reviewer should watch for}

## Surface after this phase

> Required for chain/epic phases. Omit for standalone one-off tasks.

- {Symbols this phase promises to leave behind — exported functions, types,
  files — stated precisely enough that a later phase can triage against them.}
- {Behaviors / integration points the phase guarantees.}
- {Negative space: what is deliberately unchanged and can still be relied on —
  e.g. "Legacy X still exists and still works until Phase N".}
````

The `## Surface after this phase` block is the contract that downstream phases triage against. Write it precisely: if a symbol is not listed, later phases will treat it as nonexistent.

> The `## Verification` section MUST contain at least one fenced bash/sh code block. execute-plan.sh parses commands from that block to run as the verification gate. Write it even when you expect an in-session implementation: it costs nothing, it documents "done", and it keeps the spec launch-compatible if the plan changes.

> **Verification must be non-destructive.** The block runs inside the agent's
> worktree and whatever it commits merges to trunk. Never invoke `archive.sh`
> (sweep), `git rm`, worktree removal, or anything that mutates trunk or other
> tasks. Treat `.todo-tasks/` as orchestrator-owned and off-limits to a task's own
> verification. Test exit codes with a scoped, side-effect-free invocation.

## Step 7: Confirm and pick an implementation route

Tell the user the task has been triaged with a brief summary of the plan, then ask how to
implement it:

```typescript
AskUserQuestion({
  questions: [{
    question: "Plan is triaged and ready. How should it be implemented?",
    header: "Implement",
    options: [
      { label: "In this session", description: "I implement the plan now in this conversation; you commit; then archive.sh --merged {slug}" },
      { label: "Launch headless", description: "Run execute-plan in a background worktree, squash-merge one commit on success" },
      { label: "Launch (no merge)", description: "Run execute-plan, leave the branch for manual review" },
      { label: "Hand off", description: "Leave the spec in tasks/ for a later session to pick up" }
    ],
    multiSelect: false
  }]
})
```

- **In this session** — implement the plan directly, following the same spec. Let the
  user commit the work (do not commit for them). Once it is committed, run
  `bash .claude/skills/todo-task/archive.sh --merged {slug}` to close the task — this is
  the sanctioned exit; the spec otherwise lingers as `pending` in status output.
- **Launch headless** / **Launch (no merge)** — switch to execute mode for that slug.
- **Hand off** — stop here. The spec is durable on disk; any later session can read it
  and implement it by either route.

## Triaging Guidelines

- **This is interactive.** Do not skip the briefing and rush to writing the spec. The conversation in Step 4 is where you and the user align on approach.
- **Name every file.** The agent shouldn't have to search for where to make changes.
- **Be specific about what, not how.** "Add a `getUserById` function to `users.ts` that queries by primary key" — not pseudocode.
- **Write negative constraints early.** "Do NOT" goes near the top of the spec — headless agents may not read the full document with equal attention. Ask yourself: "What's the easiest wrong implementation?" and block that path.
- **Include verification.** The agent needs to know when it's done.
- **Keep it atomic.** If triaging reveals the task is too large, split it into multiple tasks and tell the user.
- **Chain/epic phases triage against the Surface, not the code.** For a phase whose predecessors haven't merged, the predecessor's `## Surface after this phase` block is authoritative: anything absent from it does not exist, and its negative-space lines ("Legacy X still works until Phase N") are promises you can rely on.
