# Architecture

## Overview

Spex is a bash-based orchestrator that coordinates Claude CLI agents to implement features from markdown specs. Agents run as background processes in separate terminal tabs with live-streaming output. The orchestrator stays in the main tab, showing elapsed timers and polling for completion.

```
┌─────────────────────────────────────────────────────────┐
│  Main Tab: spex.sh → _orchestrator.sh                   │
│  (timer, status polling, ESC to abort, token tracking)  │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Tab: App Runner ─────── tail -F app-output.log         │
│  Tab: Dev Agent 1 ────── tail -F dev-1-r1.log           │
│  Tab: Dev Agent N ────── tail -F dev-N-r1.log           │
│  Tab: Reviewer ────────── tail -F reviewer-r1.log       │
│                                                         │
│  Agents run as background processes (script -qF + PTY)  │
│  writing to log files. Tabs show live output via tail.   │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │          .specify/messages/                       │   │
│  │  (file-based agent coordination protocol)         │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Project Structure

```
spex/
├── spex.sh                 # Main entry point
├── init.sh                 # Repo scaffolding (creates .specify/)
├── lib/
│   ├── config-parser.sh    # YAML config → shell variables
│   ├── orchestrator.sh     # Workflow state management
│   ├── prompt-renderer.sh  # {{PLACEHOLDER}} substitution
│   ├── summary-watcher.sh  # TUI dashboard renderer
│   └── terminal.sh         # Terminal tab management (macOS)
├── prompts/
│   ├── dev-agent.md        # Dev agent system prompt template
│   ├── reviewer-agent.md   # Reviewer system prompt template
│   ├── planner-agent.md    # Planner system prompt template
│   └── orchestrator.md     # Orchestrator prompt (informational)
├── templates/
│   └── config.yaml         # Default config template
├── skills/
│   └── spex.md             # Claude Code /spex skill
├── tests/                  # 85 bats tests
└── docs/plans/             # Design documents
```

## Execution Flow

### 1. Entry Point (`spex.sh`)

```
Parse CLI args → Resolve spec files → Load config → Setup messages dir
    → Generate _orchestrator.sh → Start app runner → Run orchestrator
```

The entry point handles:
- Argument parsing (`--spec`, `--repo`, `--dry-run`)
- Spec auto-discovery from `.specify/specs/` and `.specify/specs/chunks/`
- Config loading via `parse_config` (YAML → shell variables)
- Manual chunk detection and `plan.json` generation
- Skip-spec filtering
- Writing the `_run-claude.sh` agent wrapper
- Generating `_orchestrator.sh` as a heredoc with baked-in config values
- Starting the app runner as a background process with terminal tab
- Running the orchestrator inline (blocking) in the main tab

### 2. Orchestrator (`_orchestrator.sh`)

Generated at runtime via heredoc. All config values are baked in at write time (no config re-reading at runtime). The orchestrator manages:

**Planning phase** (if chunking enabled):
- Manual chunks: reads pre-built `plan.json`
- Auto chunks: runs planner agent to decompose spec, prompts user to approve plan

**Chunk loop** (outer):
- Iterates over chunks, creates a git branch per chunk
- Swaps `spec.md` with current chunk content

**Dev/review loop** (inner, per chunk):
1. Render dev prompt with current context
2. Launch dev agent(s) as background processes, each in a new terminal tab
3. Poll `check_dev_status` with elapsed timer; ESC aborts agents
4. Optionally compact dev logs (context compaction)
5. Launch reviewer as background process in a new terminal tab
6. Poll `get_review_verdict` with elapsed timer; ESC aborts reviewer
7. Display token usage after each phase
8. If `changes_requested` and under `max_rounds`: commit WIP, build `prior-context.md`, loop
9. If `approved` or at `max_rounds`: break

**Finalization**:
- Displays total tokens consumed
- Prompts user for approval (y/d/n)
- Commits, creates PR via `gh pr create`

### 3. Agent Runner (`_run-claude.sh`)

Wrapper around `claude -p` that handles:
- Tool permissions (`--allowedTools`)
- Model selection (`--model`)
- Timeout enforcement (`timeout Ns`)
- PTY allocation via `script -qF` for real-time streaming output
- Retry with fallback model on timeout or empty output
- Token/cost estimation logging

### 4. Terminal Tab Management (`lib/terminal.sh`)

Opens new terminal tabs on macOS for each agent process. Detects iTerm2 vs Terminal.app via `$TERM_PROGRAM` and uses `osascript`. Each tab runs `tail -F` on the agent's log file for live output. No-ops on non-macOS platforms.

### 5. File-Based Coordination

Agents don't communicate directly. All coordination happens through files in `.specify/messages/`:

```
                    _orchestrator.sh
                    (reads/writes)
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
    summary.json    dev-N-status.json  reviewer-feedback.md
    plan.json       prior-context.md   costs.log / tokens.log
    spec.md         app-output.log
