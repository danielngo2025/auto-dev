#!/usr/bin/env bash
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
  echo "Usage: auto-dev.sh [--spec <spec.md>] --repo <path> [--dry-run] [--detached]"
  echo ""
  echo "Options:"
  echo "  --spec <file>    Path to the feature spec (default: first .md in .auto-dev/specs/)"
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

# --- Resolve spec file ---
if [[ -z "$SPEC_FILE" ]]; then
  SPECS_DIR="$REPO_DIR/.auto-dev/specs"
  if [[ -d "$SPECS_DIR" ]]; then
    SPEC_FILE="$(find "$SPECS_DIR" -maxdepth 1 -name '*.md' -type f | head -1)"
  fi
  [[ -z "$SPEC_FILE" ]] && echo "Error: no spec provided and no .md files in .auto-dev/specs/" >&2 && exit 1
fi

[[ ! -f "$SPEC_FILE" ]] && echo "Error: spec file not found: $SPEC_FILE" >&2 && exit 1

CONFIG_FILE="$REPO_DIR/.auto-dev/config.yaml"
[[ ! -f "$CONFIG_FILE" ]] && echo "Error: config not found: $CONFIG_FILE" >&2 && exit 1

parse_config "$CONFIG_FILE"

REPO_DIR="$(cd "$REPO_DIR" && pwd)"
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
create_session "$SESSION_NAME" "$CFG_DEV_AGENTS"

# Unset CLAUDECODE in all panes so nested claude sessions can launch
for pane_target in $(tmux list-panes -t "$SESSION_NAME" -a -F '#{pane_id}'); do
  tmux send-keys -t "$pane_target" "unset CLAUDECODE" C-m
done
sleep 1

# Start app runner
if [[ -n "$CFG_APP_COMMAND" ]]; then
  send_to_pane "$SESSION_NAME" "app-runner" \
    "cd $REPO_DIR && $CFG_APP_COMMAND 2>&1 | tee $MESSAGES_DIR/app-output.log"
fi

# Build skills list and watch patterns strings for prompt rendering
SKILLS_LIST=""
for skill in "${CFG_REVIEWER_SKILLS[@]}"; do
  SKILLS_LIST="${SKILLS_LIST}   - ${skill}\n"
done

WATCH_PATTERNS_STR=""
for pattern in "${CFG_WATCH_PATTERNS[@]}"; do
  WATCH_PATTERNS_STR="${WATCH_PATTERNS_STR} \"${pattern}\""
done

# --- Write agent runner wrapper (streams output to pane, captures log for summary) ---
AGENT_RUNNER="$MESSAGES_DIR/_run-claude.sh"
cat > "$AGENT_RUNNER" << 'RUNEOF'
#!/usr/bin/env bash
prompt_file="$1"
log_file="$2"
costs_file="$3"
tokens_file="$4"
tools="$5"
repo_dir="$6"

cd "$repo_dir"

claude -p "$(cat "$prompt_file")" --allowedTools "$tools" 2>&1 | tee "$log_file"

char_count=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ' || echo "0")
est_tokens=$((char_count / 4))
echo "$est_tokens" >> "$tokens_file"
echo "0" >> "$costs_file"
RUNEOF
chmod +x "$AGENT_RUNNER"

# --- Write orchestrator script to run inside tmux ---
ORCHESTRATOR_SCRIPT="$MESSAGES_DIR/_orchestrator.sh"
cat > "$ORCHESTRATOR_SCRIPT" << ORCHEOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$SCRIPT_DIR"
source "\$SCRIPT_DIR/lib/orchestrator.sh"
source "\$SCRIPT_DIR/lib/prompt-renderer.sh"
source "\$SCRIPT_DIR/lib/tmux-setup.sh"

MESSAGES_DIR="$MESSAGES_DIR"
PROMPTS_DIR="$PROMPTS_DIR"
REPO_DIR="$REPO_DIR"
SESSION_NAME="$SESSION_NAME"
FEATURE_NAME="$FEATURE_NAME"
SPEC_FILE="$SPEC_FILE"
CFG_DEV_AGENTS=$CFG_DEV_AGENTS
CFG_MAX_ROUNDS=$CFG_MAX_ROUNDS
CFG_STANDARDS_FILE="$CFG_STANDARDS_FILE"
CFG_SEVERITY_GATE="$CFG_SEVERITY_GATE"
SKILLS_LIST="$SKILLS_LIST"
WATCH_PATTERNS_STR="$WATCH_PATTERNS_STR"

