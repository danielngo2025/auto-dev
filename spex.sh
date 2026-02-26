#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/config-parser.sh"
source "$SCRIPT_DIR/lib/orchestrator.sh"
source "$SCRIPT_DIR/lib/prompt-renderer.sh"
source "$SCRIPT_DIR/lib/summary-watcher.sh"

# --- Argument parsing ---
SPEC_FILE=""
REPO_DIR="."
DRY_RUN=false

usage() {
  echo "Usage: spex.sh [--spec <spec.md>] --repo <path> [--dry-run]"
  echo ""
  echo "Options:"
  echo "  --spec <file>    Path to the feature spec (default: first .md in .specify/specs/)"
  echo ""
  echo "Chunk files in .specify/specs/chunks/ are picked up automatically."
  echo "  --repo <path>    Path to the target repository (default: .)"
  echo "  --dry-run        Show the execution plan without running"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) SPEC_FILE="$2"; shift 2 ;;
    --repo) REPO_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
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
  echo "Dry run complete. Remove --dry-run to execute."
  exit 0
fi

# --- Setup ---
mkdir -p "$MESSAGES_DIR"
rm -f "$MESSAGES_DIR/costs.log" "$MESSAGES_DIR/tokens.log"
rm -f "$MESSAGES_DIR"/dev-*-status.json "$MESSAGES_DIR/reviewer-feedback.md"

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

# Unset CLAUDECODE so nested claude sessions can launch
unset CLAUDECODE

# Start app runner in background
APP_RUNNER_PID=""
if [[ -n "$CFG_APP_COMMAND" ]]; then
  bash -c "cd '$REPO_DIR' && $CFG_APP_COMMAND" < /dev/null > "$MESSAGES_DIR/app-output.log" 2>&1 &
  APP_RUNNER_PID=$!
  echo "  App runner started (PID: $APP_RUNNER_PID)"
fi

# Build skills list and watch patterns strings for prompt rendering
SKILLS_LIST=""
for skill in "${CFG_REVIEWER_SKILLS[@]}"; do
  SKILLS_LIST="${SKILLS_LIST}   - ${skill}\n"
done

