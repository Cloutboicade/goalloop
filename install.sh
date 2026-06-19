#!/usr/bin/env bash
# =============================================================================
#  GoalLoop installer — a self-draining task queue for ANY coding agent.
#
#  Add tasks as GitHub Issues. They get broken down automatically, then executed
#  ONE AT A TIME in fresh agent sessions — each finished and tested before the
#  next. Works with Claude Code, OpenAI Codex, Cursor, Aider, and any agent that
#  reads AGENTS.md and can run `gh`.
#
#  USAGE — run from the root of the repo you want to add it to:
#      bash install.sh
#  or one-line (when hosted):
#      curl -fsSL <raw-url>/install.sh | bash
#
#  Safe + idempotent: never touches your source, never clobbers your config.yml,
#  re-runnable. After it finishes, follow the printed "Next steps".
# =============================================================================
set -euo pipefail

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

# --- Locate the repo + derive owner/name --------------------------------------
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || { echo "ERROR: run this from inside a git repository." >&2; exit 1; }
cd "$ROOT"

REMOTE="$(git remote get-url origin 2>/dev/null || echo '')"
# Take the trailing owner/repo regardless of host or extra path segments
# (handles git@host:o/r.git, https://host/o/r, and proxied https://host/git/o/r).
SLUG="$(printf '%s' "$REMOTE" | sed -E 's#\.git$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')"
printf '%s' "$SLUG" | grep -Eq '^[^/]+/[^/]+$' || SLUG="OWNER/REPO"
DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="main"

say "GoalLoop → installing into: $ROOT"
say "  repo:   $SLUG"
say "  branch: $DEFAULT_BRANCH"

mkdir -p .goalloop/playbooks .github/ISSUE_TEMPLATE .github/workflows .claude/commands

# --- Detect the project's verify commands (best effort) -----------------------
INSTALL_CMD=""; CHECK_CMD=""; BUILD_CMD=""
has() { grep -q "$1" package.json 2>/dev/null; }
if [ -f bun.lock ] || [ -f bun.lockb ]; then
  INSTALL_CMD="bun install"
  if has '"check"'; then CHECK_CMD="bun run check"; else CHECK_CMD="bun test"; fi
  has '"build"' && BUILD_CMD="bun run build"
elif [ -f package.json ]; then
  INSTALL_CMD="npm install"
  if has '"check"'; then CHECK_CMD="npm run check"; elif has '"test"'; then CHECK_CMD="npm test"; fi
  has '"build"' && BUILD_CMD="npm run build"
elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then
  INSTALL_CMD="pip install -r requirements.txt"; CHECK_CMD="pytest"; BUILD_CMD=""
elif [ -f go.mod ]; then
  INSTALL_CMD="go mod download"; CHECK_CMD="go test ./..."; BUILD_CMD="go build ./..."
elif [ -f Cargo.toml ]; then
  INSTALL_CMD="cargo fetch"; CHECK_CMD="cargo test"; BUILD_CMD="cargo build --release"
fi

# --- .goalloop/config.yml  (never clobber an existing one) --------------------
if [ -f .goalloop/config.yml ]; then
  say "  keep:   .goalloop/config.yml already exists — left untouched"
else
  cat > .goalloop/config.yml <<EOF
# .goalloop/config.yml — tell the loop about THIS project. Every agent reads this.

# One or two lines: what this project is and what "good" looks like.
project: >-
  TODO: describe this project in a sentence so the agent has context.

# Commands the loop runs to VERIFY a task before opening a PR. Edit to match your
# stack. Leave a step blank ("") to skip it. (Auto-detected below — double-check.)
verify:
  install: "${INSTALL_CMD}"
  check:   "${CHECK_CMD}"     # typecheck + unit tests — must pass
  build:   "${BUILD_CMD}"     # production build — must pass

git:
  default_branch: ${DEFAULT_BRANCH}
  branch_prefix: "claude/"    # loop branches start with this; some hosts only allow
                              # pushes to a prefix (e.g. Claude routines → claude/)

policy:
  auto_merge: false           # if true, loop may merge a PR once CI is green — but
                              # ONLY for issues that also carry the 'autopilot' label
  max_tasks_per_run: 1        # finish one task fully before starting the next