# Rebuild PANE_MAP
declare -gA PANE_MAP=()
PANE_MAP["summary"]="\${SESSION_NAME}:0.0"
PANE_MAP["app-runner"]="\${SESSION_NAME}:0.1"
PANE_MAP["reviewer"]="\${SESSION_NAME}:0.2"
for ((i = 1; i <= CFG_DEV_AGENTS; i++)); do
  PANE_MAP["dev-\${i}"]="\${SESSION_NAME}:0.\$((i + 2))"
done

CURRENT_ROUND=1

# Cleanup on abort
abort_workflow() {
  echo ""
  echo "  Aborted by user. Cleaning up..."
  update_summary_phase "\$MESSAGES_DIR" "aborted"
  kill_session "\$SESSION_NAME" 2>/dev/null || true
  exit 1
}
trap abort_workflow INT TERM

echo "  Press ESC or 'q' to abort workflow."
echo ""

while true; do
  update_summary_phase "\$MESSAGES_DIR" "development"

  for ((i = 1; i <= CFG_DEV_AGENTS; i++)); do
    rendered_prompt="\$(render_prompt "\$PROMPTS_DIR/dev-agent.md" \
      "STANDARDS_FILE=\$CFG_STANDARDS_FILE" \
      "WATCH_PATTERNS=\$WATCH_PATTERNS_STR" \
      "AGENT_ID=\$i" \
      "ROUND=\$CURRENT_ROUND")"

    prompt_file="\$MESSAGES_DIR/dev-\${i}-prompt-r\${CURRENT_ROUND}.md"
    echo "\$rendered_prompt" > "\$prompt_file"

    update_agent_status "\$MESSAGES_DIR" "dev-\$i" "implementing"

    send_to_pane "\$SESSION_NAME" "dev-\$i" \
      "bash \$MESSAGES_DIR/_run-claude.sh \$prompt_file \$MESSAGES_DIR/dev-\${i}-r\${CURRENT_ROUND}.log \$MESSAGES_DIR/costs.log \$MESSAGES_DIR/tokens.log 'Edit,Write,Read,Bash,Grep,Glob' \$REPO_DIR"
  done

  echo ""
  echo "=== Round \$CURRENT_ROUND / \$CFG_MAX_ROUNDS — Development ==="
  DEV_START=\$(date +%s)
  while ! check_dev_status "\$MESSAGES_DIR" "\$CFG_DEV_AGENTS"; do
    show_progress "\$REPO_DIR" "\$SESSION_NAME" "dev-1" "\$DEV_START" "dev implementing" "\$MESSAGES_DIR"
    if wait_or_abort 5; then
      abort_workflow
    fi
  done
  echo ""
  echo "  Dev agent(s) complete."

  for ((i = 1; i <= CFG_DEV_AGENTS; i++)); do
    print_agent_summary "\$MESSAGES_DIR/dev-\${i}-r\${CURRENT_ROUND}.log" "dev-\$i output"
  done
  echo ""

  update_summary_phase "\$MESSAGES_DIR" "review"
  update_agent_status "\$MESSAGES_DIR" "reviewer" "reviewing"

  reviewer_prompt="\$(render_prompt "\$PROMPTS_DIR/reviewer-agent.md" \
    "STANDARDS_FILE=\$CFG_STANDARDS_FILE" \
    "REVIEWER_SKILLS=${CFG_REVIEWER_SKILLS[*]}" \
    "SEVERITY_GATE=\$CFG_SEVERITY_GATE" \
    "BASE_BRANCH=main" \
    "ROUND=\$CURRENT_ROUND" \
    "SKILLS_LIST=\$SKILLS_LIST")"

  reviewer_prompt_file="\$MESSAGES_DIR/reviewer-prompt-r\${CURRENT_ROUND}.md"
  echo "\$reviewer_prompt" > "\$reviewer_prompt_file"

  send_to_pane "\$SESSION_NAME" "reviewer" \
    "bash \$MESSAGES_DIR/_run-claude.sh \$reviewer_prompt_file \$MESSAGES_DIR/reviewer-r\${CURRENT_ROUND}.log \$MESSAGES_DIR/costs.log \$MESSAGES_DIR/tokens.log 'Read,Write,Edit,Bash,Grep,Glob' \$REPO_DIR"

  echo "=== Round \$CURRENT_ROUND / \$CFG_MAX_ROUNDS — Review ==="
  REV_START=\$(date +%s)
  while [[ "\$(get_review_verdict "\$MESSAGES_DIR")" = "pending" ]]; do
    show_progress "\$REPO_DIR" "\$SESSION_NAME" "reviewer" "\$REV_START" "reviewing" "\$MESSAGES_DIR"
    if wait_or_abort 5; then
      abort_workflow
    fi
  done
  echo ""

  VERDICT="\$(get_review_verdict "\$MESSAGES_DIR")"
  update_agent_status "\$MESSAGES_DIR" "reviewer" "done"

  print_agent_summary "\$MESSAGES_DIR/reviewer-r\${CURRENT_ROUND}.log" "reviewer output"
  echo "  Verdict: \$VERDICT"

  if ! should_continue "\$VERDICT" "\$CURRENT_ROUND" "\$CFG_MAX_ROUNDS"; then
    break
  fi

  echo ""
  echo "  Committing WIP and starting next round..."
  send_to_pane "\$SESSION_NAME" "dev-1" \
    "cd \$REPO_DIR && git add -A -- . ':!.auto-dev' && git commit -m 'wip: address review feedback'"
  sleep 5

  increment_round "\$MESSAGES_DIR"
  CURRENT_ROUND=\$((CURRENT_ROUND + 1))
  rm -f "\$MESSAGES_DIR"/dev-*-status.json
  rm -f "\$MESSAGES_DIR/reviewer-feedback.md"
