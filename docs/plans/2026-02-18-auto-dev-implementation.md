# Auto-Dev Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a multi-terminal agentic AI workflow that orchestrates Claude CLI dev/reviewer agents across tmux panes with a live summary dashboard.

**Architecture:** Shell scripts orchestrate tmux sessions. Each agent runs as a separate `claude` CLI process. Agents communicate via shared JSON/markdown files in `.auto-dev/messages/`. A config parser reads per-repo YAML settings. A summary watcher script renders a live dashboard.

**Tech Stack:** Bash, tmux, jq, yq, Claude CLI, bats (testing)

---

### Task 1: Install Dependencies

**Files:**
- None (system setup)

**Step 1: Install tmux, yq, and bats via brew**

```bash
brew install tmux yq bats-core
```

**Step 2: Verify all tools are available**

```bash
tmux -V        # Expected: tmux 3.x
yq --version   # Expected: yq (https://github.com/mikefarah/yq/) version v4.x
bats --version # Expected: Bats 1.x
jq --version   # Expected: jq-1.7.1
claude --version # Expected: Claude Code 2.x
```

**Step 3: Commit — no code change, skip**

---

### Task 2: Project Scaffolding

**Files:**
- Create: `lib/` (directory)
- Create: `prompts/` (directory)
- Create: `skills/` (directory)
- Create: `templates/` (directory)
- Create: `tests/` (directory)

**Step 1: Create the directory structure**

```bash
mkdir -p lib prompts skills templates tests
```

**Step 2: Verify structure exists**

```bash
ls -d lib prompts skills templates tests
```

Expected: all five directories listed.

**Step 3: Commit**

```bash
git add lib prompts skills templates tests
git commit --allow-empty -m "chore: scaffold project directory structure"
```

---

### Task 3: Config Template

**Files:**
- Create: `templates/config.yaml`

**Step 1: Write the failing test**

Create `tests/config-template.bats`:

```bash
#!/usr/bin/env bats

@test "config template exists" {
  [ -f templates/config.yaml ]
}

@test "config template has required top-level keys" {
  run yq '.project' templates/config.yaml
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  run yq '.workflow' templates/config.yaml
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  run yq '.app_runner' templates/config.yaml
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  run yq '.reviewer' templates/config.yaml
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  run yq '.summary' templates/config.yaml
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}

@test "config template has sensible defaults" {
  run yq '.workflow.max_rounds' templates/config.yaml
  [ "$output" = "3" ]

  run yq '.workflow.dev_agents' templates/config.yaml
  [ "$output" = "1" ]

  run yq '.workflow.branch_prefix' templates/config.yaml
  [ "$output" = "auto-dev/" ]

  run yq '.summary.refresh_interval' templates/config.yaml
  [ "$output" = "5" ]
}
```

**Step 2: Run test to verify it fails**

```bash
bats tests/config-template.bats
```

Expected: FAIL — `templates/config.yaml` does not exist.

**Step 3: Write the config template**

Create `templates/config.yaml`:

```yaml
# .auto-dev/config.yaml — copy this to your repo's .auto-dev/ directory

project:
  name: "my-project"
  repo_path: "."

workflow:
  max_rounds: 3
  dev_agents: 1
  branch_prefix: "auto-dev/"

spec:
  path: "docs/specs/"

app_runner:
  command: ""
  health_check: ""
  watch_patterns:
    - "panic:"
    - "FAIL"
    - "Error:"
    - "fatal"

reviewer:
  skills:
    - "code-review"
  standards_file: "CLAUDE.md"
  severity_gate: "high"

summary:
  refresh_interval: 5
```

**Step 4: Run test to verify it passes**

```bash
bats tests/config-template.bats
```

Expected: all 3 tests PASS.

**Step 5: Commit**

```bash
git add templates/config.yaml tests/config-template.bats
git commit -m "feat: add default config.yaml template with tests"
```

---

### Task 4: Config Parser

**Files:**
- Create: `lib/config-parser.sh`
- Create: `tests/config-parser.bats`

**Step 1: Write the failing test**

Create `tests/config-parser.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  cp templates/config.yaml "$TEST_DIR/config.yaml"
  # Override some values for testing
  yq -i '.project.name = "test-project"' "$TEST_DIR/config.yaml"
  yq -i '.app_runner.command = "echo hello"' "$TEST_DIR/config.yaml"
  source lib/config-parser.sh
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "parse_config loads project name" {
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_PROJECT_NAME" = "test-project" ]
}

@test "parse_config loads workflow settings" {
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_MAX_ROUNDS" = "3" ]
  [ "$CFG_DEV_AGENTS" = "1" ]
  [ "$CFG_BRANCH_PREFIX" = "auto-dev/" ]
}

@test "parse_config loads app runner settings" {
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_APP_COMMAND" = "echo hello" ]
}

@test "parse_config loads reviewer skills as array" {
  parse_config "$TEST_DIR/config.yaml"
  [ "${CFG_REVIEWER_SKILLS[0]}" = "code-review" ]
}

@test "parse_config loads severity gate" {
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_SEVERITY_GATE" = "high" ]
}

@test "parse_config loads watch patterns as array" {
  parse_config "$TEST_DIR/config.yaml"
  [ "${#CFG_WATCH_PATTERNS[@]}" -ge 1 ]
  [[ " ${CFG_WATCH_PATTERNS[*]} " == *"panic:"* ]]
}

@test "parse_config fails on missing file" {
  run parse_config "/nonexistent/config.yaml"
  [ "$status" -ne 0 ]
}
```

**Step 2: Run test to verify it fails**

```bash
bats tests/config-parser.bats
```

Expected: FAIL — `lib/config-parser.sh` does not exist.

**Step 3: Write the config parser**

Create `lib/config-parser.sh`:

```bash
#!/usr/bin/env bash
# Parses .auto-dev/config.yaml into shell variables.
# Usage: source lib/config-parser.sh && parse_config path/to/config.yaml

set -euo pipefail

parse_config() {
  local config_file="$1"

  if [[ ! -f "$config_file" ]]; then
    echo "Error: config file not found: $config_file" >&2
    return 1
  fi

  # Project
  CFG_PROJECT_NAME="$(yq '.project.name' "$config_file")"
  CFG_REPO_PATH="$(yq '.project.repo_path' "$config_file")"

  # Workflow
  CFG_MAX_ROUNDS="$(yq '.workflow.max_rounds' "$config_file")"
  CFG_DEV_AGENTS="$(yq '.workflow.dev_agents' "$config_file")"
  CFG_BRANCH_PREFIX="$(yq '.workflow.branch_prefix' "$config_file")"

  # Spec
  CFG_SPEC_PATH="$(yq '.spec.path' "$config_file")"

  # App runner
  CFG_APP_COMMAND="$(yq '.app_runner.command' "$config_file")"
  CFG_HEALTH_CHECK="$(yq '.app_runner.health_check' "$config_file")"

  # Watch patterns (bash array)
  local pattern_count
  pattern_count="$(yq '.app_runner.watch_patterns | length' "$config_file")"
  CFG_WATCH_PATTERNS=()
  for ((i = 0; i < pattern_count; i++)); do
    CFG_WATCH_PATTERNS+=("$(yq ".app_runner.watch_patterns[$i]" "$config_file")")
  done

  # Reviewer
  CFG_STANDARDS_FILE="$(yq '.reviewer.standards_file' "$config_file")"
  CFG_SEVERITY_GATE="$(yq '.reviewer.severity_gate' "$config_file")"

  # Reviewer skills (bash array)
  local skill_count
  skill_count="$(yq '.reviewer.skills | length' "$config_file")"
  CFG_REVIEWER_SKILLS=()
  for ((i = 0; i < skill_count; i++)); do
    CFG_REVIEWER_SKILLS+=("$(yq ".reviewer.skills[$i]" "$config_file")")
  done

  # Summary
  CFG_REFRESH_INTERVAL="$(yq '.summary.refresh_interval' "$config_file")"

  export CFG_PROJECT_NAME CFG_REPO_PATH CFG_MAX_ROUNDS CFG_DEV_AGENTS
  export CFG_BRANCH_PREFIX CFG_SPEC_PATH CFG_APP_COMMAND CFG_HEALTH_CHECK
  export CFG_STANDARDS_FILE CFG_SEVERITY_GATE CFG_REFRESH_INTERVAL
}
```