triage:
  max_new_issues_per_run: 20  # carve big epics in batches across runs (rate-limit safe);
                              # the loop resumes a half-carved epic on the next run
execute:
  max_fix_attempts: 3         # fix-forward tries on a failing verify before parking a task
EOF
  say "  wrote:  .goalloop/config.yml (verify auto-detected: check='${CHECK_CMD:-<none>}')"
fi

# --- Playbooks (agent-neutral; always refreshed) ------------------------------
cat > .goalloop/playbooks/triage.md <<'EOF'
# Playbook — TRIAGE: turn raw `inbox` issues into a clean, right-sized `ready` queue

**Planning only — write NO code, open NO PRs.** Use the `gh` CLI for every GitHub
action. Read `.goalloop/config.yml` (and `AGENTS.md` / `CLAUDE.md` if present) for
context, the verify stack, and `triage.max_new_issues_per_run` (default 20).

Three guarantees you must uphold: **never duplicate** an item, **never lose** an item,
**right-size** every task — the count follows the work, never a fixed quota like 5–7.

## 1. Find work
```
gh issue list --label inbox --state open --json number,title,body,labels --limit 200
```
Count NEW issues you create this run; stop creating once you reach
`triage.max_new_issues_per_run` (default 20) so you never trip GitHub's bulk-creation
rate limit. Anything unfinished resumes automatically on the next run.

## 2. Classify each inbox issue
- **Atomic** — one coherent deliverable a single session can implement AND verify.
- **Epic** — multiple independent deliverables (a brain dump, or a task with several
  asks). Judge by content, not by how long the text is.

## 3. ATOMIC → sharpen and promote
1. Read enough of the repo to ground it. Add/refine **2–5 concrete, checkable acceptance
   criteria** citing the real files/areas the work will touch (`gh issue comment`).
2. If you realize it's too big to finish+verify in one session, treat it as an EPIC.
3. **Dependencies:** if it can't start until another task is done, add a line
   `Depends on #M` to its body and label it `blocked` (not `ready`) until #M is `done`.
4. Otherwise promote:
   `gh issue edit <n> --remove-label inbox --add-label ready --add-label "priority:<high|med|low>"`

## 4. EPIC → plan once, then carve in idempotent batches (scales to ANY size)
The epic body is the **ledger** — that is what makes this resumable and duplicate-proof.

### A. Write the plan ONCE
If the body has no `## GoalLoop plan` section yet, analyze the dump and append one:
- One `- [ ]` line per intended task — **as many as the dump truly warrants** (3 or 300).
  Don't merge distinct deliverables; don't shatter one deliverable into noise.
- For large dumps, group lines under `### <theme>` headers and order them so foundations
  come before the features that depend on them. Note couplings inline: `(after: <line>)`.
```
gh issue edit <epic> --body "<original dump text>

## GoalLoop plan
### <theme 1>
- [ ] <task>
- [ ] <task>
### <theme 2>
- [ ] <task>"
```

### B. Carve the next batch into real issues
Take the next UNCHECKED `- [ ]` lines (up to the per-run cap). For each:
1. Create the child (prefer native `--parent`; the ledger checklist is the always-true backbone):
```
gh issue create --parent <epic> --title "<sharp title>" \
  --body $'Goal: <one paragraph>\n\nAcceptance:\n- [ ] <concrete, file-anchored>\n\nContext: epic #<epic>.' \
  --label <ready|inbox> --label "priority:<p>"
```
   - If that line is itself a multi-deliverable area, create it as a **nested epic**:
     label it `epic` + `inbox` (NOT `ready`). A later pass breaks it down too — depth is
     unlimited. This is how the system "expands what needs expanding."
   - If it depends on a sibling, add `Depends on #M` to its body and label it `blocked`.
2. After creating the batch, **edit the epic body once** to check off exactly the lines you
   just carved, recording each issue number: `- [x] #<new> <title>`. A re-run only ever
   processes still-unchecked lines, so nothing is duplicated and nothing is lost.

