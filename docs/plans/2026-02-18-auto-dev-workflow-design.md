# Auto-Dev: Multi-Terminal Agentic AI Workflow

**Date:** 2026-02-18
**Status:** Approved

## Overview

Auto-Dev is a multi-agent development workflow that orchestrates Claude CLI agents across separate tmux terminal panes. A dev agent implements features from markdown specs, a reviewer agent enforces repo-specific coding standards, and the dev agent iterates on feedback — all visible in parallel terminals with a live summary dashboard.

## Key Decisions

| Decision | Choice |
|----------|--------|
| Platform | Claude Code CLI agents in tmux panes |
| Input | Spec markdown files |
| Communication | Shared files in `.auto-dev/messages/` |
| Loop control | Fixed rounds (configurable, default 3) |
| Review skills | Repo-configurable via `.auto-dev/config.yaml` |
| Standards | Repo's `CLAUDE.md` |
| App monitoring | Generic user-defined command, stdout piped to log |
| Dev agents | Configurable count (1 or auto-split by spec) |
| Output | Feature branch + PR with review history |
| Delivery | Claude Code slash command + standalone shell script |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    tmux session: auto-dev                │
├──────────────────┬──────────────────┬───────────────────┤
│   Dev Agent(s)   │  Reviewer Agent  │   App Runner      │
│   (claude cli)   │  (claude cli)    │   (user command)  │
│                  │                  │                   │
│  Reads: spec.md  │  Reads: git diff │   Runs: config    │
│  Writes: code    │  Writes: review  │   defined command │
│  Reads: review   │  Reads: app logs │   Writes: stdout  │
│  Reads: app logs │                  │   to shared file  │
├──────────────────┴──────────────────┴───────────────────┤
│                   Summary Dashboard                      │
│  Reads all shared files, shows: round #, status,         │
│  review score, failures detected, agent activity          │
└─────────────────────────────────────────────────────────┘
```

Each agent runs as a separate `claude` CLI process in its own tmux pane. Agents communicate exclusively through shared files in `.auto-dev/messages/`. No agent writes to another agent's files.

## Communication Layer

```
.auto-dev/
├── config.yaml              # Workflow settings (per repo)
├── messages/
│   ├── spec.md              # Input spec (copied or symlinked)
│   ├── dev-1-status.json    # Dev agent 1 status/output
│   ├── dev-2-status.json    # Dev agent 2 (if multi-dev)
│   ├── reviewer-feedback.md # Reviewer's structured feedback
│   ├── app-output.log       # App runner stdout/stderr
│   └── summary.json         # Aggregated state for dashboard
└── skills/                  # Repo-specific review skills
    ├── code-review.md
    ├── security-check.md
    └── test-coverage.md
```

### Status JSON Schema (dev agent)

```json
{
  "status": "done | in_progress | error",
  "round": 1,
  "files_changed": ["path/to/file.go"],
  "tests_passed": true,
  "app_healthy": true,
  "error_message": null
}
```

### Reviewer Feedback Schema (reviewer-feedback.md)

```markdown
# Review: Round N

## Verdict: approved | changes_requested

## Summary
<brief overall assessment>

## Findings

### CRITICAL
- [file:line] Description of issue

### HIGH
- [file:line] Description of issue

### MEDIUM
- [file:line] Description of issue

### LOW
- [file:line] Description of issue

## Score: X/10
```

## Config Format

```yaml
# .auto-dev/config.yaml

project:
  name: "my-service"
  repo_path: "."

workflow:
  max_rounds: 3
  dev_agents: 1                     # number or "auto"
  branch_prefix: "auto-dev/"

spec:
  path: "docs/specs/"

app_runner:
  command: "go run ./cmd/server"
  health_check: "curl -s http://localhost:8080/health"
  watch_patterns:
    - "panic:"
    - "FAIL"
    - "Error:"
    - "fatal"

reviewer:
  skills:
    - "code-review"
    - "security-review"
    - "test-coverage"
  standards_file: "CLAUDE.md"
  severity_gate: "high"

summary:
  refresh_interval: 5