# Build dev skills list from .specify/skills/ directory
DEV_SKILLS_LIST=""
SKILLS_DIR="$REPO_DIR/.specify/skills"
if [[ -d "$SKILLS_DIR" ]]; then
  for skill_entry in "$SKILLS_DIR"/*; do
    [[ ! -e "$skill_entry" ]] && continue
    skill_name="$(basename "$skill_entry")"
    if [[ -d "$skill_entry" && -f "$skill_entry/SKILL.md" ]]; then
      DEV_SKILLS_LIST="${DEV_SKILLS_LIST}  - .specify/skills/${skill_name}/SKILL.md
"
    elif [[ -f "$skill_entry" ]]; then
      DEV_SKILLS_LIST="${DEV_SKILLS_LIST}  - .specify/skills/${skill_name}
"
    fi
  done
fi

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

# Use script -qF to allocate a pseudo-TTY so claude streams output in real-time
script -qF "$log_file" timeout "${agent_timeout}s" claude -p "$(cat "$prompt_file")" \
  --allowedTools "$tools" \
  --permission-mode acceptEdits \
  --no-session-persistence \
  "${model_args[@]}" < /dev/null
exit_code=$?

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
  script -qaF "$log_file" timeout "${agent_timeout}s" claude -p "$(cat "$prompt_file")" \
    --allowedTools "$tools" \
    --permission-mode acceptEdits \
    --no-session-persistence \
    --model "$fallback_model" < /dev/null
  exit_code=$?
  echo "$(date): fallback exited with code $exit_code" >> "$debug_log"
  if [[ $exit_code -eq 124 ]]; then
    echo "" >> "$log_file"
    echo "--- FALLBACK AGENT TIMED OUT after ${agent_timeout}s ---" >> "$log_file"
  fi
fi

output_chars=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ' || echo "0")
prompt_chars=$(wc -c < "$prompt_file" 2>/dev/null | tr -d ' ' || echo "0")
est_tokens=$(( (output_chars + prompt_chars) / 4 ))
echo "$est_tokens" >> "$tokens_file"
echo "0" >> "$costs_file"
RUNEOF
chmod +x "$AGENT_RUNNER"

# --- Write orchestrator script ---
ORCHESTRATOR_SCRIPT="$MESSAGES_DIR/_orchestrator.sh"
cat > "$ORCHESTRATOR_SCRIPT" << ORCHEOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$SCRIPT_DIR"
source "\$SCRIPT_DIR/lib/orchestrator.sh"
source "\$SCRIPT_DIR/lib/prompt-renderer.sh"

MESSAGES_DIR="$MESSAGES_DIR"
PROMPTS_DIR="$PROMPTS_DIR"
REPO_DIR="$REPO_DIR"
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
APP_RUNNER_PID="$APP_RUNNER_PID"

CURRENT_ROUND=1
TOTAL_CHUNKS=1
CURRENT_CHUNK=0
VERDICT=""
DEV_PIDS=()
REVIEWER_PID=""

# Productivity tracking
WORKFLOW_START=\$SECONDS
TOTAL_DEV_SECS=0
TOTAL_REVIEW_SECS=0
FIRST_ROUND_VERDICT=""

kill_agent_pids() {
  for pid in "\${DEV_PIDS[@]:-}"; do
    kill "\$pid" 2>/dev/null || true
  done
  [[ -n "\${REVIEWER_PID:-}" ]] && kill "\$REVIEWER_PID" 2>/dev/null || true
}

abort_workflow() {
  echo ""
  echo "  Aborted by user. Cleaning up..."
  update_summary_phase "\$MESSAGES_DIR" "aborted"
  kill_agent_pids
  [[ -n "\${APP_RUNNER_PID:-}" ]] && kill "\$APP_RUNNER_PID" 2>/dev/null || true
  exit 1
}
trap abort_workflow INT TERM

# Checks if any tracked PID is still alive. Returns 0 if at least one alive.
any_pid_alive() {
  for pid in "\${DEV_PIDS[@]:-}" "\${REVIEWER_PID:-}"; do
    [[ -n "\$pid" ]] && kill -0 "\$pid" 2>/dev/null && return 0
  done
  return 1
}

# Waits for a condition while showing elapsed timer and live agent output.
# ESC aborts workflow. Breaks early if all agent PIDs die.
# Args: <label> <check_command> [log_file_glob]
wait_with_timer() {
  local label="\$1"
  local check_cmd="\$2"
  local log_glob="\${3:-}"
  local start_time=\$SECONDS
  declare -A _log_offsets

  while ! eval "\$check_cmd"; do
    if ! any_pid_alive; then
      echo ""
      echo "  Warning: agent process(es) exited without completing."
      break
    fi

    # Show new lines from agent log files
    if [[ -n "\$log_glob" ]]; then
      for lf in \$log_glob; do
        [[ -f "\$lf" ]] || continue
        local cur_lines=\$(wc -l < "\$lf" | tr -d ' ')
        local prev=\${_log_offsets["\$lf"]:-0}
        if (( cur_lines > prev )); then
          local new_count=\$(( cur_lines - prev ))
          printf "\r%*s\r" 80 ""
          tail -n "\$new_count" "\$lf" | while IFS= read -r line; do
            local trimmed="\$(echo "\$line" | sed 's/^[[:space:]]*//' | cut -c1-120)"
            [[ -n "\$trimmed" ]] && printf "  │ %s\n" "\$trimmed"
          done
          _log_offsets["\$lf"]=\$cur_lines
        fi
      done
    fi

    local elapsed=\$(( SECONDS - start_time ))
    local mins=\$(( elapsed / 60 ))
    local secs=\$(( elapsed % 60 ))
    printf "\r  %s — %dm %02ds (ESC to abort)  " "\$label" "\$mins" "\$secs"

    if read -rsn1 -t 2 key </dev/tty 2>/dev/null; then
      if [[ "\$key" == \$'\x1b' ]]; then
        echo ""
        abort_workflow
      fi
    fi
  done
  local elapsed=\$(( SECONDS - start_time ))
  local mins=\$(( elapsed / 60 ))
  local secs=\$(( elapsed % 60 ))
  printf "\r  %s — done in %dm %02ds              \n" "\$label" "\$mins" "\$secs"
}

# Checks app-output.log for failure patterns. Returns 0 if healthy, 1 if failures found.
check_app_health() {
  local app_log="\$MESSAGES_DIR/app-output.log"
  [[ ! -f "\$app_log" ]] && return 0
  local patterns=(\$WATCH_PATTERNS_STR)
  for pat in "\${patterns[@]}"; do
    pat="\$(echo "\$pat" | tr -d '"')"
    if grep -q "\$pat" "\$app_log" 2>/dev/null; then
      echo "  Warning: app-output.log contains failure pattern: \$pat"
      return 1
    fi
  done
  return 0
}