### C. Finish or hand off
- Unchecked lines remain (you hit the cap) → leave the epic `inbox`+`epic` and STOP. The
  next `/run-queue` resumes exactly here.
- Every line checked → fully carved: `gh issue edit <epic> --remove-label inbox` (keep `epic`).

## 5. Can't be made executable?
Needs a human decision, missing info, or an unbuilt dependency:
```
gh issue edit <n> --remove-label inbox --add-label blocked
gh issue comment <n> --body "Blocked: <exactly what's needed / the decision required>"
```
Never guess on ambiguous scope — a blocked issue with a crisp question beats a wrong task.

## Rules
- One task = one clear outcome. Unsure if it's one or two? Make two.
- Never delete an issue. Never recreate a checked line. Never drop an item.

## Report
Issues triaged, new children created this run, epics still carving (with remaining
unchecked counts), and the current `ready` count.
EOF

cat > .goalloop/playbooks/execute.md <<'EOF'
# Playbook — EXECUTE: implement, test, and PR exactly ONE issue, with maximum care

You are given one issue number **N**. Do ONLY this task. Read `.goalloop/config.yml`
(verify commands, policy, `execute.max_fix_attempts` — default 3) and honor
`AGENTS.md` / `CLAUDE.md`. Use `gh` for GitHub.

## 0. Resume or claim (idempotent)
```
gh issue view N --json number,title,body,labels,state
```
- If it's `blocked`, you lack info to finish, or a `Depends on #M` is not yet `done` →
  STOP, comment why, leave it. Don't start.
- Check for prior work: `gh pr list --state all --head <branch_prefix>task-N-` and the branch.
  - An OPEN PR/branch for N already exists → **resume it** (check it out); don't start over.
  - Otherwise → `gh issue edit N --remove-label ready --add-label in-progress`.

## 1. Understand before touching anything
- Read the issue + its parent epic for the full intent and acceptance criteria.
- Read the actual code you will change, its tests, and its callers. Decide the **smallest
  change that satisfies every acceptance criterion.**