```

## Workflow Lifecycle

### Phase 1: Setup

1. Read `.auto-dev/config.yaml`
2. Create tmux session with panes (dev, reviewer, app runner, summary)
3. Start app runner pane with the configured command
4. Create feature branch: `auto-dev/<spec-name>`
5. Copy spec to `.auto-dev/messages/spec.md`
6. Initialize `summary.json` with round 0 state

### Phase 2: Development (Round 1)

6. Dev agent(s) launch in their panes
   - Read `spec.md`
   - Read `CLAUDE.md` for coding standards
   - Implement the feature
   - Run tests
   - Poll `app-output.log` for failure patterns
   - If app failure detected, fix before continuing
   - Write `dev-N-status.json` with status "done"
   - Git commit on feature branch

### Phase 3: Review

7. Reviewer agent launches in its pane
   - Detect dev status files show "done"
   - Run `git diff` against base branch
   - Invoke each skill listed in `config.yaml`
   - Poll `app-output.log` for runtime issues
   - Write `reviewer-feedback.md` with structured findings
   - Write verdict: "approved" or "changes_requested"

### Phase 4: Iteration (Rounds 2..N)

8. If verdict = "changes_requested" AND round < max_rounds:
   - Dev agent reads `reviewer-feedback.md`
   - Addresses each finding by severity (critical first)
   - Polls `app-output.log` again
   - Updates `dev-N-status.json`
   - Git commit
   - Back to Phase 3

9. If verdict = "approved" OR round >= max_rounds:
   - Proceed to Phase 5

### Phase 5: Finalize

10. Create PR with:
    - Spec summary
    - Review history from all rounds
    - Final reviewer verdict and score
    - App health status
11. Summary dashboard shows final report
12. Optionally kill tmux panes or leave open for inspection

## Summary Dashboard

The summary pane runs a shell script polling `.auto-dev/messages/summary.json`:

```
╔══════════════════════════════════════════════╗
║          AUTO-DEV: my-feature                ║
╠══════════════════════════════════════════════╣
║ Spec:    docs/specs/add-auth.md              ║
║ Branch:  auto-dev/add-auth                   ║
║ Round:   2 / 3                               ║
╠══════════════════════════════════════════════╣
║ AGENTS                                       ║
║  Dev-1:     ● implementing (12 files changed)║
║  Dev-2:     ● idle                           ║
║  Reviewer:  ○ waiting                        ║
║  App:       ● running (healthy)              ║
╠══════════════════════════════════════════════╣
║ REVIEW (Round 1)                             ║
║  Critical: 0  High: 1  Medium: 3  Low: 5    ║
║  Verdict:  changes_requested                 ║
╠══════════════════════════════════════════════╣
║ APP OUTPUT (last 3 lines)                    ║
║  [INFO] Server started on :8080              ║
║  [INFO] GET /health 200 1ms                  ║
║  [INFO] Connected to database                ║
╚══════════════════════════════════════════════╝
```

## Agent Prompt Templates

Located at `.auto-dev/prompts/`:

### dev-agent.md

Defines the dev agent role:
- Read spec from `.auto-dev/messages/spec.md`
- Follow coding standards from `CLAUDE.md`
- In rounds > 1, read and address `reviewer-feedback.md`
- Poll `app-output.log` for failure patterns
- Write status to `dev-N-status.json`
- Git commit with prefix `auto-dev:`

### reviewer-agent.md

Defines the reviewer agent role:
- Wait for dev status "done"
- Run `git diff` against base branch
- Invoke each configured review skill
- Read `app-output.log` for runtime issues
- Write structured feedback to `reviewer-feedback.md`
- Severity gate: block unless no issues at or above configured severity

### orchestrator.md

Defines the orchestrator logic:
- Manage round transitions
- Poll dev and reviewer status files
- Update `summary.json`
- Trigger phase transitions
- Handle max rounds exhaustion

## Delivery

### Claude Code Skill: `/auto-dev`

Installed at `~/.claude/commands/auto-dev.md` or per-repo `.claude/commands/`.

```
> /auto-dev docs/specs/add-auth.md
```

The skill reads config, launches tmux, spawns agents, and uses the invoking terminal as the summary dashboard.

### Standalone Script: `auto-dev.sh`

```bash
./auto-dev.sh --spec docs/specs/add-auth.md --repo /path/to/repo
```

For CI/automation:
- Creates tmux session in detached mode (or runs sequentially)
- Outputs summary to stdout and report file
- Exit code 0 if PR created, non-zero if max rounds exhausted
- Can be called from GitHub Actions, cron, etc.

## Project Structure

```
auto-dev/
├── auto-dev.sh                  # Standalone launcher script
├── lib/
│   ├── tmux-setup.sh            # Creates tmux session + panes
│   ├── orchestrator.sh          # Round management, polling, transitions
│   ├── summary-watcher.sh       # Dashboard renderer
│   └── config-parser.sh         # Reads .auto-dev/config.yaml
├── prompts/
│   ├── dev-agent.md             # Dev agent system prompt template
│   ├── reviewer-agent.md        # Reviewer agent system prompt template
│   └── orchestrator.md          # Orchestrator prompt
├── skills/
│   └── auto-dev.md              # Claude Code slash command skill
├── templates/
│   ├── config.yaml              # Default .auto-dev/config.yaml template
│   └── init.sh                  # `auto-dev init` to scaffold .auto-dev/ in a repo
└── README.md
```