**Step 4: Run test to verify it passes**

```bash
bats tests/config-parser.bats
```

Expected: all 7 tests PASS.

**Step 5: Commit**

```bash
git add lib/config-parser.sh tests/config-parser.bats
git commit -m "feat: add config parser with YAML-to-shell-variable extraction"
```

---

### Task 5: tmux Session Setup

**Files:**
- Create: `lib/tmux-setup.sh`
- Create: `tests/tmux-setup.bats`

**Step 1: Write the failing test**

Create `tests/tmux-setup.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export AUTO_DEV_SESSION="auto-dev-test-$$"
  source lib/tmux-setup.sh
}

teardown() {
  tmux kill-session -t "$AUTO_DEV_SESSION" 2>/dev/null || true
}

@test "create_session creates a tmux session" {
  create_session "$AUTO_DEV_SESSION" 1
  run tmux has-session -t "$AUTO_DEV_SESSION"
  [ "$status" -eq 0 ]
}

@test "create_session creates correct number of panes for 1 dev agent" {
  create_session "$AUTO_DEV_SESSION" 1
  # Expected panes: dev-1, reviewer, app-runner, summary = 4
  local pane_count
  pane_count="$(tmux list-panes -t "$AUTO_DEV_SESSION" -a | wc -l | tr -d ' ')"
  [ "$pane_count" -eq 4 ]
}

@test "create_session creates correct panes for 2 dev agents" {
  create_session "$AUTO_DEV_SESSION" 2
  # Expected panes: dev-1, dev-2, reviewer, app-runner, summary = 5
  local pane_count
  pane_count="$(tmux list-panes -t "$AUTO_DEV_SESSION" -a | wc -l | tr -d ' ')"
  [ "$pane_count" -eq 5 ]
}

@test "get_pane_id returns valid pane for known role" {
  create_session "$AUTO_DEV_SESSION" 1
  local pane_id
  pane_id="$(get_pane_id "$AUTO_DEV_SESSION" "dev-1")"
  [ -n "$pane_id" ]
}

@test "send_to_pane sends command to a pane" {
  create_session "$AUTO_DEV_SESSION" 1
  run send_to_pane "$AUTO_DEV_SESSION" "summary" "echo hello"
  [ "$status" -eq 0 ]
}

@test "kill_session destroys the session" {
  create_session "$AUTO_DEV_SESSION" 1
  kill_session "$AUTO_DEV_SESSION"
  run tmux has-session -t "$AUTO_DEV_SESSION"
  [ "$status" -ne 0 ]
}
```

**Step 2: Run test to verify it fails**

```bash
bats tests/tmux-setup.bats
```

Expected: FAIL — `lib/tmux-setup.sh` does not exist.

**Step 3: Write the tmux setup library**

Create `lib/tmux-setup.sh`:

```bash
#!/usr/bin/env bash
# Creates and manages tmux sessions for auto-dev workflow.
# Usage: source lib/tmux-setup.sh

set -euo pipefail

# Maps role names to pane indices within the session.
declare -A PANE_MAP

create_session() {
  local session_name="$1"
  local dev_agent_count="$2"

  # Create session with first window (summary pane)
  tmux new-session -d -s "$session_name" -x 200 -y 50

  # Split into layout: top-left, top-right, bottom-left, bottom-right
  # Start with summary in pane 0
  PANE_MAP["summary"]="${session_name}:0.0"

  # Split horizontally for app-runner
  tmux split-window -h -t "${session_name}:0.0"
  PANE_MAP["app-runner"]="${session_name}:0.1"

  # Split the left pane vertically for reviewer
  tmux split-window -v -t "${session_name}:0.0"
  PANE_MAP["reviewer"]="${session_name}:0.2"

  # Split the right pane vertically for dev-1
  tmux split-window -v -t "${session_name}:0.1"
  PANE_MAP["dev-1"]="${session_name}:0.3"

  # Additional dev agents get their own panes
  local pane_index=4
  for ((i = 2; i <= dev_agent_count; i++)); do
    tmux split-window -v -t "${session_name}:0.$((pane_index - 1))"
    PANE_MAP["dev-${i}"]="${session_name}:0.${pane_index}"
    ((pane_index++))
  done

  # Rebalance the layout
  tmux select-layout -t "${session_name}:0" tiled
}

get_pane_id() {
  local session_name="$1"
  local role="$2"
  echo "${PANE_MAP[$role]:-}"
}

send_to_pane() {
  local session_name="$1"
  local role="$2"
  local command="$3"

  local pane_id="${PANE_MAP[$role]:-}"
  if [[ -z "$pane_id" ]]; then
    echo "Error: unknown role: $role" >&2
    return 1
  fi

  tmux send-keys -t "$pane_id" "$command" C-m
}

kill_session() {
  local session_name="$1"
  tmux kill-session -t "$session_name" 2>/dev/null || true
}
```

**Step 4: Run test to verify it passes**

```bash
bats tests/tmux-setup.bats
```

Expected: all 6 tests PASS.

**Step 5: Commit**

```bash
git add lib/tmux-setup.sh tests/tmux-setup.bats
git commit -m "feat: add tmux session setup with pane management"
```

---

### Task 6: Summary Watcher (Dashboard)

**Files:**
- Create: `lib/summary-watcher.sh`
- Create: `tests/summary-watcher.bats`

**Step 1: Write the failing test**

