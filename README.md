# spex

Agentic AI workflow that orchestrates Claude CLI agents to implement features from markdown specs. Dev and reviewer agents run in parallel terminal tabs with live-streaming output, elapsed timers, and token tracking.

```
Spec (.md) → Dev Agent → Review Agent → Iterate → Commit → PR
                 ↑             │
                 └─────────────┘  (up to max_rounds)

Main tab:  orchestrator (timer, status, ESC to abort)
Tab 2:     dev agent (live streaming output)
Tab 3:     reviewer (live streaming output)
Tab 4:     app runner (background process logs)
```

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- [jq](https://jqlang.github.io/jq/) 1.6+
- [yq](https://github.com/mikefarah/yq) 4.0+
- [gh](https://cli.github.com/) (GitHub CLI, for PR creation)

### Install dependencies (macOS)

```bash
brew install yq jq gh
```

## Quick Start

### 1. Clone spex

```bash
git clone <repo-url> ~/spex
```

### 2. Initialize your project repo

```bash
bash ~/spex/init.sh /path/to/your/repo
```

To include skills from a remote repo:

```bash
bash ~/spex/init.sh --skills-repo vendasta/dev-agent-toolkit /path/to/your/repo
```

This creates a `.specify/` directory in your repo with:

```
.specify/
├── config.yaml     # Workflow settings (edit this)
├── messages/       # Agent communication files (runtime)
├── prompts/        # Agent prompt templates
├── specs/          # Feature specs go here
│   └── chunks/     # Manual chunk files (optional)
└── skills/         # Repo-specific review skills
```

### 3. Configure

Edit `.specify/config.yaml` in your repo:

```yaml
project:
  name: "my-service"
  repo_path: "."

workflow:
  max_rounds: 3          # Max dev-review iterations
  dev_agents: 1          # Number of dev agents (run sequentially)
  dev_model: "sonnet"
  reviewer_model: "haiku"
  agent_timeout: 900     # Max seconds per agent invocation
  dev_fallback_model: "opus"   # Retry on timeout/empty output
  phases:
    plan: true           # Run planner (requires chunking)
    dev: true            # Run dev agent(s)
    review: true         # Run reviewer (false = auto-approve)
    commit: true         # Git commit after completion
    pr: true             # Push + PR creation

app_runner:
  command: "go run ./cmd/server"   # Your app start command
  health_check: "curl -s http://localhost:8080/health"
  watch_patterns:
    - "panic:"
    - "FAIL"

reviewer:
  skills:
    - "code-review"
    - "security-review"
  standards_file: "CLAUDE.md"
  severity_gate: "high"

permissions:
  dev_tools: "Edit,Write,Read,Bash,Grep,Glob"
  reviewer_tools: "Read,Write,Bash,Grep,Glob"
```

### 4. Write a spec

```bash
cat > .specify/specs/add-auth.md << 'EOF'
# Add Authentication

## Requirements
- Add JWT-based authentication middleware
- Protect all /api/* routes
- Return 401 for unauthenticated requests

## Acceptance Criteria
- All existing tests continue to pass
- New tests cover auth middleware
- No hardcoded secrets
EOF
```

### 5. Run

```bash
bash ~/spex/spex.sh --repo .
```

Spex auto-discovers spec files in `.specify/specs/`. You can also specify one directly:

```bash
bash ~/spex/spex.sh --spec .specify/specs/add-auth.md --repo .
```

## Usage

```
spex.sh [--spec <spec.md>] --repo <path> [--dry-run]
```

| Flag | Description |
|------|-------------|
| `--spec <file>` | Path to the feature spec (default: auto-discover from `.specify/specs/`) |
| `--repo <path>` | Path to the target repository (default: `.`) |
| `--dry-run` | Show the execution plan without running |

### Dry run

```bash
bash ~/spex/spex.sh --repo . --dry-run
```

## How It Works

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full system design.

### Workflow Phases

1. **Setup** — Reads config, starts app runner in a new terminal tab
2. **Planning** (optional) — Planner agent decomposes spec into chunks
3. **Development** — Dev agent(s) run in parallel, each in its own terminal tab with live output. Main tab shows elapsed timer.
4. **Review** — Reviewer runs in its own tab. Main tab polls for verdict with timer.
5. **Iteration** — If `changes_requested` and under `max_rounds`: dev fixes issues
6. **Finalize** — Shows total tokens consumed. Prompts for approval, commits, creates PR.

### Controls

- **ESC** — Abort the current agent (dev or reviewer) during its run
- **Ctrl+C** — Abort the entire workflow

### Agent Communication

Agents coordinate through shared files in `.specify/messages/`:

| File | Written by | Read by |
|------|-----------|---------|
| `spec.md` | Launcher | Dev agent |
| `dev-N-status.json` | Dev agent | Orchestrator |
| `reviewer-feedback.md` | Reviewer | Dev agent |
| `app-output.log` | App runner | Dev agent, Reviewer |
| `summary.json` | Orchestrator | Dashboard |
| `prior-context.md` | Orchestrator | Dev agent (next round) |

## Configuration

### Phase Toggles

Disable phases you don't need:

```yaml
workflow:
  phases:
    review: false   # Skip review, auto-approve
    pr: false       # Don't create PR
```

### Retry with Fallback

If an agent times out or produces no output, retry with a different model:

```yaml
workflow:
  dev_fallback_model: "opus"
  reviewer_fallback_model: "sonnet"
```

### Permission Tiers

Control which Claude tools each agent can use:

```yaml
permissions:
  dev_tools: "Edit,Write,Read,Bash,Grep,Glob"
  reviewer_tools: "Read,Grep,Glob"          # Read-only reviewer
```

### Context Compaction

Summarize agent logs between rounds to reduce token usage:

```yaml
context_compaction:
  enabled: true
  model: "haiku"
  max_log_chars: 50000
```

### Chunking

Break large features into sequential chunks:

**Auto-chunking** (planner agent decomposes the spec):

```yaml
chunking:
  enabled: true
  max_chunks: 5
  planner_model: "sonnet"
```

**Manual chunks** (you create the files):

```
.specify/specs/chunks/
├── 01-setup-models.md
├── 02-add-api-routes.md
└── 03-write-tests.md
```

### Severity Gate

| Gate | Blocks on |
|------|-----------|
| `critical` | Critical issues only |
| `high` | Critical + high issues |
| `medium` | Critical + high + medium |
| `low` | Any issue |

### Skip Specs

Skip specific chunk files:

```yaml
skip_specs:
  - "01-setup.md"    # Already done
```

## Customizing Prompts

Agent behavior is defined in `.specify/prompts/`:

| File | Controls |
|------|----------|
| `dev-agent.md` | How the dev agent implements features |
| `reviewer-agent.md` | What the reviewer checks and how it reports |
| `planner-agent.md` | How the planner decomposes specs into chunks |

Templates use `{{PLACEHOLDER}}` syntax. Available placeholders:

| Placeholder | Source |
|-------------|--------|
| `{{STANDARDS_FILE}}` | `reviewer.standards_file` |
| `{{WATCH_PATTERNS}}` | `app_runner.watch_patterns` |
| `{{AGENT_ID}}` | Dev agent number (1, 2, ...) |
| `{{ROUND}}` | Current round number |
| `{{SEVERITY_GATE}}` | `reviewer.severity_gate` |
| `{{SKILLS_LIST}}` | Formatted list of review skills |
| `{{MAX_CHUNKS}}` | `chunking.max_chunks` |

## Running Tests

```bash
bats tests/*.bats
```

## Troubleshooting

### Agent not starting

Check that the Claude CLI is installed and authenticated:

```bash
claude --version
claude "hello"
```

### App runner not working

Verify the command works standalone:

```bash
cd /your/repo && <your-app-command>
```

### Review never completes

Check `.specify/messages/reviewer-feedback.md` for the reviewer's output.

### Stale state from previous run

```bash
rm -rf .specify/messages/*
```