done

# --- Commit approved changes ---
update_summary_phase "\$MESSAGES_DIR" "finalizing"

send_to_pane "\$SESSION_NAME" "dev-1" \
  "cd \$REPO_DIR && git add -A -- . ':!.auto-dev' && git commit -m 'feat: \${FEATURE_NAME}'"
sleep 5

PR_BODY="## What\n\n"
PR_BODY+="Automated implementation of feature spec: \\\`\$FEATURE_NAME\\\`\n\n"
PR_BODY+="Source: \\\`\$SPEC_FILE\\\`\n\n"
if [[ -f "\$MESSAGES_DIR/reviewer-feedback.md" ]]; then
  PR_BODY+="### Changes\n\n\$(grep -A 100 '## Summary' "\$MESSAGES_DIR/reviewer-feedback.md" | head -5)\n\n"
fi
PR_BODY+="## Why\n\n"
PR_BODY+="Feature requested via auto-dev spec. Implementation validated through \$CURRENT_ROUND round(s) of automated code review.\n\n"
PR_BODY+="## Expected Result / Proof\n\n"
PR_BODY+="- Review rounds: \$CURRENT_ROUND / \$CFG_MAX_ROUNDS\n"
PR_BODY+="- Final verdict: **\$VERDICT**\n"
if [[ -f "\$MESSAGES_DIR/reviewer-feedback.md" ]]; then
  SCORE="\$(grep -o 'Score: [0-9]*/10' "\$MESSAGES_DIR/reviewer-feedback.md" | tail -1)"
  [[ -n "\$SCORE" ]] && PR_BODY+="- Reviewer score: **\$SCORE**\n"
  PR_BODY+="\n<details><summary>Full review</summary>\n\n\$(cat "\$MESSAGES_DIR/reviewer-feedback.md")\n\n</details>\n"
fi

send_to_pane "\$SESSION_NAME" "dev-1" \
  "cd \$REPO_DIR && gh pr create --title 'auto-dev: \$FEATURE_NAME' --body \"\$(echo -e "\$PR_BODY")\""

update_summary_phase "\$MESSAGES_DIR" "complete"
FINAL_COST="\$(get_total_cost "\$MESSAGES_DIR")"
FINAL_TOKENS="\$(get_total_tokens "\$MESSAGES_DIR")"
echo ""
echo "Auto-dev complete. Branch: $BRANCH_NAME"
echo "  Total cost: \\\$\$FINAL_COST | Total tokens: \$FINAL_TOKENS"
ORCHEOF

chmod +x "$ORCHESTRATOR_SCRIPT"

# --- Launch orchestrator in summary pane, attach immediately ---
send_to_pane "$SESSION_NAME" "summary" \
  "bash $ORCHESTRATOR_SCRIPT 2>&1 | tee $MESSAGES_DIR/orchestrator.log"

if [[ "$DETACHED" = false ]]; then
  tmux attach-session -t "$SESSION_NAME"
else
  echo "Auto-dev running in detached mode. Attach with: tmux attach -t $SESSION_NAME"
  # Wait for orchestrator to finish
  while [[ "$(jq -r '.phase' "$MESSAGES_DIR/summary.json" 2>/dev/null)" != "complete" ]]; do
    sleep 10
  done
  echo "Auto-dev complete. Branch: $BRANCH_NAME"
fi