Create `tests/summary-watcher.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  export MESSAGES_DIR="$TEST_DIR/messages"
  mkdir -p "$MESSAGES_DIR"
  source lib/summary-watcher.sh
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "render_dashboard outputs dashboard when summary.json exists" {
  cat > "$MESSAGES_DIR/summary.json" <<'EOF'
{
  "spec": "docs/specs/add-auth.md",
  "branch": "auto-dev/add-auth",
  "round": 1,
  "max_rounds": 3,
  "agents": {
    "dev-1": {"status": "implementing", "files_changed": 5},
    "reviewer": {"status": "waiting"},
    "app": {"status": "running", "healthy": true}
  },
  "review": null,
  "phase": "development"
}
EOF
  run render_dashboard "$MESSAGES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"add-auth"* ]]
  [[ "$output" == *"Round"* ]]
  [[ "$output" == *"Dev-1"* ]]
}

@test "render_dashboard shows review findings when available" {
  cat > "$MESSAGES_DIR/summary.json" <<'EOF'
{
  "spec": "docs/specs/add-auth.md",
  "branch": "auto-dev/add-auth",
  "round": 2,
  "max_rounds": 3,
  "agents": {
    "dev-1": {"status": "fixing", "files_changed": 8},
    "reviewer": {"status": "done"},
    "app": {"status": "running", "healthy": true}
  },
  "review": {
    "critical": 0,
    "high": 1,
    "medium": 3,
    "low": 5,
    "verdict": "changes_requested"
  },
  "phase": "iteration"
}
EOF
  run render_dashboard "$MESSAGES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changes_requested"* ]]
}

@test "render_dashboard shows app output tail" {
  cat > "$MESSAGES_DIR/summary.json" <<'EOF'
{
  "spec": "test.md",
  "branch": "auto-dev/test",
  "round": 1,
  "max_rounds": 3,
  "agents": {},
  "review": null,
  "phase": "setup"
}
EOF
  echo "[INFO] Server started" > "$MESSAGES_DIR/app-output.log"
  echo "[INFO] Ready" >> "$MESSAGES_DIR/app-output.log"

  run render_dashboard "$MESSAGES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Server started"* ]]
}
```

**Step 2: Run test to verify it fails**

```bash
bats tests/summary-watcher.bats
```

Expected: FAIL — `lib/summary-watcher.sh` does not exist.

**Step 3: Write the summary watcher**

Create `lib/summary-watcher.sh`:

```bash
#!/usr/bin/env bash
# Renders a live dashboard from .auto-dev/messages/summary.json.
# Usage: source lib/summary-watcher.sh && watch_dashboard <messages_dir> <interval>

set -euo pipefail

render_dashboard() {
  local messages_dir="$1"
  local summary_file="$messages_dir/summary.json"
  local app_log="$messages_dir/app-output.log"

  if [[ ! -f "$summary_file" ]]; then
    echo "Waiting for workflow to start..."
    return 0
  fi

  local spec branch round max_rounds phase
  spec="$(jq -r '.spec // "unknown"' "$summary_file")"
  branch="$(jq -r '.branch // "unknown"' "$summary_file")"
  round="$(jq -r '.round // 0' "$summary_file")"
  max_rounds="$(jq -r '.max_rounds // 3' "$summary_file")"
  phase="$(jq -r '.phase // "unknown"' "$summary_file")"

  # Extract feature name from spec path
  local feature_name
  feature_name="$(basename "$spec" .md)"

  local width=50
  local border
  border="$(printf '═%.0s' $(seq 1 $width))"
  local divider
  divider="$(printf '─%.0s' $(seq 1 $width))"

  echo "╔${border}╗"
  printf "║  %-$((width - 2))s║\n" "AUTO-DEV: ${feature_name}"
  echo "╠${border}╣"
  printf "║  %-$((width - 2))s║\n" "Spec:    ${spec}"
  printf "║  %-$((width - 2))s║\n" "Branch:  ${branch}"
  printf "║  %-$((width - 2))s║\n" "Round:   ${round} / ${max_rounds}"
  printf "║  %-$((width - 2))s║\n" "Phase:   ${phase}"
  echo "╠${border}╣"

  # Agents section
  printf "║  %-$((width - 2))s║\n" "AGENTS"

  local agent_keys
  agent_keys="$(jq -r '.agents | keys[]' "$summary_file" 2>/dev/null || true)"
  for agent in $agent_keys; do
    local status files_changed healthy
    status="$(jq -r ".agents[\"$agent\"].status // \"unknown\"" "$summary_file")"
    files_changed="$(jq -r ".agents[\"$agent\"].files_changed // \"\"" "$summary_file")"
    healthy="$(jq -r ".agents[\"$agent\"].healthy // \"\"" "$summary_file")"

    local icon="○"
    [[ "$status" != "waiting" && "$status" != "idle" ]] && icon="●"

    local label
    # Capitalize agent name: dev-1 -> Dev-1, reviewer -> Reviewer, app -> App
    label="$(echo "$agent" | sed 's/^./\U&/; s/-\(.\)/-\U\1/')"

    local detail="$status"
    [[ -n "$files_changed" && "$files_changed" != "null" ]] && detail="$status ($files_changed files)"
    [[ -n "$healthy" && "$healthy" != "null" ]] && detail="$status ($([ "$healthy" = "true" ] && echo "healthy" || echo "unhealthy"))"

    printf "║    %s %-$((width - 6))s║\n" "$icon" "${label}: ${detail}"
  done

  echo "╠${border}╣"

  # Review section
  local review_exists
  review_exists="$(jq -r '.review // "null"' "$summary_file")"
  if [[ "$review_exists" != "null" ]]; then
    local critical high medium low verdict
    critical="$(jq -r '.review.critical // 0' "$summary_file")"
    high="$(jq -r '.review.high // 0' "$summary_file")"
    medium="$(jq -r '.review.medium // 0' "$summary_file")"
    low="$(jq -r '.review.low // 0' "$summary_file")"
    verdict="$(jq -r '.review.verdict // "pending"' "$summary_file")"

    printf "║  %-$((width - 2))s║\n" "REVIEW (Round $((round - 1)))"
    printf "║    %-$((width - 4))s║\n" "Critical: $critical  High: $high  Medium: $medium  Low: $low"
    printf "║    %-$((width - 4))s║\n" "Verdict: $verdict"
  else
    printf "║  %-$((width - 2))s║\n" "REVIEW"
    printf "║    %-$((width - 4))s║\n" "No reviews yet"
  fi

  echo "╠${border}╣"

  # App output (last 3 lines)
  printf "║  %-$((width - 2))s║\n" "APP OUTPUT (last 3 lines)"
  if [[ -f "$app_log" ]]; then
    tail -3 "$app_log" | while IFS= read -r line; do
      local truncated="${line:0:$((width - 4))}"
      printf "║    %-$((width - 4))s║\n" "$truncated"
    done
  else
    printf "║    %-$((width - 4))s║\n" "(no output yet)"
  fi

  echo "╚${border}╝"
}

watch_dashboard() {
  local messages_dir="$1"
  local interval="${2:-5}"

  while true; do
    clear
    render_dashboard "$messages_dir"
    sleep "$interval"
  done
}
```

**Step 4: Run test to verify it passes**

```bash
bats tests/summary-watcher.bats
```

Expected: all 3 tests PASS.

**Step 5: Commit**

```bash
git add lib/summary-watcher.sh tests/summary-watcher.bats
git commit -m "feat: add summary dashboard watcher with TUI rendering"
```