# Prints end-of-run productivity summary report
print_run_summary() {
  local total_elapsed=\$(( SECONDS - WORKFLOW_START ))
  local total_mins=\$(( total_elapsed / 60 ))
  local total_secs=\$(( total_elapsed % 60 ))
  local dev_mins=\$(( TOTAL_DEV_SECS / 60 ))
  local dev_secs=\$(( TOTAL_DEV_SECS % 60 ))
  local rev_mins=\$(( TOTAL_REVIEW_SECS / 60 ))
  local rev_secs=\$(( TOTAL_REVIEW_SECS % 60 ))
  local other_secs=\$(( total_elapsed - TOTAL_DEV_SECS - TOTAL_REVIEW_SECS ))
  local other_mins=\$(( other_secs / 60 ))
  other_secs=\$(( other_secs % 60 ))

  local final_tokens="\$(get_total_tokens "\$MESSAGES_DIR")"

  echo ""
  echo "=============================================="
  echo "  RUN SUMMARY"
  echo "=============================================="
  echo ""
  printf "  %-22s %dm %02ds\n" "Total elapsed:" "\$total_mins" "\$total_secs"
  printf "  %-22s %dm %02ds\n" "  Development:" "\$dev_mins" "\$dev_secs"
  printf "  %-22s %dm %02ds\n" "  Review:" "\$rev_mins" "\$rev_secs"
  printf "  %-22s %dm %02ds\n" "  Overhead:" "\$other_mins" "\$other_secs"
  echo ""
  printf "  %-22s %s / %s\n" "Rounds:" "\$CURRENT_ROUND" "\$CFG_MAX_ROUNDS"
  printf "  %-22s %s\n" "Final verdict:" "\$VERDICT"
  if [[ -n "\$FIRST_ROUND_VERDICT" ]]; then
    printf "  %-22s %s\n" "First-round verdict:" "\$FIRST_ROUND_VERDICT"
  fi
  printf "  %-22s %s\n" "Tokens consumed:" "\$final_tokens"
  echo ""

  # Review score if available
  if [[ -f "\$MESSAGES_DIR/reviewer-feedback.md" ]]; then
    local score="\$(grep -o 'Score: [0-9]*/10' "\$MESSAGES_DIR/reviewer-feedback.md" | tail -1)"
    [[ -n "\$score" ]] && printf "  %-22s %s\n" "Review score:" "\$score"

    local critical=\$(grep -c '^\- \[' "\$MESSAGES_DIR/reviewer-feedback.md" 2>/dev/null || true)
    local findings=""
    for sev in CRITICAL HIGH MEDIUM LOW; do
      local count=\$(sed -n "/^### \$sev/,/^### /p" "\$MESSAGES_DIR/reviewer-feedback.md" 2>/dev/null | grep -c '^\- ' || true)
      [[ "\$count" -gt 0 ]] 2>/dev/null && findings+="\$sev:\$count "
    done
    [[ -n "\$findings" ]] && printf "  %-22s %s\n" "Findings:" "\$findings"
  fi

  # Git diff stats
  local diff_stat="\$(cd "\$REPO_DIR" && git diff --stat HEAD 2>/dev/null)"
  if [[ -n "\$diff_stat" ]]; then
    local files_changed="\$(echo "\$diff_stat" | tail -1 | grep -o '[0-9]* file' | grep -o '[0-9]*')"
    local insertions="\$(echo "\$diff_stat" | tail -1 | grep -o '[0-9]* insertion' | grep -o '[0-9]*')"
    local deletions="\$(echo "\$diff_stat" | tail -1 | grep -o '[0-9]* deletion' | grep -o '[0-9]*')"
    echo ""
    printf "  %-22s %s file(s)\n" "Files changed:" "\${files_changed:-0}"
    printf "  %-22s +%s / -%s\n" "Lines:" "\${insertions:-0}" "\${deletions:-0}"
  fi
  echo ""
}