- If reality contradicts the issue (the thing described doesn't exist, or differs) → STOP,
  comment the discrepancy, label `blocked`. Surfacing a wrong assumption beats building wrong.

## 2. Branch
```
git fetch origin && git checkout <default_branch> && git pull --ff-only
git checkout -b <branch_prefix>task-N-<short-slug>
```
The branch MUST start with `git.branch_prefix` from config (some hosts only allow pushes
to that prefix, else the push is rejected and no PR appears).

## 3. Implement — smallest correct change, maximum care
- Match the surrounding code exactly: structure, naming, layers, conventions.
- Touch ONLY what this task needs. No drive-by refactors, no unrelated files, no scope creep.
- Honor every data-safety rule / invariant the repo documents (merge not clobber; confirm +
  reversible destructive actions; etc.). If the task would violate one, STOP and `blocked`.
- **Lock the new logic with a test in the same commit** — it encodes the acceptance criteria
  and would fail without your change.

## 4. Verify — fix-forward, never ship broken
Run each non-empty `verify:` command from config, in order: install → check → build.
- A step fails → diagnose and fix, up to `execute.max_fix_attempts` times (default 3).
- Still failing after the cap, or a real fix would balloon scope → revert the branch to
  clean, comment the exact failure + what you tried, and set the issue back to `ready`
  (or `blocked` if it needs a decision). **NEVER open a PR that doesn't pass the gate.**

## 5. Self-review the diff (be your own strict reviewer)
Re-read `git diff`:
- Does it satisfy EVERY acceptance criterion? Check each off.
- Any scope creep, leftover debug, or convention/data-safety violation? Fix or revert it.
- Is the test meaningful (it fails without the change)?

## 6. Open the PR (never push to the default branch)
```
git add -A && git commit -m "<concise summary> (closes #N)"
git push -u origin HEAD
gh pr create --base <default_branch> --fill \
  --body $'What changed: ...\n\nAcceptance:\n- [x] ...\n\nTests added: ...\nVerify: check OK, build OK\n\nCloses #N'
```
Add a session link if `CLAUDE_CODE_REMOTE_SESSION_ID` is set.

## 7. Hand off
- Leave N `in-progress` (merge closes it; run-queue reconciles to `done`).
- Auto-merge ONLY if `policy.auto_merge: true` AND the issue has `autopilot` AND CI is green
  (`gh pr merge --squash --auto`). Otherwise park for review. If the default branch
  auto-deploys to prod, never merge unreviewed work.

## Report
PR URL, each verify step's pass/fail, acceptance-criteria coverage, and merged-or-awaiting-
review. If you stopped (blocked/failed), state exactly why and what's needed.
EOF

cat > .goalloop/playbooks/run-queue.md <<'EOF'
# Playbook — RUN-QUEUE: one safe unit of progress, then stop.

Read `.goalloop/config.yml`. Use `gh`. Don't drain the whole backlog in one session —
per-task fresh sessions are the point (cheaper, sharper, isolated).

## 1. Reconcile (self-heal the board)
For every `in-progress` issue (`gh issue list --label in-progress --state open --json number,title`):
- Find its PR by branch (`gh pr list --state all --head <branch_prefix>task-<n>- --json number,state,merged`):
  - **merged** → `gh issue edit <n> --remove-label in-progress --add-label done`.
  - **open** → genuinely in flight.
  - **closed, not merged** → `--remove-label in-progress --add-label ready`; comment "needs retry".
  - **no branch/PR at all** (orphaned/stale) → `--remove-label in-progress --add-label ready`;
    comment "reset by reconcile".
- If ANY issue is genuinely in flight (open PR) → **STOP. Do not start another.** Report it
  and exit. (Single-in-flight lock = finish before moving on.)

## 2. Triage
Follow `.goalloop/playbooks/triage.md`: advance `inbox` → `ready`, continuing any half-carved
epic from a prior run. Planning only — no code.

## 3. Pick ONE (priority + dependency aware)
From open `ready` issues choose the highest priority (`priority:high` > `med` > `low`, then
lowest number). SKIP any whose `Depends on #M` is not `done` (re-label those `blocked`).
If nothing is ready: if epics are still carving, say so; else print "queue empty". Exit.

## 4. Execute
Follow `.goalloop/playbooks/execute.md` on that single issue.

## 5. Report
One screen: what you reconciled, triage progress (epics carving + unchecked remaining), the
task executed (PR URL + verify results), and how many `ready` tasks remain.
EOF
say "  wrote:  .goalloop/playbooks/{triage,execute,run-queue}.md"

# --- Issue templates ----------------------------------------------------------
cat > .github/ISSUE_TEMPLATE/config.yml <<EOF
blank_issues_enabled: true
contact_links:
  - name: How this task system works
    url: https://github.com/$SLUG/blob/$DEFAULT_BRANCH/.goalloop/playbooks/run-queue.md
    about: The task loop — add tasks here, they get broken down and executed one at a time.
EOF

cat > .github/ISSUE_TEMPLATE/task.yml <<'EOF'
name: "🟢 Task"
description: "One concrete, shippable change. Triage will sharpen it."
title: "[task] "
labels: ["inbox"]
body:
  - type: textarea
    id: goal
    attributes:
      label: What do you want?
      description: "Plain language. One outcome. Several things? Use the Brain dump template instead."
    validations: { required: true }
  - type: textarea
    id: done
    attributes:
      label: How do we know it's done? (optional)
      description: "Leave blank and triage will propose acceptance criteria."
    validations: { required: false }
  - type: dropdown
    id: priority
    attributes: { label: Priority, options: ["med", "high", "low"], default: 0 }
    validations: { required: true }
EOF

cat > .github/ISSUE_TEMPLATE/brain-dump.yml <<'EOF'
name: "🧠 Brain dump / Big feature"
description: "Dump everything in your head. Triage splits it into separate, executable tasks."
title: "[epic] "
labels: ["inbox", "epic"]
body:
  - type: textarea
    id: dump
    attributes:
      label: Dump it all here
      description: "Don't structure it. List features, fixes, half-ideas. Triage creates one sub-issue per real task."
    validations: { required: true }
  - type: dropdown
    id: priority
    attributes: { label: Overall priority, options: ["med", "high", "low"], default: 0 }
    validations: { required: true }
EOF
say "  wrote:  .github/ISSUE_TEMPLATE/{config,task,brain-dump}.yml"

# --- Label sync workflow (gh-based, self-contained) ---------------------------
cat > .github/workflows/goalloop-labels.yml <<EOF
name: GoalLoop labels

# Creates/updates the lifecycle labels with the gh CLI (preinstalled on runners).
# Idempotent; never deletes labels you made elsewhere. Run from the Actions tab, or
# automatically when this file changes on the default branch.
on:
  push:
    branches: [$DEFAULT_BRANCH]
    paths: [".github/workflows/goalloop-labels.yml"]
  workflow_dispatch:
permissions:
  issues: write
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - env:
          GH_TOKEN: \${{ secrets.GITHUB_TOKEN }}
          GH_REPO: \${{ github.repository }}
        run: |
          set -euo pipefail
          mk() { gh label create "\$1" --color "\$2" --description "\$3" --force; }
          mk inbox           B0BEC5 "New task, not yet triaged."
          mk ready           0E8A16 "Planned and executable. The loop picks these up."
          mk in-progress     FBCA04 "A session is on it (PR open). Single-in-flight lock."
          mk done            5319E7 "Shipped — PR merged."
          mk blocked         D93F0B "Needs a decision, info, or a dependency."
          mk epic            1D76DB "Too big for one task. Split into sub-issues by triage."
          mk "priority:high" B60205 "Do first."
          mk "priority:med"  C5DEF5 "Normal."
          mk "priority:low"  EEEEEE "Whenever."
          mk autopilot       0052CC "Loop may auto-merge this task's PR once CI is green."
          echo "Labels synced."
EOF
say "  wrote:  .github/workflows/goalloop-labels.yml"

# --- Optional universal scheduled runner (shipped disabled, as .example) ------
cat > .github/workflows/goalloop-run.yml.example <<EOF
# OPTIONAL universal scheduled runner — "bring your own agent".
# Rename to goalloop-run.yml, pick ONE agent block, add the API-key secret, commit.
# (Claude Code users: prefer routines /schedule instead — runs on your subscription.)
name: GoalLoop run
on:
  schedule: [{ cron: "0 * * * *" }]   # hourly; adjust
  workflow_dispatch:
permissions: { contents: write, issues: write, pull-requests: write }
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # --- Option A: Claude Code -------------------------------------------------
      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: \${{ secrets.ANTHROPIC_API_KEY }}
          prompt: "Follow the playbook at .goalloop/playbooks/run-queue.md for this repository."
          claude_args: "--allowedTools Bash,Read,Edit,Write"

      # --- Option B: OpenAI Codex (replace Option A with this) -------------------
      # - uses: openai/codex-action@v1
      #   with:
      #     openai_api_key: \${{ secrets.OPENAI_API_KEY }}
      #     prompt: "Follow the playbook at .goalloop/playbooks/run-queue.md for this repository."
      # # ...or the raw CLI:
      # # - run: npm i -g @openai/codex
      # # - env: { CODEX_API_KEY: \${{ secrets.OPENAI_API_KEY }}, GH_TOKEN: \${{ secrets.GITHUB_TOKEN }} }
      # #   run: codex exec --sandbox danger-full-access --ask-for-approval never "Follow .goalloop/playbooks/run-queue.md for this repository."

      # --- Option C: any other agent CLI (e.g. Kimi) -----------------------------
      # - run: npm i -g <agent-cli>          # e.g. kimi
      # - env: { AGENT_API_KEY: \${{ secrets.AGENT_API_KEY }}, GH_TOKEN: \${{ secrets.GITHUB_TOKEN }} }
      #   run: <agent> "Follow .goalloop/playbooks/run-queue.md for this repository."
EOF
say "  wrote:  .github/workflows/goalloop-run.yml.example"

# --- Claude Code adapters (thin → playbooks) ----------------------------------
cat > .claude/commands/triage.md <<'EOF'
---
description: GoalLoop — process the inbox (split big issues, mark tasks ready).
---
Follow the playbook at `.goalloop/playbooks/triage.md` for this repository.
EOF
cat > .claude/commands/execute-issue.md <<'EOF'
---
description: GoalLoop — fully implement + PR one issue. Usage: /execute-issue <n>
argument-hint: <issue-number>
---
Follow the playbook at `.goalloop/playbooks/execute.md` for this repository, with issue number **#$ARGUMENTS**.
EOF
cat > .claude/commands/run-queue.md <<'EOF'
---
description: GoalLoop — one loop pass (reconcile, triage, execute one task).
---
Follow the playbook at `.goalloop/playbooks/run-queue.md` for this repository.
EOF
say "  wrote:  .claude/commands/{triage,execute-issue,run-queue}.md"

# --- AGENTS.md hub (append a marked block, idempotent) ------------------------
MARK_START="<!-- goalloop:start -->"
if [ -f AGENTS.md ] && grep -qF "$MARK_START" AGENTS.md; then
  say "  keep:   AGENTS.md already has the GoalLoop section — left untouched"
else
  [ -f AGENTS.md ] || printf '# Agent guide\n\n' > AGENTS.md
  cat >> AGENTS.md <<'EOF'

<!-- goalloop:start -->
## Task loop

This repo uses **GoalLoop**: tasks are GitHub Issues, executed one at a time.
The universal interface is the `gh` CLI; project specifics live in `.goalloop/config.yml`.

- **Process new tasks (triage):** follow `.goalloop/playbooks/triage.md`.
- **Do one task:** follow `.goalloop/playbooks/execute.md` with an issue number.
- **Run the loop (reconcile → triage → execute one):** follow `.goalloop/playbooks/run-queue.md`.

If a user says "run the task loop" / "drain the queue", follow `run-queue.md`.
<!-- goalloop:end -->
EOF
  say "  wrote:  AGENTS.md (GoalLoop section)"
fi

# --- Claude Code awareness (it reads CLAUDE.md, NOT AGENTS.md) -----------------
# The .claude/commands/* adapters already give Claude Code /triage, /execute-issue,
# /run-queue. This also makes a plain "run the task loop" work by pointing CLAUDE.md
# at the same playbooks.
if [ -f CLAUDE.md ]; then
  if grep -qF "$MARK_START" CLAUDE.md; then
    say "  keep:   CLAUDE.md already has the GoalLoop section — left untouched"
  else
    cat >> CLAUDE.md <<'EOF'

<!-- goalloop:start -->
## Task loop
This repo uses GoalLoop. Run `/run-queue` (or `/triage`, `/execute-issue <n>`), or
follow `.goalloop/playbooks/run-queue.md`. Project config: `.goalloop/config.yml`. See AGENTS.md.
<!-- goalloop:end -->
EOF
    say "  wrote:  CLAUDE.md (GoalLoop pointer)"
  fi
else
  printf '# Project guide for Claude Code\n\n@AGENTS.md\n' > CLAUDE.md
  say "  wrote:  CLAUDE.md (imports AGENTS.md so Claude Code sees the loop)"
fi

# --- Done ---------------------------------------------------------------------
say ""
say "GoalLoop v3 installed (idempotent batched triage · recursive epics · careful execute)."
[ -f CLAUDE.md ] || warn "no CLAUDE.md found — that's fine; the loop reads .goalloop/config.yml + AGENTS.md."
case "${CHECK_CMD}" in "") warn "couldn't auto-detect a test command — edit verify.check in .goalloop/config.yml.";; esac
say ""
say "Next steps:"
say "  1. Fill in .goalloop/config.yml (the 'project:' line + verify commands)."
say "  2. Commit to a '${DEFAULT_BRANCH}'-bound branch and merge (templates/labels"
say "     only activate on the default branch)."
say "  3. Actions tab → 'GoalLoop labels' → Run workflow (creates the labels)."
say "  4. Add a task: Issues → New issue → Task or Brain dump."
say "  5. Drive it: tell your agent \"run the task loop\" (it reads AGENTS.md),"
say "     or in Claude Code run /run-queue. To automate, see goalloop-run.yml.example"
say "     or Claude routines (/schedule)."