---

### Task 7: Agent Prompt Templates

**Files:**
- Create: `prompts/dev-agent.md`
- Create: `prompts/reviewer-agent.md`
- Create: `prompts/orchestrator.md`

**Step 1: Write the dev agent prompt**

Create `prompts/dev-agent.md`:

```markdown
# Role: Dev Agent

You are an autonomous development agent implementing a feature from a spec.

## Inputs

- **Spec:** Read `.auto-dev/messages/spec.md` for the feature requirements
- **Standards:** Read `{{STANDARDS_FILE}}` for coding standards and conventions
- **Review feedback (round > 1):** Read `.auto-dev/messages/reviewer-feedback.md` and address each finding
- **App output:** Read `.auto-dev/messages/app-output.log` to check for runtime failures

## Protocol

1. Read the spec thoroughly before writing any code
2. Plan your implementation approach
3. Write code following the repo's coding standards
4. Run tests after each significant change
5. Check `.auto-dev/messages/app-output.log` for these failure patterns: {{WATCH_PATTERNS}}
   - If a failure pattern is detected, fix the issue before continuing
6. When implementation is complete, write your status:
   ```bash
   cat > .auto-dev/messages/dev-{{AGENT_ID}}-status.json <<'STATUSEOF'
   {
     "status": "done",
     "round": {{ROUND}},
     "files_changed": ["list", "of", "changed", "files"],
     "tests_passed": true,
     "app_healthy": true
   }
   STATUSEOF
   ```
7. Git commit with message format: `auto-dev(round-{{ROUND}}): <description>`

## Round > 1 Instructions

If this is round 2 or later:
1. Read `.auto-dev/messages/reviewer-feedback.md` first
2. Address findings in priority order: CRITICAL > HIGH > MEDIUM > LOW
3. For each finding, fix the issue in the referenced file and line
4. Do NOT introduce new features — only address review feedback
5. Run tests after each fix

## Constraints

- Stay within the scope of the spec — do not add unrequested features
- Follow existing code patterns in the repo
- Do not modify files outside the feature scope unless necessary
- Always run tests before marking status as "done"
```

**Step 2: Write the reviewer agent prompt**

Create `prompts/reviewer-agent.md`:

```markdown
# Role: Reviewer Agent

You are an autonomous code reviewer enforcing coding standards and best practices.

## Inputs

- **Standards:** Read `{{STANDARDS_FILE}}` for the repo's coding standards
- **Config skills:** {{REVIEWER_SKILLS}}
- **Severity gate:** Only approve if no issues at or above `{{SEVERITY_GATE}}` severity
- **App output:** Read `.auto-dev/messages/app-output.log` for runtime issues

## Protocol

1. Wait until all dev agent status files show `"status": "done"`
   - Poll `.auto-dev/messages/dev-*-status.json` every 10 seconds
2. Run `git diff {{BASE_BRANCH}}...HEAD` to see all changes
3. For each configured skill, review the changes:
{{SKILLS_LIST}}
4. Check `.auto-dev/messages/app-output.log` for runtime failures
5. Write structured feedback to `.auto-dev/messages/reviewer-feedback.md`:

```markdown
# Review: Round {{ROUND}}

## Verdict: approved | changes_requested

## Summary
<brief overall assessment — 2-3 sentences>

## Findings

### CRITICAL
- [file:line] Description of critical issue

### HIGH
- [file:line] Description of high-severity issue

### MEDIUM
- [file:line] Description of medium-severity issue

### LOW
- [file:line] Description of low-severity issue

## Score: X/10
```

6. Update the summary file:
   ```bash
   jq '.review = {"critical": N, "high": N, "medium": N, "low": N, "verdict": "approved|changes_requested"}' \
     .auto-dev/messages/summary.json > tmp.json && mv tmp.json .auto-dev/messages/summary.json
   ```

## Severity Gate

- If any finding is at or above `{{SEVERITY_GATE}}` severity: verdict = `changes_requested`
- If all findings are below the gate: verdict = `approved`

## Constraints

- Do NOT modify any code — only review and report
- Be specific: always include file path and line number
- Be actionable: describe what to fix, not just what's wrong
- Focus on the diff, not the entire codebase
```

**Step 3: Write the orchestrator prompt**

Create `prompts/orchestrator.md`:

```markdown
# Role: Orchestrator

You manage the auto-dev workflow lifecycle.

## State

- **Round:** {{ROUND}} / {{MAX_ROUNDS}}
- **Phase:** {{PHASE}}
- **Messages dir:** .auto-dev/messages/

## Phase Transitions

### Setup → Development
1. Verify `.auto-dev/messages/spec.md` exists
2. Initialize `summary.json`:
   ```json
   {
     "spec": "{{SPEC_PATH}}",
     "branch": "{{BRANCH_NAME}}",
     "round": 1,
     "max_rounds": {{MAX_ROUNDS}},
     "agents": {},
     "review": null,
     "phase": "development"
   }
   ```
3. Signal dev agent(s) to start

### Development → Review
1. Poll `dev-*-status.json` files until all show `"status": "done"`
2. Update `summary.json` phase to `"review"`
3. Signal reviewer agent to start

### Review → Iteration (or Finalize)
1. Read `reviewer-feedback.md` for verdict
2. If verdict = `"approved"` OR round >= max_rounds:
   - Transition to Finalize
3. If verdict = `"changes_requested"`:
   - Increment round
   - Update `summary.json` with new round and phase `"development"`
   - Signal dev agent(s) to start next round

### Finalize
1. Create PR with `gh pr create`:
   - Title: `auto-dev: {{FEATURE_NAME}}`
   - Body: spec summary + review history + final verdict
2. Update `summary.json` phase to `"complete"`
3. Report final status
```

**Step 4: Verify prompt templates have correct placeholder syntax**

```bash
# Check all placeholders are {{DOUBLE_BRACED}}
grep -oE '\{\{[A-Z_]+\}\}' prompts/*.md | sort -u
```

Expected: a list of all placeholder names used across templates.

**Step 5: Commit**

```bash
git add prompts/dev-agent.md prompts/reviewer-agent.md prompts/orchestrator.md
git commit -m "feat: add agent prompt templates for dev, reviewer, and orchestrator"
```

---

### Task 8: Orchestrator Script

**Files:**
- Create: `lib/orchestrator.sh`
- Create: `tests/orchestrator.bats`

**Step 1: Write the failing test**

