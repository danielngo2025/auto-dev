# auto-dev

Multi-terminal agentic AI workflow that orchestrates Claude CLI agents across tmux panes. A dev agent implements features from markdown specs, a reviewer agent enforces repo-specific coding standards, and the dev agent iterates on feedback — all visible in parallel terminals with a live summary dashboard.

```
┌─────────────────────────────────────────────────────────┐
│                    tmux session: auto-dev                │
├──────────────────┬──────────────────┬───────────────────┤
│   Dev Agent(s)   │  Reviewer Agent  │   App Runner      │
│   (claude cli)   │  (claude cli)    │   (user command)  │
├──────────────────┴──────────────────┴───────────────────┤
│                   Summary Dashboard                      │
└─────────────────────────────────────────────────────────┘
```

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- [tmux](https://github.com/tmux/tmux) 3.0+
- [jq](https://jqlang.github.io/jq/) 1.6+
- [yq](https://github.com/mikefarah/yq) 4.0+
- [gh](https://cli.github.com/) (GitHub CLI, for PR creation)

### Install dependencies (macOS)

```bash
brew install tmux yq jq gh
```

## Quick Start

### 1. Clone auto-dev

```bash
git clone <repo-url> ~/auto-dev
```

### 2. Initialize your project repo

```bash
bash ~/auto-dev/templates/init.sh /path/to/your/repo
```

This creates a `.auto-dev/` directory in your repo with:

```
.auto-dev/
├── config.yaml     # Workflow settings (edit this)
├── messages/       # Agent communication files (runtime)
├── prompts/        # Agent prompt templates
└── skills/         # Repo-specific review skills
```

### 3. Configure

Edit `.auto-dev/config.yaml` in your repo:

```yaml
project:
  name: "my-service"
  repo_path: "."

workflow:
  max_rounds: 3          # Max dev-review iterations
  dev_agents: 1           # Number of parallel dev agents
  branch_prefix: "auto-dev/"

spec:
  path: "docs/specs/"

app_runner:
  command: "go run ./cmd/server"   # Your app start command
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
  standards_file: "CLAUDE.md"      # Your repo's coding standards
  severity_gate: "high"            # Block until no issues >= this

summary:
  refresh_interval: 5
```

### 4. Write a spec

Create a markdown spec file describing the feature:

```bash
cat > docs/specs/add-auth.md << 'EOF'
# Add Authentication

## Requirements
- Add JWT-based authentication middleware
- Protect all /api/* routes
- Add login endpoint at POST /auth/login
- Return 401 for unauthenticated requests

## Acceptance Criteria
- All existing tests continue to pass
- New tests cover auth middleware and login endpoint
- No hardcoded secrets
EOF
```

### 5. Run

```bash
bash ~/auto-dev/auto-dev.sh --spec docs/specs/add-auth.md --repo .
```

This opens a tmux session with four panes where you can watch the agents work in real time.

## Usage

```
auto-dev.sh --spec <spec.md> --repo <path> [--dry-run] [--detached]
```

| Flag | Description |
|------|-------------|
| `--spec <file>` | Path to the feature spec markdown file (required) |
| `--repo <path>` | Path to the target repository (default: `.`) |
| `--dry-run` | Show the execution plan without running |
| `--detached` | Run tmux session in detached mode (for CI/automation) |

### Dry run

Preview what will happen without executing:

```bash
bash ~/auto-dev/auto-dev.sh --spec docs/specs/add-auth.md --repo . --dry-run
```

Output:

```
=== Dry run: Auto-Dev Execution Plan ===

Project:      my-service
Spec:         docs/specs/add-auth.md
Branch:       auto-dev/add-auth
Dev agents:   1
Max rounds:   3
App command:  go run ./cmd/server
Review skills: code-review security-review
Severity gate: high

Panes: summary | app-runner | reviewer | dev-1

Dry run complete. Remove --dry-run to execute.
```

### Detached mode (CI)

Run headless for automation pipelines:

```bash
bash ~/auto-dev/auto-dev.sh --spec docs/specs/add-auth.md --repo . --detached
```

Attach later with:

```bash
tmux attach -t auto-dev-my-service
```

## How It Works

### Workflow Phases

```
Setup → Development → Review → Iteration → Finalize
                        ↑          │
                        └──────────┘  (up to max_rounds)
```

**Phase 1: Setup**
- Reads `.auto-dev/config.yaml`
- Creates tmux session with panes
- Starts the app runner
- Creates feature branch

**Phase 2: Development**
- Dev agent reads the spec
- Implements the feature following `CLAUDE.md` standards
- Runs tests
- Monitors app output for failures
- Commits and writes status

**Phase 3: Review**
- Reviewer agent diffs the changes
- Runs each configured review skill
- Checks app output for runtime issues
- Writes structured feedback with severity ratings
- Gives verdict: `approved` or `changes_requested`

**Phase 4: Iteration**
- If `changes_requested` and under `max_rounds`: dev agent reads feedback, fixes issues, reviewer reviews again
- If `approved` or at `max_rounds`: proceed to finalize

**Phase 5: Finalize**
- Creates a PR with spec summary, review history, and final verdict

### Agent Communication

Agents communicate through shared files in `.auto-dev/messages/`:

| File | Written by | Read by |
|------|-----------|---------|
| `spec.md` | Launcher | Dev agent |
| `dev-N-status.json` | Dev agent | Reviewer, Orchestrator |
| `reviewer-feedback.md` | Reviewer | Dev agent |
| `app-output.log` | App runner | Dev agent, Reviewer |
| `summary.json` | Orchestrator | Dashboard |

### Summary Dashboard

The bottom tmux pane shows a live dashboard:

```
╔══════════════════════════════════════════════════╗
║  AUTO-DEV: add-auth                              ║
╠══════════════════════════════════════════════════╣
║  Spec:    docs/specs/add-auth.md                 ║
║  Branch:  auto-dev/add-auth                      ║
║  Round:   2 / 3                                  ║
║  Phase:   iteration                              ║
╠══════════════════════════════════════════════════╣
║  AGENTS                                          ║
║    ● Dev-1: implementing (12 files)              ║
║    ○ Reviewer: waiting                           ║
║    ● App: running (healthy)                      ║
╠══════════════════════════════════════════════════╣
║  REVIEW (Round 1)                                ║
║    Critical: 0  High: 1  Medium: 3  Low: 5      ║
║    Verdict: changes_requested                    ║
╠══════════════════════════════════════════════════╣
║  APP OUTPUT (last 3 lines)                       ║
║    [INFO] Server started on :8080                ║
║    [INFO] GET /health 200 1ms                    ║
║    [INFO] Connected to database                  ║
╚══════════════════════════════════════════════════╝
```

## Configuration

### Reviewer Skills

Each repo defines which review checks to run. Add skill names to `reviewer.skills` in your config:

```yaml
reviewer:
  skills:
    - "code-review"        # General code quality
    - "security-review"    # Security vulnerability scan
    - "test-coverage"      # Test coverage verification
```

These map to Claude Code skills or custom skills in `.auto-dev/skills/`.

### Severity Gate

The `severity_gate` controls when the reviewer approves:

| Gate | Meaning |
|------|---------|
| `critical` | Only block on critical issues |
| `high` | Block on critical + high issues |
| `medium` | Block on critical + high + medium issues |
| `low` | Block on any issue |

### Multiple Dev Agents

For large features, split work across multiple agents:

```yaml
workflow:
  dev_agents: 3    # Spawns 3 dev panes
```

Or set to `"auto"` to let the orchestrator split the spec into sub-tasks.

### App Runner

Configure the command to start your application:

```yaml
app_runner:
  command: "npm run dev"
  health_check: "curl -s http://localhost:3000"
  watch_patterns:
    - "Error:"
    - "FAIL"
    - "TypeError"
    - "Cannot find module"
```

Set `command: ""` to disable app monitoring.

### Watch Patterns

Strings to watch for in the app runner output. If any pattern appears, the dev agent attempts to fix the issue before continuing.

## Claude Code Skill

Install the `/auto-dev` slash command:

```bash
cp ~/auto-dev/skills/auto-dev.md ~/.claude/commands/auto-dev.md
```

Then use it in any Claude Code session:

```
> /auto-dev docs/specs/add-auth.md
```

## Customizing Prompt Templates

Agent behavior is defined in `.auto-dev/prompts/`:

| File | Controls |
|------|----------|
| `dev-agent.md` | How the dev agent implements features |
| `reviewer-agent.md` | What the reviewer checks and how it reports |
| `orchestrator.md` | Phase transition logic |

Templates use `{{PLACEHOLDER}}` syntax. Available placeholders:

| Placeholder | Source |
|-------------|--------|
| `{{STANDARDS_FILE}}` | `reviewer.standards_file` from config |
| `{{WATCH_PATTERNS}}` | `app_runner.watch_patterns` from config |
| `{{AGENT_ID}}` | Dev agent number (1, 2, ...) |
| `{{ROUND}}` | Current round number |
| `{{REVIEWER_SKILLS}}` | `reviewer.skills` from config |
| `{{SEVERITY_GATE}}` | `reviewer.severity_gate` from config |
| `{{BASE_BRANCH}}` | Base branch for git diff |
| `{{SKILLS_LIST}}` | Formatted list of review skills |
| `{{MAX_ROUNDS}}` | `workflow.max_rounds` from config |
| `{{PHASE}}` | Current workflow phase |

Edit these templates to customize agent behavior for your team's workflow.

## Project Structure

```
auto-dev/
├── auto-dev.sh              # Main launcher script
├── lib/
│   ├── config-parser.sh     # YAML config → shell variables
│   ├── tmux-setup.sh        # tmux session/pane management
│   ├── orchestrator.sh      # Round management, state transitions
│   ├── prompt-renderer.sh   # {{PLACEHOLDER}} substitution
│   └── summary-watcher.sh   # Live TUI dashboard
├── prompts/
│   ├── dev-agent.md         # Dev agent system prompt
│   ├── reviewer-agent.md    # Reviewer agent system prompt
│   └── orchestrator.md      # Orchestrator system prompt
├── skills/
│   └── auto-dev.md          # Claude Code /auto-dev skill
├── templates/
│   ├── config.yaml          # Default config template
│   └── init.sh              # Repo scaffolding script
├── tests/                   # 70 bats tests
└── docs/plans/              # Design and implementation docs
```

## Running Tests

```bash
# Run all tests
bats tests/*.bats

# Run a specific test file
bats tests/orchestrator.bats

# Run with verbose output
bats tests/*.bats --verbose-run
```

## Troubleshooting

### tmux session already exists

```bash
tmux kill-session -t auto-dev-<project-name>
```

### Agent not starting

Check that the Claude CLI is installed and authenticated:

```bash
claude --version
claude "hello"
```

### App runner not working

Verify the command in your config works standalone:

```bash
cd /your/repo && <your-app-command>
```

### Review never completes

Check `.auto-dev/messages/reviewer-feedback.md` for the reviewer's output. The reviewer waits for all dev status files to show `"status": "done"` before starting.

### Stale state from previous run

Clear the messages directory:

```bash
rm -rf .auto-dev/messages/*
```
