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
  echo "  --spec <file>    Path to the feature spec (default: first .md in .specify/specs/)"
  echo ""
  echo "Chunk files in .specify/specs/chunks/ are picked up automatically."
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
    --help|-h) usage ;;
    *) usage ;;
  esac
done

# --- Resolve spec file and chunks ---
MANUAL_CHUNKS=false
CHUNK_FILES=()

if [[ -z "$SPEC_FILE" ]]; then
  SPECS_DIR="$REPO_DIR/.specify/specs"
  CHUNKS_DIR="$REPO_DIR/.specify/specs/chunks"

  # Check for manual chunks first
  if [[ -d "$CHUNKS_DIR" ]]; then
    while IFS= read -r f; do
      CHUNK_FILES+=("$f")
    done < <(find "$CHUNKS_DIR" -maxdepth 1 -name '*.md' -type f | sort)

    if [[ ${#CHUNK_FILES[@]} -gt 0 ]]; then
      MANUAL_CHUNKS=true
      SPEC_FILE="${CHUNK_FILES[0]}"
    fi
  fi

  # Filter out skip_specs after config is available (deferred to post-parse)

  # Fall back to single spec in specs/
  if [[ "$MANUAL_CHUNKS" != "true" && -d "$SPECS_DIR" ]]; then
    SPEC_FILE="$(find "$SPECS_DIR" -maxdepth 1 -name '*.md' -type f | head -1)"
  fi

  [[ -z "$SPEC_FILE" ]] && echo "Error: no spec provided and no .md files in .specify/specs/" >&2 && exit 1
fi

[[ ! -f "$SPEC_FILE" ]] && echo "Error: spec file not found: $SPEC_FILE" >&2 && exit 1

CONFIG_FILE="$REPO_DIR/.specify/config.yaml"
[[ ! -f "$CONFIG_FILE" ]] && echo "Error: config not found: $CONFIG_FILE" >&2 && exit 1

parse_config "$CONFIG_FILE"

# Filter out skip_specs from manual chunks
if [[ "$MANUAL_CHUNKS" = "true" && ${#CFG_SKIP_SPECS[@]} -gt 0 ]]; then
  FILTERED_CHUNKS=()
  SKIPPED_CHUNKS=()
  for cf in "${CHUNK_FILES[@]}"; do
    chunk_basename="$(basename "$cf")"
    skip=false
    for skip_name in "${CFG_SKIP_SPECS[@]}"; do
      if [[ "$chunk_basename" = "$skip_name" ]]; then
        skip=true
        break
      fi
    done
    if [[ "$skip" = "true" ]]; then
      SKIPPED_CHUNKS+=("$chunk_basename")
    else
      FILTERED_CHUNKS+=("$cf")
    fi
  done
  CHUNK_FILES=("${FILTERED_CHUNKS[@]}")
  if [[ ${#CHUNK_FILES[@]} -eq 0 ]]; then
    echo "Error: all chunk files were skipped by skip_specs config" >&2
    exit 1
  fi
  SPEC_FILE="${CHUNK_FILES[0]}"
  if [[ ${#SKIPPED_CHUNKS[@]} -gt 0 ]]; then
    echo "Skipping ${#SKIPPED_CHUNKS[@]} spec(s): ${SKIPPED_CHUNKS[*]}"
  fi
fi

REPO_DIR="$(cd "$REPO_DIR" && pwd)"
MESSAGES_DIR="$REPO_DIR/.specify/messages"
PROMPTS_DIR="$REPO_DIR/.specify/prompts"

if [[ "$MANUAL_CHUNKS" = "true" ]]; then
  FEATURE_NAME="${CFG_PROJECT_NAME}"
else
  FEATURE_NAME="$(basename "$SPEC_FILE" .md)"
fi
SESSION_NAME="auto-dev-${CFG_PROJECT_NAME}"

# --- Dry run ---
if [[ "$DRY_RUN" = true ]]; then
  echo "=== Dry run: Auto-Dev Execution Plan ==="
  echo ""
  echo "Project:        $CFG_PROJECT_NAME"
  echo "Spec:           $SPEC_FILE"
  echo "Dev agents:     $CFG_DEV_AGENTS"
  echo "Max rounds:     $CFG_MAX_ROUNDS"
  echo "Dev model:      $CFG_DEV_MODEL"
  echo "Reviewer model: $CFG_REVIEWER_MODEL"
  echo "Agent timeout:  ${CFG_AGENT_TIMEOUT}s"
  if [[ -n "$CFG_DEV_FALLBACK_MODEL" ]]; then
    echo "Dev fallback:   $CFG_DEV_FALLBACK_MODEL"
  fi
  if [[ -n "$CFG_REVIEWER_FALLBACK_MODEL" ]]; then
    echo "Rev fallback:   $CFG_REVIEWER_FALLBACK_MODEL"
  fi
  echo "Phases:         plan=${CFG_PHASE_PLAN} dev=${CFG_PHASE_DEV} review=${CFG_PHASE_REVIEW} commit=${CFG_PHASE_COMMIT} pr=${CFG_PHASE_PR}"
  echo "App command:    $CFG_APP_COMMAND"
  echo "Review skills:  ${CFG_REVIEWER_SKILLS[*]}"
  echo "Severity gate:  $CFG_SEVERITY_GATE"
  echo "Dev tools:      $CFG_DEV_TOOLS"
  echo "Reviewer tools: $CFG_REVIEWER_TOOLS"
  if [[ ${#CFG_SKIP_SPECS[@]} -gt 0 ]]; then
    echo "Skip specs:     ${CFG_SKIP_SPECS[*]}"
  fi
  if [[ "$MANUAL_CHUNKS" = "true" ]]; then
    echo "Chunking:       manual (${#CHUNK_FILES[@]} chunk files)"
    for cf in "${CHUNK_FILES[@]}"; do
      echo "                  - $(basename "$cf")"
    done
  elif [[ "$CFG_CHUNKING_ENABLED" = "true" ]]; then
    echo "Chunking:       enabled (max $CFG_MAX_CHUNKS chunks)"
    echo "Planner model:  $CFG_PLANNER_MODEL"
  else
    echo "Chunking:       disabled"
  fi
  echo ""
  echo "Panes: summary | app-runner | reviewer | dev-1..dev-${CFG_DEV_AGENTS}"
  echo ""
  echo "Dry run complete. Remove --dry-run to execute."
  exit 0
fi

# --- Setup ---
mkdir -p "$MESSAGES_DIR"
rm -f "$MESSAGES_DIR/costs.log" "$MESSAGES_DIR/tokens.log"

if [[ "$MANUAL_CHUNKS" = "true" ]]; then
  # Manual chunks: copy each file to messages/chunks/, build plan.json
  mkdir -p "$MESSAGES_DIR/chunks"
  TOTAL_CHUNKS=${#CHUNK_FILES[@]}

  PLAN_CHUNKS_JSON="["
  for ((i = 0; i < TOTAL_CHUNKS; i++)); do
    chunk_file="${CHUNK_FILES[$i]}"
    chunk_num=$((i + 1))
    cp "$chunk_file" "$MESSAGES_DIR/chunks/chunk-${chunk_num}.md"

    chunk_basename="$(basename "$chunk_file" .md)"
    chunk_title="$(echo "$chunk_basename" | sed 's/^[0-9]*[-_ ]*//')"

    [[ $i -gt 0 ]] && PLAN_CHUNKS_JSON+=","
    PLAN_CHUNKS_JSON+="{\"id\":${chunk_num},\"title\":\"${chunk_title}\",\"file\":\"chunks/chunk-${chunk_num}.md\",\"estimated_files\":0}"
  done
  PLAN_CHUNKS_JSON+="]"

  jq -n --argjson chunks "$PLAN_CHUNKS_JSON" --argjson total "$TOTAL_CHUNKS" \
    '{total_chunks: $total, chunks: $chunks}' > "$MESSAGES_DIR/plan.json"

  cp "$MESSAGES_DIR/chunks/chunk-1.md" "$MESSAGES_DIR/spec.md"
  CFG_CHUNKING_ENABLED="true"

  echo "Discovered $TOTAL_CHUNKS manual chunk(s) from .specify/specs/"
else
  cp "$SPEC_FILE" "$MESSAGES_DIR/spec.md"
  if [[ "$CFG_CHUNKING_ENABLED" = "true" ]]; then
    cp "$SPEC_FILE" "$MESSAGES_DIR/spec-full.md"
    mkdir -p "$MESSAGES_DIR/chunks"
  fi
fi
init_workflow "$MESSAGES_DIR" "$SPEC_FILE" "$CFG_MAX_ROUNDS"
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
model="${7:-}"
agent_timeout="${8:-900}"
fallback_model="${9:-}"

debug_log="${log_file%.log}-debug.log"

cd "$repo_dir" || { echo "ERROR: cd $repo_dir failed" | tee "$log_file" >> "$debug_log"; exit 1; }

if [[ ! -f "$prompt_file" ]]; then
  echo "ERROR: prompt file not found: $prompt_file" | tee "$log_file" >> "$debug_log"
  echo "0" >> "$tokens_file"; echo "0" >> "$costs_file"
  exit 1
fi

if ! command -v claude &>/dev/null; then
  echo "ERROR: claude not found in PATH" | tee "$log_file" >> "$debug_log"
  echo "PATH=$PATH" >> "$debug_log"
  echo "0" >> "$tokens_file"; echo "0" >> "$costs_file"
  exit 1
fi

model_args=()
if [[ -n "$model" && "$model" != "null" ]]; then
  model_args=(--model "$model")
fi

echo "$(date): starting claude -p (model=${model:-default}, timeout=${agent_timeout}s, tools=$tools)" >> "$debug_log"
echo "$(date): prompt_file=$prompt_file ($(wc -c < "$prompt_file" | tr -d ' ') bytes)" >> "$debug_log"

prompt_content="$(cat "$prompt_file")"
timeout "${agent_timeout}s" claude -p "$prompt_content" \
  --allowedTools "$tools" \
  --permission-mode acceptEdits \
  --no-session-persistence \
  "${model_args[@]}" 2>&1 | tee "$log_file"
exit_code=${PIPESTATUS[0]}

echo "$(date): claude exited with code $exit_code" >> "$debug_log"

if [[ $exit_code -eq 124 ]]; then
  echo "" >> "$log_file"
  echo "--- AGENT TIMED OUT after ${agent_timeout}s ---" >> "$log_file"
fi

# Retry with fallback model on timeout or zero output
if [[ ($exit_code -eq 124 || ! -s "$log_file") && -n "$fallback_model" && "$fallback_model" != "$model" ]]; then
  echo "$(date): retrying with fallback model: $fallback_model" >> "$debug_log"
  echo "" >> "$log_file"
  echo "--- Retrying with fallback model: $fallback_model ---" >> "$log_file"
  prompt_content="$(cat "$prompt_file")"
  timeout "${agent_timeout}s" claude -p "$prompt_content" \
    --allowedTools "$tools" \
    --permission-mode acceptEdits \
    --no-session-persistence \
    --model "$fallback_model" 2>&1 | tee -a "$log_file"
  exit_code=${PIPESTATUS[0]}
  echo "$(date): fallback exited with code $exit_code" >> "$debug_log"
  if [[ $exit_code -eq 124 ]]; then
    echo "" >> "$log_file"
    echo "--- FALLBACK AGENT TIMED OUT after ${agent_timeout}s ---" >> "$log_file"
  fi
fi

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
CFG_DEV_MODEL="$CFG_DEV_MODEL"
CFG_REVIEWER_MODEL="$CFG_REVIEWER_MODEL"
CFG_AGENT_TIMEOUT="$CFG_AGENT_TIMEOUT"
CFG_DEV_FALLBACK_MODEL="$CFG_DEV_FALLBACK_MODEL"
CFG_REVIEWER_FALLBACK_MODEL="$CFG_REVIEWER_FALLBACK_MODEL"
CFG_PHASE_PLAN="$CFG_PHASE_PLAN"
CFG_PHASE_DEV="$CFG_PHASE_DEV"
CFG_PHASE_REVIEW="$CFG_PHASE_REVIEW"
CFG_PHASE_COMMIT="$CFG_PHASE_COMMIT"
CFG_PHASE_PR="$CFG_PHASE_PR"
CFG_DEV_TOOLS="$CFG_DEV_TOOLS"
CFG_REVIEWER_TOOLS="$CFG_REVIEWER_TOOLS"
CFG_PLANNER_TOOLS="$CFG_PLANNER_TOOLS"
CFG_COMPACTION_ENABLED="$CFG_COMPACTION_ENABLED"
CFG_COMPACTION_MODEL="$CFG_COMPACTION_MODEL"
CFG_COMPACTION_MAX_CHARS="$CFG_COMPACTION_MAX_CHARS"
CFG_CHUNKING_ENABLED="$CFG_CHUNKING_ENABLED"
CFG_MAX_CHUNKS="$CFG_MAX_CHUNKS"
CFG_PLANNER_MODEL="$CFG_PLANNER_MODEL"
CFG_PLANNER_TIMEOUT="$CFG_PLANNER_TIMEOUT"
MANUAL_CHUNKS="$MANUAL_CHUNKS"
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
TOTAL_CHUNKS=1
CURRENT_CHUNK=0
VERDICT=""

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

# ============================================================
# PLANNING PHASE (chunking: planner or manual)
# ============================================================
if [[ "\$CFG_CHUNKING_ENABLED" = "true" ]]; then

  if [[ "\$MANUAL_CHUNKS" = "true" ]]; then
    # --- MANUAL CHUNKS: plan.json already built by setup ---
    TOTAL_CHUNKS="\$(jq -r '.total_chunks' "\$MESSAGES_DIR/plan.json")"
    echo ""
    echo "=== Manual Chunks — \$TOTAL_CHUNKS chunk(s) discovered ==="
    echo ""
    for ((c = 1; c <= TOTAL_CHUNKS; c++)); do
      CHUNK_TITLE="\$(jq -r ".chunks[\$((c-1))].title" "\$MESSAGES_DIR/plan.json")"
      echo "  \$c. \$CHUNK_TITLE"
    done
    echo ""

  elif [[ "\$CFG_PHASE_PLAN" = "true" ]]; then
    # --- AUTO PLANNING: run planner agent ---
    update_summary_phase "\$MESSAGES_DIR" "planning"

    planner_prompt="\$(render_prompt "\$PROMPTS_DIR/planner-agent.md" \
      "STANDARDS_FILE=\$CFG_STANDARDS_FILE" \
      "MAX_CHUNKS=\$CFG_MAX_CHUNKS")"

    planner_prompt_file="\$MESSAGES_DIR/planner-prompt.md"
    echo "\$planner_prompt" > "\$planner_prompt_file"

    update_agent_status "\$MESSAGES_DIR" "planner" "planning"

    send_to_pane "\$SESSION_NAME" "dev-1" \
      "bash \$MESSAGES_DIR/_run-claude.sh \$planner_prompt_file \$MESSAGES_DIR/planner.log \$MESSAGES_DIR/costs.log \$MESSAGES_DIR/tokens.log '\$CFG_PLANNER_TOOLS' \$REPO_DIR \$CFG_PLANNER_MODEL \$CFG_PLANNER_TIMEOUT"

    echo ""
    echo "=== Planning Phase — Decomposing spec into chunks ==="
    PLAN_START=\$(date +%s)
    while [[ ! -f "\$MESSAGES_DIR/planner-status.json" ]] || \
          [[ "\$(jq -r '.status' "\$MESSAGES_DIR/planner-status.json" 2>/dev/null)" != "done" ]]; do
      show_progress "\$REPO_DIR" "\$SESSION_NAME" "dev-1" "\$PLAN_START" "planning" "\$MESSAGES_DIR"
      if wait_or_abort 5; then
        abort_workflow
      fi
    done
    echo ""
    echo "  Planner complete."
    print_agent_summary "\$MESSAGES_DIR/planner.log" "planner output"
    update_agent_status "\$MESSAGES_DIR" "planner" "done"

    TOTAL_CHUNKS="\$(jq -r '.total_chunks' "\$MESSAGES_DIR/plan.json")"

    # --- USER APPROVAL OF PLAN ---
    echo ""
    echo "=============================================="
    echo "  CHUNK PLAN — APPROVAL REQUIRED"
    echo "=============================================="
    echo ""
    echo "  Feature:     \$FEATURE_NAME"
    echo "  Total chunks: \$TOTAL_CHUNKS"
    echo ""

    for ((c = 1; c <= TOTAL_CHUNKS; c++)); do
      CHUNK_TITLE="\$(jq -r ".chunks[\$((c-1))].title" "\$MESSAGES_DIR/plan.json")"
      CHUNK_EST="\$(jq -r ".chunks[\$((c-1))].estimated_files" "\$MESSAGES_DIR/plan.json")"
      echo "  \$c. \$CHUNK_TITLE (~\$CHUNK_EST files)"
    done

    echo ""
    echo "----------------------------------------------"
    echo "  [y] Approve plan and start implementation"
    echo "  [v] View chunk details, then decide"
    echo "  [n] Abort — do not implement"
    echo "----------------------------------------------"
    echo ""

    PLAN_APPROVED=false
    while true; do
      read -r -p "  > " PLAN_CHOICE </dev/tty
      case "\$PLAN_CHOICE" in
        y|Y)
          PLAN_APPROVED=true
          break
          ;;
        v|V)
          for ((c = 1; c <= TOTAL_CHUNKS; c++)); do
            echo ""
            echo "--- Chunk \$c ---"
            head -20 "\$MESSAGES_DIR/chunks/chunk-\${c}.md"
            echo "..."
          done
          echo ""
          echo "  [y] Approve plan and start implementation"
          echo "  [n] Abort — do not implement"
          ;;
        n|N)
          PLAN_APPROVED=false
          break
          ;;
        *)
          echo "  Please enter y, v, or n."
          ;;
      esac
    done

    if [[ "\$PLAN_APPROVED" != "true" ]]; then
      update_summary_phase "\$MESSAGES_DIR" "stopped"
      echo "  Plan rejected. Exiting."
      exit 0
    fi
  fi

fi

# ============================================================
# OUTER CHUNK LOOP
# ============================================================
for ((CURRENT_CHUNK = 1; CURRENT_CHUNK <= TOTAL_CHUNKS; CURRENT_CHUNK++)); do

  if [[ "\$CFG_CHUNKING_ENABLED" = "true" ]]; then
    # Swap spec.md with current chunk content
    cp "\$MESSAGES_DIR/chunks/chunk-\${CURRENT_CHUNK}.md" "\$MESSAGES_DIR/spec.md"

    CHUNK_TITLE="\$(jq -r ".chunks[\$((CURRENT_CHUNK-1))].title" "\$MESSAGES_DIR/plan.json")"

    # Create a branch for this chunk (short name from title)
    CHUNK_BRANCH="\$(echo "\$CHUNK_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-\$//' | cut -c1-50)"
    [[ -z "\$CHUNK_BRANCH" ]] && CHUNK_BRANCH="chunk-\${CURRENT_CHUNK}"
    cd "\$REPO_DIR" && git checkout -b "\$CHUNK_BRANCH" 2>/dev/null || true

    echo ""
    echo "=============================================="
    echo "  CHUNK \$CURRENT_CHUNK / \$TOTAL_CHUNKS: \$CHUNK_TITLE"
    echo "  Branch: \$CHUNK_BRANCH"
    echo "=============================================="

    update_summary_chunk "\$MESSAGES_DIR" "\$CURRENT_CHUNK" "\$TOTAL_CHUNKS" "\$CHUNK_TITLE"
  fi

  CURRENT_ROUND=1

  # --- DEV/REVIEW LOOP (per chunk) ---
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
        "bash \$MESSAGES_DIR/_run-claude.sh \$prompt_file \$MESSAGES_DIR/dev-\${i}-r\${CURRENT_ROUND}.log \$MESSAGES_DIR/costs.log \$MESSAGES_DIR/tokens.log '\$CFG_DEV_TOOLS' \$REPO_DIR \$CFG_DEV_MODEL \$CFG_AGENT_TIMEOUT \$CFG_DEV_FALLBACK_MODEL"
    done

    echo ""
    if [[ "\$CFG_CHUNKING_ENABLED" = "true" ]]; then
      echo "=== Chunk \$CURRENT_CHUNK — Round \$CURRENT_ROUND / \$CFG_MAX_ROUNDS — Development ==="
    else
      echo "=== Round \$CURRENT_ROUND / \$CFG_MAX_ROUNDS — Development ==="
    fi
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

    if [[ "\$CFG_COMPACTION_ENABLED" = "true" ]]; then
      echo "  Compacting dev agent context..."
      for ((i = 1; i <= CFG_DEV_AGENTS; i++)); do
        _log="\$MESSAGES_DIR/dev-\${i}-r\${CURRENT_ROUND}.log"
        _out="\$MESSAGES_DIR/dev-\${i}-r\${CURRENT_ROUND}-summary.md"
        if [[ -f "\$_log" && -s "\$_log" ]]; then
          _excerpt="\$(head -c "\$CFG_COMPACTION_MAX_CHARS" "\$_log")"
          timeout 60s claude -p "Summarize this dev agent session in 15 lines max. Sections: (1) Files changed, (2) Key decisions, (3) Errors/problems, (4) Test results. Be specific, no preamble.

---
\${_excerpt}" \
            --model "\$CFG_COMPACTION_MODEL" \
            --no-session-persistence > "\$_out" 2>/dev/null || echo "(summary unavailable)" > "\$_out"
        fi
      done
    fi

    if [[ "\$CFG_PHASE_REVIEW" = "true" ]]; then
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
        "bash \$MESSAGES_DIR/_run-claude.sh \$reviewer_prompt_file \$MESSAGES_DIR/reviewer-r\${CURRENT_ROUND}.log \$MESSAGES_DIR/costs.log \$MESSAGES_DIR/tokens.log '\$CFG_REVIEWER_TOOLS' \$REPO_DIR \$CFG_REVIEWER_MODEL \$CFG_AGENT_TIMEOUT \$CFG_REVIEWER_FALLBACK_MODEL"

      if [[ "\$CFG_CHUNKING_ENABLED" = "true" ]]; then
        echo "=== Chunk \$CURRENT_CHUNK — Round \$CURRENT_ROUND / \$CFG_MAX_ROUNDS — Review ==="
      else
        echo "=== Round \$CURRENT_ROUND / \$CFG_MAX_ROUNDS — Review ==="
      fi
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

      if [[ "\$CFG_COMPACTION_ENABLED" = "true" ]]; then
        _log="\$MESSAGES_DIR/reviewer-r\${CURRENT_ROUND}.log"
        _out="\$MESSAGES_DIR/reviewer-r\${CURRENT_ROUND}-summary.md"
        if [[ -f "\$_log" && -s "\$_log" ]]; then
          _excerpt="\$(head -c "\$CFG_COMPACTION_MAX_CHARS" "\$_log")"
          timeout 60s claude -p "Summarize this code review in 10 lines max. Sections: (1) Verdict and reason, (2) Critical/High issues with file:line, (3) Files reviewed. Be specific, no preamble.

---
\${_excerpt}" \
            --model "\$CFG_COMPACTION_MODEL" \
            --no-session-persistence > "\$_out" 2>/dev/null || true
        fi
      fi

      if ! should_continue "\$VERDICT" "\$CURRENT_ROUND" "\$CFG_MAX_ROUNDS"; then
        break
      fi
    else
      VERDICT="approved"
      echo "  Review phase skipped (phases.review=false). Auto-approving."
      break
    fi

    echo ""
    echo "  Committing WIP and starting next round..."
    send_to_pane "\$SESSION_NAME" "dev-1" \
      "cd \$REPO_DIR && git add -A -- . ':!.specify' && git commit -m 'wip: address review feedback'"
    sleep 5

    # Build prior-context.md for next round's dev agents
    PRIOR_FILES=""
    for sf in "\$MESSAGES_DIR"/dev-*-status.json; do
      [[ -f "\$sf" ]] || continue
      files="\$(jq -r '.files_changed // [] | join(", ")' "\$sf" 2>/dev/null || true)"
      [[ -n "\$files" ]] && PRIOR_FILES+="\$files, "
    done
    PRIOR_FILES="\${PRIOR_FILES%, }"
    PRIOR_REVIEW_SUMMARY=""
    if [[ -f "\$MESSAGES_DIR/reviewer-feedback.md" ]]; then
      PRIOR_REVIEW_SUMMARY="\$(grep -A 3 '## Summary' "\$MESSAGES_DIR/reviewer-feedback.md" | grep -v '^##' | tr '\n' ' ' || true)"
    fi
    {
      printf "## Round %s Summary\n" "\$CURRENT_ROUND"
      printf "Files modified: %s\n" "\${PRIOR_FILES:-none recorded}"
      printf "Review summary: %s\n" "\${PRIOR_REVIEW_SUMMARY:-no review yet}"
      printf "Full feedback: See .specify/messages/reviewer-feedback.md\n"
      if [[ "\$CFG_COMPACTION_ENABLED" = "true" ]]; then
        for ((i = 1; i <= CFG_DEV_AGENTS; i++)); do
          _s="\$MESSAGES_DIR/dev-\${i}-r\${CURRENT_ROUND}-summary.md"
          if [[ -f "\$_s" ]]; then
            printf "\n### Dev-%d Compact Summary\n" "\$i"
            cat "\$_s"
          fi
        done
        _rs="\$MESSAGES_DIR/reviewer-r\${CURRENT_ROUND}-summary.md"
        if [[ -f "\$_rs" ]]; then
          printf "\n### Reviewer Compact Summary\n"
          cat "\$_rs"
        fi
      fi
    } > "\$MESSAGES_DIR/prior-context.md"

    increment_round "\$MESSAGES_DIR"
    CURRENT_ROUND=\$((CURRENT_ROUND + 1))
    rm -f "\$MESSAGES_DIR"/dev-*-status.json
  done
  # --- end dev/review loop ---

  # --- PER-CHUNK COMMIT ---
  if [[ "\$CFG_CHUNKING_ENABLED" = "true" ]]; then
    CHUNK_TITLE="\$(jq -r ".chunks[\$((CURRENT_CHUNK-1))].title" "\$MESSAGES_DIR/plan.json")"

    if [[ "\$CFG_PHASE_COMMIT" = "true" ]]; then
      echo ""
      echo "  Committing chunk \$CURRENT_CHUNK: \$CHUNK_TITLE"
      send_to_pane "\$SESSION_NAME" "dev-1" \
        "cd \$REPO_DIR && git add -A -- . ':!.specify' && git commit -m 'feat(chunk-\${CURRENT_CHUNK}): \${CHUNK_TITLE}'"
      sleep 5
      echo "  Committed chunk \$CURRENT_CHUNK / \$TOTAL_CHUNKS."
    else
      echo "  Commit phase skipped (phases.commit=false) for chunk \$CURRENT_CHUNK."
    fi

    # Clean up for next chunk
    rm -f "\$MESSAGES_DIR"/dev-*-status.json
    rm -f "\$MESSAGES_DIR/reviewer-feedback.md"
  fi

done
# --- end outer chunk loop ---

# ============================================================
# FINALIZATION — approval before push + PR
# ============================================================
cd "\$REPO_DIR"

if [[ "\$CFG_CHUNKING_ENABLED" = "true" ]]; then
  # --- CHUNKED SUMMARY ---
  update_summary_phase "\$MESSAGES_DIR" "complete"
  FINAL_COST="\$(get_total_cost "\$MESSAGES_DIR")"
  FINAL_TOKENS="\$(get_total_tokens "\$MESSAGES_DIR")"

  echo ""
  echo "=============================================="
  echo "  ALL CHUNKS COMPLETE"
  echo "=============================================="
  echo ""
  echo "  Feature:  \$FEATURE_NAME"
  echo "  Chunks:   \$TOTAL_CHUNKS"
  echo "  Total cost: \\\$\$FINAL_COST | Total tokens: \$FINAL_TOKENS"

else
  # --- NON-CHUNKED FINALIZATION (original flow) ---

  if [[ "\$CFG_PHASE_COMMIT" != "true" && "\$CFG_PHASE_PR" != "true" ]]; then
    # Both commit and PR disabled — skip finalization
    update_summary_phase "\$MESSAGES_DIR" "complete"
    FINAL_COST="\$(get_total_cost "\$MESSAGES_DIR")"
    FINAL_TOKENS="\$(get_total_tokens "\$MESSAGES_DIR")"
    echo ""
    echo "  Workflow complete (commit and PR phases disabled)."
    echo "  Changes remain uncommitted in: \$REPO_DIR"
    echo "  Total cost: \\\$\$FINAL_COST | Total tokens: \$FINAL_TOKENS"

  else
    update_summary_phase "\$MESSAGES_DIR" "awaiting_approval"

    echo ""
    echo "=============================================="
    echo "  WORKFLOW COMPLETE — APPROVAL REQUIRED"
    echo "=============================================="
    echo ""
    echo "  Feature:  \$FEATURE_NAME"
    echo "  Rounds:   \$CURRENT_ROUND / \$CFG_MAX_ROUNDS"
    echo "  Verdict:  \$VERDICT"
    echo ""
    echo "  Modified files:"
    git diff --stat HEAD 2>/dev/null | sed 's/^/    /'
    echo ""

    if [[ "\$CFG_PHASE_COMMIT" = "true" && "\$CFG_PHASE_PR" = "true" ]]; then
      COMMIT_LABEL="Commit, push & create PR"
    elif [[ "\$CFG_PHASE_COMMIT" = "true" ]]; then
      COMMIT_LABEL="Commit changes (PR creation disabled)"
    fi

    echo "  Proposed commit: feat: \${FEATURE_NAME}"
    if [[ "\$CFG_PHASE_PR" = "true" ]]; then
      echo "  Proposed PR:     auto-dev: \$FEATURE_NAME"
    fi
    echo ""
    echo "----------------------------------------------"
    echo "  [y] \$COMMIT_LABEL"
    echo "  [d] Show full diff, then decide"
    echo "  [n] Skip — leave changes uncommitted"
    echo "----------------------------------------------"
    echo ""

    APPROVED=false
    while true; do
      read -r -p "  > " APPROVAL_CHOICE </dev/tty
      case "\$APPROVAL_CHOICE" in
        y|Y)
          APPROVED=true
          break
          ;;
        d|D)
          echo ""
          git diff HEAD 2>/dev/null | head -200
          echo ""
          echo "  (showing first 200 lines — full diff in working tree)"
          echo ""
          echo "  [y] \$COMMIT_LABEL"
          echo "  [n] Skip — leave changes uncommitted"
          ;;
        n|N)
          APPROVED=false
          break
          ;;
        *)
          echo "  Please enter y, d, or n."
          ;;
      esac
    done

    if [[ "\$APPROVED" = true ]]; then
      update_summary_phase "\$MESSAGES_DIR" "finalizing"

      if [[ "\$CFG_PHASE_COMMIT" = "true" ]]; then
        send_to_pane "\$SESSION_NAME" "dev-1" \
          "cd \$REPO_DIR && git add -A -- . ':!.specify' && git commit -m 'feat: \${FEATURE_NAME}'"
        sleep 5
      fi

      if [[ "\$CFG_PHASE_PR" = "true" ]]; then
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
      fi

      update_summary_phase "\$MESSAGES_DIR" "complete"
      FINAL_COST="\$(get_total_cost "\$MESSAGES_DIR")"
      FINAL_TOKENS="\$(get_total_tokens "\$MESSAGES_DIR")"
      echo ""
      echo "  Auto-dev complete."
      echo "  Total cost: \\\$\$FINAL_COST | Total tokens: \$FINAL_TOKENS"
    else
      update_summary_phase "\$MESSAGES_DIR" "stopped"
      FINAL_COST="\$(get_total_cost "\$MESSAGES_DIR")"
      FINAL_TOKENS="\$(get_total_tokens "\$MESSAGES_DIR")"
      echo ""
      echo "  Skipped commit/PR. Changes remain uncommitted in: \$REPO_DIR"
      echo "  Total cost: \\\$\$FINAL_COST | Total tokens: \$FINAL_TOKENS"
      echo ""
      echo "  To commit manually:"
      echo "    cd \$REPO_DIR"
      echo "    git add -A -- . ':!.specify' && git commit -m 'feat: \$FEATURE_NAME'"
      echo "    gh pr create --title 'auto-dev: \$FEATURE_NAME'"
    fi
  fi
fi
ORCHEOF

chmod +x "$ORCHESTRATOR_SCRIPT"

# --- Launch orchestrator in summary pane, attach immediately ---
send_to_pane "$SESSION_NAME" "summary" \
  "bash $ORCHESTRATOR_SCRIPT 2>&1 | tee $MESSAGES_DIR/orchestrator.log"

if [[ "$DETACHED" = false ]]; then
  tmux attach-session -t "$SESSION_NAME"
else
  echo "Auto-dev running in detached mode. Attach with: tmux attach -t $SESSION_NAME"
  # Wait for orchestrator to finish (complete or stopped by user)
  while true; do
    PHASE="$(jq -r '.phase' "$MESSAGES_DIR/summary.json" 2>/dev/null || echo "unknown")"
    [[ "$PHASE" = "complete" || "$PHASE" = "stopped" ]] && break
    sleep 10
  done
  echo "Auto-dev finished (phase: $PHASE)."
fi