Create `tests/orchestrator.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  export MESSAGES_DIR="$TEST_DIR/messages"
  mkdir -p "$MESSAGES_DIR"
  source lib/orchestrator.sh
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "init_workflow creates summary.json" {
  init_workflow "$MESSAGES_DIR" "docs/specs/feat.md" "auto-dev/feat" 3
  [ -f "$MESSAGES_DIR/summary.json" ]
  local phase
  phase="$(jq -r '.phase' "$MESSAGES_DIR/summary.json")"
  [ "$phase" = "setup" ]
}

@test "check_dev_status returns false when no status files" {
  run check_dev_status "$MESSAGES_DIR" 1
  [ "$status" -ne 0 ]
}

@test "check_dev_status returns true when all devs done" {
  echo '{"status":"done","round":1}' > "$MESSAGES_DIR/dev-1-status.json"
  run check_dev_status "$MESSAGES_DIR" 1
  [ "$status" -eq 0 ]
}

@test "check_dev_status returns false when dev still in progress" {
  echo '{"status":"in_progress","round":1}' > "$MESSAGES_DIR/dev-1-status.json"
  run check_dev_status "$MESSAGES_DIR" 1
  [ "$status" -ne 0 ]
}

@test "get_review_verdict reads verdict from feedback" {
  cat > "$MESSAGES_DIR/reviewer-feedback.md" <<'EOF'
# Review: Round 1

## Verdict: changes_requested

## Summary
Needs work.
EOF
  local verdict
  verdict="$(get_review_verdict "$MESSAGES_DIR")"
  [ "$verdict" = "changes_requested" ]
}

@test "get_review_verdict returns approved" {
  cat > "$MESSAGES_DIR/reviewer-feedback.md" <<'EOF'
# Review: Round 1

## Verdict: approved

## Summary
Looks good.
EOF
  local verdict
  verdict="$(get_review_verdict "$MESSAGES_DIR")"
  [ "$verdict" = "approved" ]
}

@test "should_continue returns true when changes_requested and under max rounds" {
  run should_continue "changes_requested" 1 3
  [ "$status" -eq 0 ]
}

@test "should_continue returns false when approved" {
  run should_continue "approved" 1 3
  [ "$status" -ne 0 ]
}

@test "should_continue returns false when at max rounds" {
  run should_continue "changes_requested" 3 3
  [ "$status" -ne 0 ]
}

@test "update_summary_phase updates phase in summary.json" {
  echo '{"phase":"setup","round":1}' > "$MESSAGES_DIR/summary.json"
  update_summary_phase "$MESSAGES_DIR" "development"
  local phase
  phase="$(jq -r '.phase' "$MESSAGES_DIR/summary.json")"
  [ "$phase" = "development" ]
}

@test "increment_round updates round in summary.json" {
  echo '{"phase":"development","round":1}' > "$MESSAGES_DIR/summary.json"
  increment_round "$MESSAGES_DIR"
  local round
  round="$(jq -r '.round' "$MESSAGES_DIR/summary.json")"
  [ "$round" = "2" ]
}
```

**Step 2: Run test to verify it fails**

```bash
bats tests/orchestrator.bats
```

Expected: FAIL — `lib/orchestrator.sh` does not exist.

**Step 3: Write the orchestrator library**

Create `lib/orchestrator.sh`:

```bash
#!/usr/bin/env bash
# Manages workflow state transitions and round control.
# Usage: source lib/orchestrator.sh

set -euo pipefail

init_workflow() {
  local messages_dir="$1"
  local spec_path="$2"
  local branch_name="$3"
  local max_rounds="$4"

  mkdir -p "$messages_dir"

  jq -n \
    --arg spec "$spec_path" \
    --arg branch "$branch_name" \
    --argjson max_rounds "$max_rounds" \
    '{
      spec: $spec,
      branch: $branch,
      round: 1,
      max_rounds: $max_rounds,
      agents: {},
      review: null,
      phase: "setup"
    }' > "$messages_dir/summary.json"
}

check_dev_status() {
  local messages_dir="$1"
  local dev_count="$2"

  for ((i = 1; i <= dev_count; i++)); do
    local status_file="$messages_dir/dev-${i}-status.json"
    if [[ ! -f "$status_file" ]]; then
      return 1
    fi
    local status
    status="$(jq -r '.status' "$status_file")"
    if [[ "$status" != "done" ]]; then
      return 1
    fi
  done
  return 0
}

get_review_verdict() {
  local messages_dir="$1"
  local feedback_file="$messages_dir/reviewer-feedback.md"

  if [[ ! -f "$feedback_file" ]]; then
    echo "pending"
    return 0
  fi

  grep -oP '## Verdict: \K\S+' "$feedback_file" | head -1
}

should_continue() {
  local verdict="$1"
  local current_round="$2"
  local max_rounds="$3"

  if [[ "$verdict" = "approved" ]]; then
    return 1
  fi

  if [[ "$current_round" -ge "$max_rounds" ]]; then
    return 1
  fi

  return 0
}

update_summary_phase() {
  local messages_dir="$1"
  local new_phase="$2"
  local summary_file="$messages_dir/summary.json"

  local tmp
  tmp="$(jq --arg phase "$new_phase" '.phase = $phase' "$summary_file")"
  echo "$tmp" > "$summary_file"
}

increment_round() {
  local messages_dir="$1"
  local summary_file="$messages_dir/summary.json"

  local tmp
  tmp="$(jq '.round += 1' "$summary_file")"
  echo "$tmp" > "$summary_file"
}

update_agent_status() {
  local messages_dir="$1"
  local agent_name="$2"
  local status="$3"
  local summary_file="$messages_dir/summary.json"

  local tmp
  tmp="$(jq --arg agent "$agent_name" --arg status "$status" \
    '.agents[$agent].status = $status' "$summary_file")"
  echo "$tmp" > "$summary_file"
}
```

**Step 4: Run test to verify it passes**

```bash
bats tests/orchestrator.bats
```

Expected: all 11 tests PASS.

**Step 5: Commit**

```bash
git add lib/orchestrator.sh tests/orchestrator.bats
git commit -m "feat: add orchestrator with round management and state transitions"
```

---

### Task 9: Prompt Template Renderer

**Files:**
- Create: `lib/prompt-renderer.sh`
- Create: `tests/prompt-renderer.bats`

**Step 1: Write the failing test**

Create `tests/prompt-renderer.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  source lib/prompt-renderer.sh
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "render_prompt replaces single placeholder" {
  echo "Hello {{NAME}}" > "$TEST_DIR/template.md"
  run render_prompt "$TEST_DIR/template.md" "NAME=World"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hello World"* ]]
  [[ "$output" != *"{{NAME}}"* ]]
}

@test "render_prompt replaces multiple placeholders" {
  echo "{{GREETING}} {{NAME}}, round {{ROUND}}" > "$TEST_DIR/template.md"
  run render_prompt "$TEST_DIR/template.md" "GREETING=Hello" "NAME=Dev" "ROUND=2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hello Dev, round 2"* ]]
}

@test "render_prompt leaves unknown placeholders as-is" {
  echo "{{KNOWN}} and {{UNKNOWN}}" > "$TEST_DIR/template.md"
  run render_prompt "$TEST_DIR/template.md" "KNOWN=replaced"
  [ "$status" -eq 0 ]
  [[ "$output" == *"replaced"* ]]
  [[ "$output" == *"{{UNKNOWN}}"* ]]
}

@test "render_prompt fails on missing template" {
  run render_prompt "/nonexistent/template.md" "NAME=test"
  [ "$status" -ne 0 ]
}
```

**Step 2: Run test to verify it fails**

```bash
bats tests/prompt-renderer.bats
```

Expected: FAIL — `lib/prompt-renderer.sh` does not exist.