```

| File | Purpose |
|------|---------|
| `summary.json` | Workflow state (round, phase, agent statuses) |
| `spec.md` | Current spec being implemented |
| `plan.json` | Chunk decomposition (planner output) |
| `dev-N-status.json` | Dev agent completion status |
| `dev-N-rR.log` | Dev agent output log (agent N, round R) |
| `reviewer-feedback.md` | Structured review with verdict |
| `reviewer-rR.log` | Reviewer output log |
| `prior-context.md` | Context from previous round for next dev iteration |
| `app-output.log` | App runner stdout/stderr |
| `costs.log` / `tokens.log` | Cumulative usage tracking |

## Config System

Config lives in `.specify/config.yaml` and is parsed by `lib/config-parser.sh` into `CFG_*` shell variables. The parser uses `yq` with null-coalescing defaults.

Key design decision: boolean fields (`phases.*`, `context_compaction.enabled`) use a `${_val/null/true}` pattern instead of `yq`'s `//` operator, because `yq` treats `false` as falsy and would apply the default.

### Config Sections

| Section | Controls |
|---------|----------|
| `project` | Name, repo path |
| `workflow` | Rounds, agents, models, timeouts, fallbacks, phases |
| `permissions` | Tool allowlists per agent role |
| `app_runner` | Background process, health check, watch patterns |
| `reviewer` | Skills, standards file, severity gate |
| `chunking` | Auto-decomposition settings |
| `context_compaction` | Log summarization between rounds |
| `skip_specs` | Chunk files to skip |

## Library Modules

### `lib/orchestrator.sh`

Pure functions for workflow state management. No I/O side effects beyond reading/writing JSON files.

| Function | Purpose |
|----------|---------|
| `init_workflow` | Creates initial `summary.json` |
| `check_dev_status` | Checks if all dev agents reported done |
| `get_review_verdict` | Reads verdict from reviewer feedback |
| `should_continue` | Determines if loop should iterate |
| `update_summary_phase` | Updates phase in summary |
| `increment_round` | Bumps round counter |
| `get_total_cost` / `get_total_tokens` | Sums usage logs |
| `print_agent_summary` | Prints tail of agent log |
| `update_summary_chunk` | Updates chunk tracking fields |
| `update_agent_status` | Updates per-agent status |

### `lib/config-parser.sh`

Single `parse_config()` function that reads YAML and exports `CFG_*` variables. Handles arrays (skills, watch patterns, skip specs) by iterating with indexed `yq` reads.

### `lib/prompt-renderer.sh`

Simple `{{PLACEHOLDER}}` → value substitution using `sed`. Templates live in `.specify/prompts/`.

### `lib/summary-watcher.sh`

Renders a TUI dashboard from `summary.json`. Used for monitoring workflow state. Box-drawing characters, agent status icons, review findings display.

## Design Decisions

**Background agents with terminal tabs**: Agents run as background processes writing to log files. Each agent gets a dedicated terminal tab running `tail -F` for live output. The orchestrator polls status files and shows an elapsed timer.

**PTY allocation via `script -qF`**: Claude CLI buffers output when not connected to a terminal. Using `script -qF` allocates a pseudo-TTY so output streams in real-time to log files, enabling live `tail -F` visibility.

**ESC to abort current agent**: During polling loops, the orchestrator reads keystrokes from `/dev/tty`. ESC kills the active agent PIDs without aborting the entire workflow.

**Heredoc-generated orchestrator**: The orchestrator script is generated as a heredoc with config values baked in. This avoids re-reading config at runtime and ensures the orchestrator is self-contained.

**File-based coordination**: Agents write status/feedback files (`dev-N-status.json`, `reviewer-feedback.md`). The orchestrator polls these during the timer loop to detect completion.

**Ctrl+C abort**: INT/TERM trap cleans up all tracked PIDs (dev agents, reviewer, app runner) and updates summary phase to "aborted".

**Context passing between rounds**: After each dev/review round, the orchestrator builds `prior-context.md` summarizing what happened (files modified, review feedback, compacted summaries). The next round's dev prompt includes this context.

**Retry with fallback**: If a primary model times out or produces no output, the agent runner automatically retries with a configured fallback model (e.g., sonnet → opus).

**Token tracking**: Each agent runner estimates tokens from output size and appends to `tokens.log`. The orchestrator displays cumulative tokens after each phase and at finalization.