echo "  Press ESC or Ctrl+C to abort."
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

    echo ""
    echo "=== Planning Phase — Decomposing spec into chunks ==="

    bash "\$MESSAGES_DIR/_run-claude.sh" "\$planner_prompt_file" "\$MESSAGES_DIR/planner.log" \
      "\$MESSAGES_DIR/costs.log" "\$MESSAGES_DIR/tokens.log" \
      "\$CFG_PLANNER_TOOLS" "\$REPO_DIR" "\$CFG_PLANNER_MODEL" "\$CFG_PLANNER_TIMEOUT"

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

    DEV_PIDS=()
    DEV_PHASE_START=\$SECONDS
    rm -f "\$MESSAGES_DIR"/dev-*-status.json
    for ((i = 1; i <= CFG_DEV_AGENTS; i++)); do
      rendered_prompt="\$(render_prompt "\$PROMPTS_DIR/dev-agent.md" \
        "STANDARDS_FILE=\$CFG_STANDARDS_FILE" \
        "WATCH_PATTERNS=\$WATCH_PATTERNS_STR" \
        "AGENT_ID=\$i" \
        "ROUND=\$CURRENT_ROUND" \
        "DEV_SKILLS=$DEV_SKILLS_LIST")"

      prompt_file="\$MESSAGES_DIR/dev-\${i}-prompt-r\${CURRENT_ROUND}.md"
      echo "\$rendered_prompt" > "\$prompt_file"

      update_agent_status "\$MESSAGES_DIR" "dev-\$i" "implementing"

      echo ""
      if [[ "\$CFG_CHUNKING_ENABLED" = "true" ]]; then
        echo "=== Chunk \$CURRENT_CHUNK — Round \$CURRENT_ROUND / \$CFG_MAX_ROUNDS — Dev \$i ==="
      else
        echo "=== Round \$CURRENT_ROUND / \$CFG_MAX_ROUNDS — Dev \$i ==="
      fi

      : > "\$MESSAGES_DIR/dev-\${i}-r\${CURRENT_ROUND}.log"
      bash "\$MESSAGES_DIR/_run-claude.sh" "\$prompt_file" \
        "\$MESSAGES_DIR/dev-\${i}-r\${CURRENT_ROUND}.log" \
        "\$MESSAGES_DIR/costs.log" "\$MESSAGES_DIR/tokens.log" \
        "\$CFG_DEV_TOOLS" "\$REPO_DIR" "\$CFG_DEV_MODEL" "\$CFG_AGENT_TIMEOUT" "\$CFG_DEV_FALLBACK_MODEL" &
      DEV_PIDS+=(\$!)
    done

    wait_with_timer "Dev agent(s) working" "check_dev_status '\$MESSAGES_DIR' '\$CFG_DEV_AGENTS'" "\$MESSAGES_DIR/dev-*-r\${CURRENT_ROUND}.log"

    for pid in "\${DEV_PIDS[@]}"; do
      wait "\$pid" 2>/dev/null || true
    done

    for ((i = 1; i <= CFG_DEV_AGENTS; i++)); do
      update_agent_status "\$MESSAGES_DIR" "dev-\$i" "done"
    done

    TOTAL_DEV_SECS=\$((TOTAL_DEV_SECS + SECONDS - DEV_PHASE_START))
    RUNNING_TOKENS="\$(get_total_tokens "\$MESSAGES_DIR")"
    echo "  Dev complete. Tokens so far: \$RUNNING_TOKENS"

    # Show modified files
    changed_files="\$(cd "\$REPO_DIR" && git diff --name-only HEAD 2>/dev/null)"
    if [[ -n "\$changed_files" ]]; then
      file_count=\$(echo "\$changed_files" | wc -l | tr -d ' ')
      echo "  Modified files (\$file_count):"
      echo "\$changed_files" | sed 's/^/    /'
    fi

    if ! check_app_health; then
      echo "  App failure detected after dev round \$CURRENT_ROUND."
      tail -5 "\$MESSAGES_DIR/app-output.log" 2>/dev/null | sed 's/^/    /'
    fi

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

      rm -f "\$MESSAGES_DIR/reviewer-feedback.md"
      REVIEW_PHASE_START=\$SECONDS

      reviewer_prompt="\$(render_prompt "\$PROMPTS_DIR/reviewer-agent.md" \
        "STANDARDS_FILE=\$CFG_STANDARDS_FILE" \
        "REVIEWER_SKILLS=${CFG_REVIEWER_SKILLS[*]}" \
        "SEVERITY_GATE=\$CFG_SEVERITY_GATE" \
        "BASE_BRANCH=main" \
        "ROUND=\$CURRENT_ROUND" \
        "SKILLS_LIST=\$SKILLS_LIST")"

      reviewer_prompt_file="\$MESSAGES_DIR/reviewer-prompt-r\${CURRENT_ROUND}.md"
      echo "\$reviewer_prompt" > "\$reviewer_prompt_file"

      if [[ "\$CFG_CHUNKING_ENABLED" = "true" ]]; then
        echo "=== Chunk \$CURRENT_CHUNK — Round \$CURRENT_ROUND / \$CFG_MAX_ROUNDS — Review ==="
      else
        echo "=== Round \$CURRENT_ROUND / \$CFG_MAX_ROUNDS — Review ==="
      fi

      : > "\$MESSAGES_DIR/reviewer-r\${CURRENT_ROUND}.log"
      bash "\$MESSAGES_DIR/_run-claude.sh" "\$reviewer_prompt_file" \
        "\$MESSAGES_DIR/reviewer-r\${CURRENT_ROUND}.log" \
        "\$MESSAGES_DIR/costs.log" "\$MESSAGES_DIR/tokens.log" \
        "\$CFG_REVIEWER_TOOLS" "\$REPO_DIR" "\$CFG_REVIEWER_MODEL" \
        "\$CFG_AGENT_TIMEOUT" "\$CFG_REVIEWER_FALLBACK_MODEL" &
      REVIEWER_PID=\$!

      wait_with_timer "Reviewer working" '[[ "\$(get_review_verdict "\$MESSAGES_DIR")" != "pending" ]] || ! kill -0 "\$REVIEWER_PID" 2>/dev/null' "\$MESSAGES_DIR/reviewer-r\${CURRENT_ROUND}.log"

      wait "\$REVIEWER_PID" 2>/dev/null || true

      VERDICT="\$(get_review_verdict "\$MESSAGES_DIR")"
      TOTAL_REVIEW_SECS=\$((TOTAL_REVIEW_SECS + SECONDS - REVIEW_PHASE_START))
      update_agent_status "\$MESSAGES_DIR" "reviewer" "done"

      [[ -z "\$FIRST_ROUND_VERDICT" ]] && FIRST_ROUND_VERDICT="\$VERDICT"

      RUNNING_TOKENS="\$(get_total_tokens "\$MESSAGES_DIR")"
      echo "  Verdict: \$VERDICT | Tokens so far: \$RUNNING_TOKENS"

      print_agent_summary "\$MESSAGES_DIR/reviewer-r\${CURRENT_ROUND}.log" "reviewer output"

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
    (cd "\$REPO_DIR" && git add -A -- . ':!.specify' && git commit -m 'wip: address review feedback') || true

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
      (cd "\$REPO_DIR" && git add -A -- . ':!.specify' && git commit -m "feat(chunk-\${CURRENT_CHUNK}): \${CHUNK_TITLE}") || true
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

  print_run_summary

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

    print_run_summary

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
    print_run_summary

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
      echo "  Proposed PR:     spex: \$FEATURE_NAME"
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
        (cd "\$REPO_DIR" && git add -A -- . ':!.specify' && git commit -m "feat: \${FEATURE_NAME}") || true
      fi

      if [[ "\$CFG_PHASE_PR" = "true" ]]; then
        PR_BODY="## What\n\n"
        PR_BODY+="Automated implementation of feature spec: \\\`\$FEATURE_NAME\\\`\n\n"
        PR_BODY+="Source: \\\`\$SPEC_FILE\\\`\n\n"
        if [[ -f "\$MESSAGES_DIR/reviewer-feedback.md" ]]; then
          PR_BODY+="### Changes\n\n\$(grep -A 100 '## Summary' "\$MESSAGES_DIR/reviewer-feedback.md" | head -5)\n\n"
        fi
        PR_BODY+="## Why\n\n"
        PR_BODY+="Feature requested via spex spec. Implementation validated through \$CURRENT_ROUND round(s) of automated code review.\n\n"
        PR_BODY+="## Expected Result / Proof\n\n"
        PR_BODY+="- Review rounds: \$CURRENT_ROUND / \$CFG_MAX_ROUNDS\n"
        PR_BODY+="- Final verdict: **\$VERDICT**\n"
        if [[ -f "\$MESSAGES_DIR/reviewer-feedback.md" ]]; then
          SCORE="\$(grep -o 'Score: [0-9]*/10' "\$MESSAGES_DIR/reviewer-feedback.md" | tail -1)"
          [[ -n "\$SCORE" ]] && PR_BODY+="- Reviewer score: **\$SCORE**\n"
          PR_BODY+="\n<details><summary>Full review</summary>\n\n\$(cat "\$MESSAGES_DIR/reviewer-feedback.md")\n\n</details>\n"
        fi

        (cd "\$REPO_DIR" && gh pr create --title "spex: \$FEATURE_NAME" --body "\$(echo -e "\$PR_BODY")") || true
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
      echo "    gh pr create --title 'spex: \$FEATURE_NAME'"
    fi
  fi
fi
ORCHEOF

chmod +x "$ORCHESTRATOR_SCRIPT"

# --- Run orchestrator inline ---
bash "$ORCHESTRATOR_SCRIPT" 2>&1 | tee "$MESSAGES_DIR/orchestrator.log"

# Cleanup app runner
if [[ -n "$APP_RUNNER_PID" ]]; then
  kill "$APP_RUNNER_PID" 2>/dev/null || true
fi