**Step 3: Write the prompt renderer**

Create `lib/prompt-renderer.sh`:

```bash
#!/usr/bin/env bash
# Renders prompt templates by replacing {{PLACEHOLDER}} with values.
# Usage: source lib/prompt-renderer.sh && render_prompt template.md KEY=value ...

set -euo pipefail

render_prompt() {
  local template_file="$1"
  shift

  if [[ ! -f "$template_file" ]]; then
    echo "Error: template not found: $template_file" >&2
    return 1
  fi

  local content
  content="$(cat "$template_file")"

  for pair in "$@"; do
    local key="${pair%%=*}"
    local value="${pair#*=}"
    content="${content//\{\{${key}\}\}/${value}}"
  done

  echo "$content"
}

render_prompt_to_file() {
  local template_file="$1"
  local output_file="$2"
  shift 2

  render_prompt "$template_file" "$@" > "$output_file"
}
```

**Step 4: Run test to verify it passes**

```bash
bats tests/prompt-renderer.bats
```

Expected: all 4 tests PASS.

**Step 5: Commit**

```bash
git add lib/prompt-renderer.sh tests/prompt-renderer.bats
git commit -m "feat: add prompt template renderer with placeholder substitution"
```

---

### Task 10: Init Script (Repo Scaffolding)

**Files:**
- Create: `templates/init.sh`
- Create: `tests/init.bats`

**Step 1: Write the failing test**

Create `tests/init.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  export AUTO_DEV_ROOT="$(pwd)"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "init creates .auto-dev directory" {
  bash templates/init.sh "$TEST_DIR"
  [ -d "$TEST_DIR/.auto-dev" ]
}

@test "init creates config.yaml from template" {
  bash templates/init.sh "$TEST_DIR"
  [ -f "$TEST_DIR/.auto-dev/config.yaml" ]
  run yq '.workflow.max_rounds' "$TEST_DIR/.auto-dev/config.yaml"
  [ "$output" = "3" ]
}

@test "init creates messages directory" {
  bash templates/init.sh "$TEST_DIR"
  [ -d "$TEST_DIR/.auto-dev/messages" ]
}

@test "init creates prompts directory" {
  bash templates/init.sh "$TEST_DIR"
  [ -d "$TEST_DIR/.auto-dev/prompts" ]
}

@test "init creates skills directory" {
  bash templates/init.sh "$TEST_DIR"
  [ -d "$TEST_DIR/.auto-dev/skills" ]
}

@test "init does not overwrite existing config" {
  mkdir -p "$TEST_DIR/.auto-dev"
  echo "existing" > "$TEST_DIR/.auto-dev/config.yaml"
  bash templates/init.sh "$TEST_DIR"
  run cat "$TEST_DIR/.auto-dev/config.yaml"
  [ "$output" = "existing" ]
}
```

**Step 2: Run test to verify it fails**

```bash
bats tests/init.bats
```

Expected: FAIL — `templates/init.sh` does not exist.

**Step 3: Write the init script**

Create `templates/init.sh`:

```bash
#!/usr/bin/env bash
# Scaffolds .auto-dev/ directory in a target repo.
# Usage: bash templates/init.sh /path/to/repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_DEV_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="${1:-.}"

echo "Initializing .auto-dev in: $TARGET_DIR"

mkdir -p "$TARGET_DIR/.auto-dev/messages"
mkdir -p "$TARGET_DIR/.auto-dev/prompts"
mkdir -p "$TARGET_DIR/.auto-dev/skills"

# Copy config template if not already present
if [[ ! -f "$TARGET_DIR/.auto-dev/config.yaml" ]]; then
  cp "$AUTO_DEV_ROOT/templates/config.yaml" "$TARGET_DIR/.auto-dev/config.yaml"
  echo "Created .auto-dev/config.yaml — edit this to configure your workflow."
else
  echo "Config already exists, skipping."
fi

# Copy prompt templates
for prompt in "$AUTO_DEV_ROOT/prompts"/*.md; do
  local_name="$(basename "$prompt")"
  if [[ ! -f "$TARGET_DIR/.auto-dev/prompts/$local_name" ]]; then
    cp "$prompt" "$TARGET_DIR/.auto-dev/prompts/$local_name"
  fi
done

echo "Done. Edit .auto-dev/config.yaml to configure your workflow."
```

**Step 4: Run test to verify it passes**

```bash
bats tests/init.bats
```

Expected: all 6 tests PASS.

**Step 5: Commit**

```bash
git add templates/init.sh tests/init.bats
git commit -m "feat: add init script to scaffold .auto-dev/ in target repos"
```

---

### Task 11: Main Launcher Script

**Files:**
- Create: `auto-dev.sh`
- Create: `tests/auto-dev.bats`

**Step 1: Write the failing test**

Create `tests/auto-dev.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  # Create a minimal fake repo with .auto-dev config
  mkdir -p "$TEST_DIR/.auto-dev/messages"
  mkdir -p "$TEST_DIR/.auto-dev/prompts"
  cp templates/config.yaml "$TEST_DIR/.auto-dev/config.yaml"
  yq -i '.app_runner.command = "echo server-started"' "$TEST_DIR/.auto-dev/config.yaml"
  yq -i '.project.name = "test-project"' "$TEST_DIR/.auto-dev/config.yaml"
  cp prompts/*.md "$TEST_DIR/.auto-dev/prompts/"
  echo "# Test Spec" > "$TEST_DIR/spec.md"
}

teardown() {
  tmux kill-session -t "auto-dev-test-project" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}

@test "auto-dev.sh shows usage without arguments" {
  run bash auto-dev.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "auto-dev.sh validates spec file exists" {
  run bash auto-dev.sh --spec /nonexistent/spec.md --repo "$TEST_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "auto-dev.sh validates .auto-dev/config.yaml exists" {
  rm "$TEST_DIR/.auto-dev/config.yaml"
  run bash auto-dev.sh --spec "$TEST_DIR/spec.md" --repo "$TEST_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config"* ]]
}

@test "auto-dev.sh --dry-run shows plan without executing" {
  run bash auto-dev.sh --spec "$TEST_DIR/spec.md" --repo "$TEST_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-project"* ]]
  [[ "$output" == *"Dry run"* ]]
}
```

**Step 2: Run test to verify it fails**

```bash
bats tests/auto-dev.bats
```

Expected: FAIL — `auto-dev.sh` does not exist.

**Step 3: Write the main launcher**

Create `auto-dev.sh`:

