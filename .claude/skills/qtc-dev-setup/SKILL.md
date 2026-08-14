---
name: qtc-dev-setup
description: Use when bootstrapping the qtc-dev-* skill system on a project for the first time, or repairing missing scaffolding. Creates the Obsidian vault layout under docs/project/, installs the SessionStart memory-load hook, initializes counters, and seeds empty memory files. Idempotent - safe to re-run.
---

# qtc-dev-setup

Bootstrap the qtc-dev-* skill system: vault layout, hook wiring, counters, memory stubs.

## When this runs

The user invokes `/qtc-dev-setup` once per project. Safe to re-run — every operation is idempotent (create-if-missing, merge-don't-replace).

## Glossary

Use these terms exactly:

- **Vault** — the `docs/project/` directory; everything qtc-dev reads/writes lives there.
- **Memory** — the four files in `docs/project/memory/`: glossary, decisions, failure-patterns, preferences.
- **Counters** — `docs/project/memory/.counters.yml`, the source of truth for EPIC/TASK/ADR sequential IDs.
- **Hook** — the SessionStart Python script at `.claude/hooks/qtc_dev_memory_load.py`.

## Process

### 1. Verify prerequisites

- Confirm working directory is the project root (contains `CLAUDE.md` or `.claude/`).
- Confirm Python 3 is available: `python3 --version`.
- If either fails: stop, report what's missing, do not partially install.

### 2. Create vault folders (idempotent)

Create (only if absent):

- `docs/project/memory/`
- `docs/project/adr/`
- `docs/project/features/`
- `docs/project/epics/`
- `docs/project/tasks/`

### 3. Seed memory files (idempotent)

Create with these initial bodies if absent. Do NOT overwrite existing files.

`docs/project/memory/glossary.md`:

```markdown
# Domain Glossary

Canonical terms for the project. Skills append here when a new term
crystallizes during brainstorm/architect. One `## Term` heading per term;
first non-blank line under the heading is the one-line definition.
```

`docs/project/memory/decisions.md` (header must be exactly `# Decisions` — `prepend_decision.py` prepends after it):

```markdown
# Decisions

Real decisions only — a choice a future reader needs the *why* for. One line each:
`- YYYY-MM-DD [TAG] decision text (and what it rejects)`.

Decision tags: ADR | REQ CHANGE | EXPERIMENT | SPIKE | BUG FIX | INFRA | INTEGRATION

Lifecycle breadcrumbs (BRAINSTORM/ARCHITECT/DECOMPOSE/EXECUTE/VERIFY/RALPH) do
NOT go here — they belong in pipeline-log.md. Keeping them apart is what stops the
decision record from drowning under hundreds of lifecycle lines.
```

`docs/project/memory/pipeline-log.md` (header must be exactly `# Pipeline Log` — `prepend_log.py` prepends after it):

```markdown
# Pipeline Log

Automated audit trail of the dev pipeline — one line per lifecycle event, written by
the qtc-dev skills via `prepend_log.py`. Not for human decisions (those go to
decisions.md). The sanity-doctor reads this file for its EXECUTE/VERIFY pairing checks.

Lifecycle tags: BRAINSTORM | ARCHITECT | DECOMPOSE | EXECUTE | VERIFY | RALPH
```

`docs/project/memory/failure-patterns.md`:

```markdown
# Known Failure Patterns

Each pattern has a `## Shape:` heading, then root cause, fix, and tasks
where it was seen.
```

`docs/project/memory/preferences.md`:

```markdown
# Workflow Preferences

Captured user preferences and corrections. Format:
- <rule>
  Why: <reason>
  Apply: <when>
```

`docs/project/memory/.counters.yml`:

```yaml
epic: 0
task: 0
adr: 0
```

### 4. Seed Work Board base file (idempotent)

Create `docs/project/Work Board.base` if absent; never overwrite if present.

```yaml
properties:
  id:
    displayName: ID
  type:
    displayName: Type
  status:
    displayName: Status
  feature:
    displayName: Feature
  epic:
    displayName: Epic
  depends_on:
    displayName: Depends On
  review_attempts:
    displayName: Reviews
  blocker_question:
    displayName: Blocker
  created:
    displayName: Created
views:
  - type: table
    name: Epics
    filters:
      and:
        - type == "epic"
    order:
      - id
      - title
      - status
      - feature
      - created
    sort: []
  - type: table
    name: Tasks
    filters:
      and:
        - type == "task"
    order:
      - id
      - title
      - status
      - epic
      - depends_on
      - review_attempts
      - created
    sort:
      - property: epic
        direction: ASC
      - property: id
        direction: ASC
  - type: table
    name: Ready
    filters:
      and:
        - status == "ready"
        - or:
            - type == "epic"
            - type == "task"
    order:
      - id
      - title
      - epic
      - depends_on
      - created
    sort:
      - property: id
        direction: ASC
  - type: table
    name: In Progress
    filters:
      and:
        - status == "in-progress"
        - or:
            - type == "epic"
            - type == "task"
    order:
      - id
      - title
      - epic
      - depends_on
      - review_attempts
    sort:
      - property: id
        direction: ASC
  - type: table
    name: Blocked
    filters:
      and:
        - status == "blocked-by-human"
        - or:
            - type == "epic"
            - type == "task"
    order:
      - id
      - title
      - epic
      - blocker_question
    sort:
      - property: id
        direction: ASC
  - type: table
    name: Done
    filters:
      and:
        - status == "done"
        - or:
            - type == "epic"
            - type == "task"
    order:
      - id
      - title
      - epic
      - created
    sort:
      - property: id
        direction: DESC
```

### 5. Install the SessionStart hook

- Ensure `.claude/hooks/qtc_dev_memory_load.py` exists; if missing, copy from `qtc_dev_memory_load.py` bundled in this skill directory.
- Make it executable: `chmod +x .claude/hooks/qtc_dev_memory_load.py`.
- Merge into `.claude/settings.json` (project-level) under `hooks.SessionStart`. **Merge, don't replace.** Read existing JSON, append a new entry if the same command isn't already registered.

Expected final state in `.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "python3 .claude/hooks/qtc_dev_memory_load.py" } ] }
    ]
  }
}
```

If other SessionStart hooks already exist, preserve them; just add this one.

### 6. (Optional) Enable Stop hook

If the user invoked `/qtc-dev-setup --enable-stop-hook`, also append a Stop hook entry pointing at `.claude/hooks/qtc_dev_session_summary.py`. The script does not yet exist; skip unless the flag is set and the user accepts they must implement that script themselves.

### 7. Verify and report

After all steps, output a summary table:

| Item | Status |
|---|---|
| Vault folders | created N, existed M |
| Memory stubs | seeded N, existed M |
| Work Board base | created / already present |
| Hook script | installed / already present |
| settings.json | merged / unchanged |

Then list next steps:

- "Run `/qtc-dev-brainstorm` to capture your first feature."
- "Glossary lives at `docs/project/memory/glossary.md` — edit freely."

## Idempotency rules

- Folders: create-if-missing only.
- Memory files: create-if-missing only — never overwrite.
- Work Board base: create-if-missing only — never overwrite.
- Gate config (`.claude/qtc-gate.json`): create-if-missing only — never overwrite.
- Counters: create-if-missing only — never reset.
- settings.json: merge into existing keys; do not duplicate the hook entry if already present (match by exact command string).

## Out of scope

- Migrating existing data — this skill assumes a fresh install.
- Cleaning up partial installs — the user can delete `docs/project/memory/` and rerun.
- Cross-project setup — the skill modifies only the current project.
