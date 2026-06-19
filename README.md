# GoalLoop

**A self-draining task queue for any coding agent.** Add tasks as GitHub Issues —
even a giant unstructured brain dump. GoalLoop breaks them down automatically, then
executes them **one at a time in fresh agent sessions**, each one finished and tested
before the next starts.

It works with **Claude Code, OpenAI Codex, Cursor, Aider, Kimi** — anything that reads
[`AGENTS.md`](https://agents.md) and can run the `gh` CLI.

---

## Why

Dumping ten tasks into one long chat means they share one context window: the agent
juggles them, half get dropped, and tokens balloon as every new message re-reads the
old mess. GoalLoop fixes that structurally — **one task = one issue = one fresh
session**. Each session reads only the project config and the single issue, does the
work behind the full verify gate, opens a PR, and ends. Cheaper, sharper, and nothing
moves on until it's actually done.

## How it works

```
  you add issues          triage (automatic)          the loop
        │                       │                         │
   ┌─────────┐  split / sharpen ┌───────┐   pick #1   ┌──────────────┐  PR merged ┌──────┐
   │  inbox  │ ────────────────▶│ ready │ ───────────▶│ in-progress  │ ──────────▶│ done │
   └─────────┘                  └───────┘             └──────────────┘            └──────┘
        │                                                     │
        └─ big "brain dump"? ─▶ epic + child issues (each ready)
```

Labels are the state machine. One task is ever `in-progress` at a time — that's how
"finish before moving on" is enforced.

## What gets installed

```
AGENTS.md                       # hub every agent reads (CLAUDE.md is wired up too)
.goalloop/
  config.yml                    # YOU set: what the project is + verify commands + policy
  playbooks/
    triage.md                   # inbox → ready  (splits big issues into child issues)
    execute.md                  # one issue → tested PR
    run-queue.md                # the loop: reconcile → triage → execute one
.github/
  ISSUE_TEMPLATE/{task,brain-dump}.yml
  workflows/goalloop-labels.yml         # creates the labels (gh, no 3rd-party action)
  workflows/goalloop-run.yml.example    # optional scheduled runner (bring any agent)
.claude/commands/{triage,execute-issue,run-queue}.md   # Claude Code slash commands
```

The **playbooks are plain Markdown and use the `gh` CLI** for every GitHub action — so
the exact same logic drives any agent. Nothing is Claude-specific except the optional
`.claude/commands/` shortcuts.

---

## Install

From the root of the repo you want to add it to:

```bash
# from the published standalone repo (install.sh sits at the repo root):
curl -fsSL https://raw.githubusercontent.com/Cloutboicade/goalloop/main/install.sh | bash

# or if you have this kit as a folder:
bash goalloop/install.sh          # inside a repo that vendored the kit
bash install.sh                   # inside a clone of the standalone goalloop repo
```

It's safe and idempotent: it auto-detects your stack's build/test commands, never
clobbers your `config.yml`, never touches your source, and can be re-run anytime.

### Upgrading an existing install

Re-run the exact same one-liner from the repo root:

```bash
curl -fsSL https://raw.githubusercontent.com/Cloutboicade/goalloop/main/install.sh | bash
```

It **refreshes the playbooks to the latest version** while **preserving your
`.goalloop/config.yml`** (it's never overwritten). Commit the changed files. That's the
whole upgrade — your tasks, labels, and settings are untouched.

## Built to scale (v3)

The breakdown and execution are designed to be safe at any size and never need a redo:

- **Idempotent, resumable triage.** A big brain dump becomes a checklist *ledger* in the
  epic; each run carves the next batch and checks lines off — so it **never duplicates,
  never loses an item**, and resumes mid-breakdown. Hundreds of tasks across many runs is fine.
- **Right-sized, not fixed-count.** One task per real deliverable — the count follows the
  work, never a quota. Sub-areas that are themselves big become **nested epics** and get
  broken down further (unlimited depth).
- **Careful execute.** Understand-before-touching, smallest correct change, a test that
  locks it, **fix-forward** verify, a self-review of the diff, and **stop-and-ask (block)
  on any ambiguity** rather than guess. It never opens a PR that fails the gate.
- **Self-healing loop.** Reconciles merged / stuck / orphaned tasks, respects
  `Depends on #N`, and keeps exactly one task in flight at a time.

Then:

1. **Edit `.goalloop/config.yml`** — one line on what the project is, and confirm the
   `verify:` commands (install / check / build) match your stack.
2. **Merge to your default branch** (GitHub only activates issue templates + labels there).
3. **Actions → "GoalLoop labels" → Run workflow** (creates the labels, once).
4. **Add a task:** Issues → New issue → *🟢 Task* or *🧠 Brain dump*.
5. **Run it** (see your agent below).

---

## Drive it with your agent

You add tasks as issues, then point an agent at the loop. Pick yours:

### Claude Code
- **In a session:** `/run-queue` (or `/triage`, `/execute-issue <n>`).
- **Hands-off:** run `/schedule`, set an hourly cadence with the prompt `/run-queue`.
  Runs on your subscription (no extra API key). Claude routines push `claude/`-prefixed
  branches by default — the kit already uses that prefix.

### OpenAI Codex
Codex auto-reads `AGENTS.md`. Just tell it:
```bash
codex exec --sandbox danger-full-access --ask-for-approval never \
  "Run the task loop: follow .goalloop/playbooks/run-queue.md for this repo."
```
(`danger-full-access` because it needs network for `gh`. `CODEX_API_KEY` env for auth.)

### Cursor / Windsurf / Aider / Zed / Jules / Copilot
These read `AGENTS.md` natively. In the agent chat, say:
> Run the task loop — follow `.goalloop/playbooks/run-queue.md` for this repo.

### Kimi (Moonshot)
The `kimi` CLI reads project docs; point it at the playbook the same way:
> Follow `.goalloop/playbooks/run-queue.md` for this repo.

*(Whether Kimi auto-loads AGENTS.md wasn't confirmed at time of writing — naming the
playbook path explicitly always works.)*

### Any other agent
The playbooks are just Markdown + `gh` commands. Open `.goalloop/playbooks/run-queue.md`
and tell your agent to follow it. If the agent can run a shell and `gh`, it works.

---

## Automate on a schedule (optional, agent-agnostic)

`.github/workflows/goalloop-run.yml.example` is a cron workflow with swappable agent
blocks (Claude Code Action, OpenAI Codex Action, or any CLI). Rename it to
`goalloop-run.yml`, uncomment one block, add that agent's API key to repo **Secrets**,
and commit. Same trigger across every agent — only the one invocation line changes.

> Claude Code users: prefer **routines** (`/schedule`) over the workflow — it runs on
> your subscription instead of a pay-per-token API key.

---

## `.goalloop/config.yml`

This is where you tell the loop about *your* project — it's why the same kit works on
any stack:

```yaml
project: "What this project is, in a sentence."
verify:
  install: "npm install"
  check:   "npm test"        # typecheck + unit tests — must pass before a PR
  build:   "npm run build"   # production build — must pass
git:
  default_branch: main
  branch_prefix: "claude/"
policy:
  auto_merge: false          # true → loop may merge a PR (only with the 'autopilot' label) once CI is green
  max_tasks_per_run: 1
```

## Safety

- The loop **opens PRs and parks them for review** by default. Add the `autopilot`
  label to an issue (and set `auto_merge: true`) to let the loop merge that one once
  CI is green.
- Every task passes your configured `check` + `build` before a PR exists.
- A green automation run only means it *ran* — open the first few runs to confirm the
  task actually succeeded, then trust it.

## Notes / honest caveats

- **Claude Code** reads `CLAUDE.md`, not `AGENTS.md`. The installer handles this: it
  appends a pointer to an existing `CLAUDE.md`, or creates one that imports `@AGENTS.md`.
- **`gh issue create --parent`** (used to link child issues) needs a recent `gh`. On
  older versions the loop falls back to a checklist in the epic — still fully functional.
- Built on open standards: [AGENTS.md](https://agents.md) and the GitHub `gh` CLI.