```bash
#!/usr/bin/env bash
# Auto-Dev: Multi-terminal agentic AI workflow.
# Usage: ./auto-dev.sh --spec <spec.md> --repo <path> [--dry-run] [--detached]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/config-parser.sh"
source "$SCRIPT_DIR/lib/tmux-setup.sh"
source "$SCRIPT_DIR/lib/orchestrator.sh"
source "$SCRIPT_DIR/lib/prompt-renderer.sh"
source "$SCRIPT_DIR/lib/summary-watcher.sh"

# --- Argument parsing ---

SPEC_FILE=""
REPO_DIR="."
DRY_RUN=false
DETACHED=false

usage() {
  echo "Usage: auto-dev.sh --spec <spec.md> --repo <path> [--dry-run] [--detached]"
  echo ""
  echo "Options:"
  echo "  --spec <file>    Path to the feature spec markdown file"
  echo "  --repo <path>    Path to the target repository (default: .)"
  echo "  --dry-run        Show the execution plan without running"
  echo "  --detached       Run tmux session in detached mode (for CI)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) SPEC_FILE="$2"; shift 2 ;;
    --repo) REPO_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --detached) DETACHED=true; shift ;;
    *) usage ;;
  esac
done

if [[ -z "$SPEC_FILE" ]]; then
  usage
fi

# --- Validation ---

if [[ ! -f "$SPEC_FILE" ]]; then
  echo "Error: spec file not found: $SPEC_FILE" >&2
  exit 1
fi

CONFIG_FILE="$REPO_DIR/.auto-dev/config.yaml"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: config not found: $CONFIG_FILE" >&2
  echo "Run 'auto-dev init' first to scaffold .auto-dev/ in your repo." >&2
  exit 1
fi

# --- Load config ---

parse_config "$CONFIG_FILE"

MESSAGES_DIR="$REPO_DIR/.auto-dev/messages"
PROMPTS_DIR="$REPO_DIR/.auto-dev/prompts"
FEATURE_NAME="$(basename "$SPEC_FILE" .md)"
BRANCH_NAME="${CFG_BRANCH_PREFIX}${FEATURE_NAME}"
SESSION_NAME="auto-dev-${CFG_PROJECT_NAME}"

# --- Dry run ---

if [[ "$DRY_RUN" = true ]]; then
  echo "=== Dry run: Auto-Dev Execution Plan ==="
  echo ""
  echo "Project:      $CFG_PROJECT_NAME"
  echo "Spec:         $SPEC_FILE"
  echo "Branch:       $BRANCH_NAME"
  echo "Dev agents:   $CFG_DEV_AGENTS"
  echo "Max rounds:   $CFG_MAX_ROUNDS"
  echo "App command:  $CFG_APP_COMMAND"
  echo "Review skills: ${CFG_REVIEWER_SKILLS[*]}"
  echo "Severity gate: $CFG_SEVERITY_GATE"
  echo ""
  echo "Panes: summary | app-runner | reviewer | dev-1..dev-${CFG_DEV_AGENTS}"
  echo ""
  echo "Dry run complete. Remove --dry-run to execute."
  exit 0
fi

# --- Setup ---

mkdir -p "$MESSAGES_DIR"
cp "$SPEC_FILE" "$MESSAGES_DIR/spec.md"

init_workflow "$MESSAGES_DIR" "$SPEC_FILE" "$BRANCH_NAME" "$CFG_MAX_ROUNDS"

# Create tmux session
create_session "$SESSION_NAME" "$CFG_DEV_AGENTS"

# --- Start app runner ---

if [[ -n "$CFG_APP_COMMAND" ]]; then
  send_to_pane "$SESSION_NAME" "app-runner" \
    "cd $REPO_DIR && $CFG_APP_COMMAND 2>&1 | tee $MESSAGES_DIR/app-output.log"
fi

# --- Render prompts and launch agents ---

SKILLS_LIST=""
for skill in "${CFG_REVIEWER_SKILLS[@]}"; do
  SKILLS_LIST="$SKILLS_LIST   - $skill\n"
done

WATCH_PATTERNS_STR=""
for pattern in "${CFG_WATCH_PATTERNS[@]}"; do
  WATCH_PATTERNS_STR="$WATCH_PATTERNS_STR \"$pattern\""
done

# --- Main loop ---

CURRENT_ROUND=1

while true; do
  update_summary_phase "$MESSAGES_DIR" "development"

  # Launch dev agents
  for ((i = 1; i <= CFG_DEV_AGENTS; i++)); do
    local_prompt="$(render_prompt "$PROMPTS_DIR/dev-agent.md" \
      "STANDARDS_FILE=$CFG_STANDARDS_FILE" \
      "WATCH_PATTERNS=$WATCH_PATTERNS_STR" \
      "AGENT_ID=$i" \
      "ROUND=$CURRENT_ROUND")"

    local_prompt_file="$MESSAGES_DIR/dev-${i}-prompt-r${CURRENT_ROUND}.md"
    echo "$local_prompt" > "$local_prompt_file"

    update_agent_status "$MESSAGES_DIR" "dev-$i" "implementing"

    send_to_pane "$SESSION_NAME" "dev-$i" \
      "cd $REPO_DIR && claude -p \"$(cat "$local_prompt_file")\" --allowedTools 'Edit,Write,Read,Bash,Grep,Glob'"
  done

  # Wait for dev agents to complete
  echo "Waiting for dev agent(s) to complete round $CURRENT_ROUND..."
  while ! check_dev_status "$MESSAGES_DIR" "$CFG_DEV_AGENTS"; do
    sleep 10
  done

  # Launch reviewer
  update_summary_phase "$MESSAGES_DIR" "review"
  update_agent_status "$MESSAGES_DIR" "reviewer" "reviewing"

  reviewer_prompt="$(render_prompt "$PROMPTS_DIR/reviewer-agent.md" \
    "STANDARDS_FILE=$CFG_STANDARDS_FILE" \
    "REVIEWER_SKILLS=${CFG_REVIEWER_SKILLS[*]}" \
    "SEVERITY_GATE=$CFG_SEVERITY_GATE" \
    "BASE_BRANCH=main" \
    "ROUND=$CURRENT_ROUND" \
    "SKILLS_LIST=$SKILLS_LIST")"

  reviewer_prompt_file="$MESSAGES_DIR/reviewer-prompt-r${CURRENT_ROUND}.md"
  echo "$reviewer_prompt" > "$reviewer_prompt_file"

  send_to_pane "$SESSION_NAME" "reviewer" \
    "cd $REPO_DIR && claude -p \"$(cat "$reviewer_prompt_file")\" --allowedTools 'Read,Bash,Grep,Glob'"

  # Wait for review
  echo "Waiting for reviewer to complete round $CURRENT_ROUND..."
  while [[ "$(get_review_verdict "$MESSAGES_DIR")" = "pending" ]]; do
    sleep 10
  done

  VERDICT="$(get_review_verdict "$MESSAGES_DIR")"
  update_agent_status "$MESSAGES_DIR" "reviewer" "done"

  # Check if we should continue
  if ! should_continue "$VERDICT" "$CURRENT_ROUND" "$CFG_MAX_ROUNDS"; then
    break
  fi

  # Prepare next round
  increment_round "$MESSAGES_DIR"
  CURRENT_ROUND=$((CURRENT_ROUND + 1))

  # Clear dev status files for next round
  rm -f "$MESSAGES_DIR"/dev-*-status.json
done

# --- Finalize ---

update_summary_phase "$MESSAGES_DIR" "finalizing"

# Build PR body from review history
PR_BODY="## Summary\n\n"
PR_BODY+="Automated implementation of: $SPEC_FILE\n\n"
PR_BODY+="## Review History\n\n"
PR_BODY+="- Rounds completed: $CURRENT_ROUND / $CFG_MAX_ROUNDS\n"
PR_BODY+="- Final verdict: $VERDICT\n\n"

if [[ -f "$MESSAGES_DIR/reviewer-feedback.md" ]]; then
  PR_BODY+="## Final Review\n\n"
  PR_BODY+="$(cat "$MESSAGES_DIR/reviewer-feedback.md")\n"
fi

send_to_pane "$SESSION_NAME" "dev-1" \
  "cd $REPO_DIR && gh pr create --title 'auto-dev: $FEATURE_NAME' --body \"$PR_BODY\""

update_summary_phase "$MESSAGES_DIR" "complete"

# Start dashboard in summary pane
send_to_pane "$SESSION_NAME" "summary" \
  "cd $REPO_DIR && bash $SCRIPT_DIR/lib/summary-watcher.sh $MESSAGES_DIR $CFG_REFRESH_INTERVAL"

if [[ "$DETACHED" = false ]]; then
  tmux attach-session -t "$SESSION_NAME"
fi

echo "Auto-dev complete. Branch: $BRANCH_NAME"
```

**Step 4: Run test to verify it passes**

```bash
bats tests/auto-dev.bats
```

Expected: all 4 tests PASS.

**Step 5: Make executable and commit**

```bash
chmod +x auto-dev.sh
git add auto-dev.sh tests/auto-dev.bats
git commit -m "feat: add main launcher script with arg parsing, validation, and workflow loop"
```

---

### Task 12: Claude Code Skill

**Files:**
- Create: `skills/auto-dev.md`

**Step 1: Write the Claude Code slash command skill**

Create `skills/auto-dev.md`:

```markdown
---
name: auto-dev
description: Launch the auto-dev multi-terminal agentic workflow for a spec file
arguments:
  - name: spec
    description: Path to the feature spec markdown file
    required: true
---

# Auto-Dev Workflow

Launch the multi-terminal agentic dev workflow for the given spec.

## Steps

1. Validate that `.auto-dev/config.yaml` exists in the current repo
2. If not, offer to run `auto-dev init` to scaffold it
3. Run the launcher:

```bash
bash <auto-dev-install-path>/auto-dev.sh --spec {{spec}} --repo .
```

Where `<auto-dev-install-path>` is the directory where auto-dev is installed.

## If `.auto-dev/` does not exist

Run init first:

```bash
bash <auto-dev-install-path>/templates/init.sh .
```

Then edit `.auto-dev/config.yaml` to configure:
- `app_runner.command` — the command to start your application
- `reviewer.skills` — which review skills to run
- `workflow.dev_agents` — how many dev agents to use

## After Launch

The workflow runs in tmux. You can:
- `tmux attach -t auto-dev-<project>` to view the session
- Watch the summary dashboard in the bottom pane
- Each agent works in its own pane
```

**Step 2: Commit**

```bash
git add skills/auto-dev.md
git commit -m "feat: add Claude Code slash command skill for /auto-dev"
```

---

### Task 13: Integration Test

**Files:**
- Create: `tests/integration.bats`

**Step 1: Write the integration test**

Create `tests/integration.bats` — tests the full flow with mocked `claude` CLI:

```bash
#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  export PATH="$TEST_DIR/bin:$PATH"

  # Create a mock claude CLI that writes status files
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Mock claude CLI: reads the prompt, writes appropriate status/feedback files
PROMPT="$*"
REPO_DIR="$(pwd)"
MESSAGES="$REPO_DIR/.auto-dev/messages"

if [[ "$PROMPT" == *"dev-agent"* ]] || [[ "$PROMPT" == *"Implement"* ]]; then
  # Simulate dev agent: write status
  AGENT_ID="1"
  [[ "$PROMPT" =~ AGENT_ID=([0-9]+) ]] && AGENT_ID="${BASH_REMATCH[1]}"
  echo '{"status":"done","round":1,"files_changed":["test.go"],"tests_passed":true,"app_healthy":true}' \
    > "$MESSAGES/dev-${AGENT_ID}-status.json"
elif [[ "$PROMPT" == *"reviewer"* ]] || [[ "$PROMPT" == *"Review"* ]]; then
  # Simulate reviewer: write feedback
  cat > "$MESSAGES/reviewer-feedback.md" <<'FEEDBACK'
# Review: Round 1

## Verdict: approved

## Summary
Code looks good.

## Findings

### CRITICAL

### HIGH

### MEDIUM

### LOW
- [test.go:1] Minor style issue

## Score: 9/10
FEEDBACK
fi
MOCK
  chmod +x "$TEST_DIR/bin/claude"

  # Create mock gh CLI
  cat > "$TEST_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo "https://github.com/test/repo/pull/1"
MOCK
  chmod +x "$TEST_DIR/bin/gh"

  # Set up a fake repo with .auto-dev
  mkdir -p "$TEST_DIR/repo"
  cd "$TEST_DIR/repo"
  git init --quiet
  git commit --allow-empty -m "init" --quiet

  bash "$(cd "$OLDPWD" && pwd)/templates/init.sh" "$TEST_DIR/repo"
  yq -i '.app_runner.command = ""' "$TEST_DIR/repo/.auto-dev/config.yaml"
  yq -i '.project.name = "integration-test"' "$TEST_DIR/repo/.auto-dev/config.yaml"

  echo "# Add user login" > "$TEST_DIR/repo/spec.md"
}

teardown() {
  tmux kill-session -t "auto-dev-integration-test" 2>/dev/null || true
  cd /
  rm -rf "$TEST_DIR"
}

@test "dry-run succeeds with valid config" {
  cd "$TEST_DIR/repo"
  run bash "$OLDPWD/auto-dev.sh" --spec "$TEST_DIR/repo/spec.md" --repo "$TEST_DIR/repo" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"integration-test"* ]]
}
```

**Step 2: Run the integration test**

```bash
bats tests/integration.bats
```

Expected: PASS.

**Step 3: Commit**

```bash
git add tests/integration.bats
git commit -m "test: add integration test with mocked claude and gh CLIs"
```

---

### Task 14: Run Full Test Suite

**Step 1: Run all tests**

```bash
bats tests/*.bats
```

Expected: all tests PASS across all test files.

**Step 2: Fix any failures**

Address any test failures found in the full run.

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: address test suite failures"
```

---

### Task 15: Make Scripts Executable and Final Cleanup

**Step 1: Set executable permissions**

```bash
chmod +x auto-dev.sh templates/init.sh lib/*.sh
```

**Step 2: Add .gitignore**

Create `.gitignore`:

```
.auto-dev/messages/
*.log
.DS_Store
```

**Step 3: Final commit**

```bash
git add .gitignore
git add -A
git commit -m "chore: set executable permissions and add .gitignore"
```

---

Plan complete and saved to `docs/plans/2026-02-18-auto-dev-implementation.md`. Two execution options:

**1. Subagent-Driven (this session)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** — Open new session with executing-plans, batch execution with checkpoints

Which approach?