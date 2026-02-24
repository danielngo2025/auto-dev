#!/usr/bin/env bash
# Parses .specify/config.yaml into shell variables.
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
  CFG_DEV_MODEL="$(yq '.workflow.dev_model // ""' "$config_file")"
  CFG_REVIEWER_MODEL="$(yq '.workflow.reviewer_model // ""' "$config_file")"
  CFG_AGENT_TIMEOUT="$(yq '.workflow.agent_timeout // 900' "$config_file")"
  CFG_DEV_FALLBACK_MODEL="$(yq '.workflow.dev_fallback_model // ""' "$config_file")"
  CFG_REVIEWER_FALLBACK_MODEL="$(yq '.workflow.reviewer_fallback_model // ""' "$config_file")"

  # Permissions
  CFG_DEV_TOOLS="$(yq '.permissions.dev_tools // "Edit,Write,Read,Bash,Grep,Glob"' "$config_file")"
  CFG_REVIEWER_TOOLS="$(yq '.permissions.reviewer_tools // "Read,Write,Bash,Grep,Glob"' "$config_file")"
  CFG_PLANNER_TOOLS="$(yq '.permissions.planner_tools // "Read,Write,Bash,Grep,Glob"' "$config_file")"

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

  # Skip specs (bash array)
  local skip_count
  skip_count="$(yq '.skip_specs | length // 0' "$config_file")"
  CFG_SKIP_SPECS=()
  for ((i = 0; i < skip_count; i++)); do
    CFG_SKIP_SPECS+=("$(yq ".skip_specs[$i]" "$config_file")")
  done

  # Chunking
  CFG_CHUNKING_ENABLED="$(yq '.chunking.enabled // false' "$config_file")"
  CFG_MAX_CHUNKS="$(yq '.chunking.max_chunks // 5' "$config_file")"
  CFG_PLANNER_MODEL="$(yq '.chunking.planner_model // "sonnet"' "$config_file")"
  CFG_PLANNER_TIMEOUT="$(yq '.chunking.planner_timeout // 600' "$config_file")"

  # Context compaction (can't use // for boolean false — yq treats it as falsy)
  local _val
  _val="$(yq '.context_compaction.enabled' "$config_file")"; CFG_COMPACTION_ENABLED="${_val/null/false}"
  CFG_COMPACTION_MODEL="$(yq '.context_compaction.model // "haiku"' "$config_file")"
  CFG_COMPACTION_MAX_CHARS="$(yq '.context_compaction.max_log_chars // 50000' "$config_file")"

  # Phases (can't use // for defaults since yq treats false as falsy)
  _val="$(yq '.workflow.phases.plan' "$config_file")"; CFG_PHASE_PLAN="${_val/null/true}"
  _val="$(yq '.workflow.phases.dev' "$config_file")"; CFG_PHASE_DEV="${_val/null/true}"
  _val="$(yq '.workflow.phases.review' "$config_file")"; CFG_PHASE_REVIEW="${_val/null/true}"
  _val="$(yq '.workflow.phases.commit' "$config_file")"; CFG_PHASE_COMMIT="${_val/null/true}"
  _val="$(yq '.workflow.phases.pr' "$config_file")"; CFG_PHASE_PR="${_val/null/true}"

  # Summary
  CFG_REFRESH_INTERVAL="$(yq '.summary.refresh_interval' "$config_file")"

  export CFG_PROJECT_NAME CFG_REPO_PATH CFG_MAX_ROUNDS CFG_DEV_AGENTS
  export CFG_SPEC_PATH CFG_APP_COMMAND CFG_HEALTH_CHECK
  export CFG_STANDARDS_FILE CFG_SEVERITY_GATE CFG_REFRESH_INTERVAL
  export CFG_DEV_MODEL CFG_REVIEWER_MODEL CFG_AGENT_TIMEOUT
  export CFG_DEV_FALLBACK_MODEL CFG_REVIEWER_FALLBACK_MODEL
  export CFG_DEV_TOOLS CFG_REVIEWER_TOOLS CFG_PLANNER_TOOLS
  export CFG_COMPACTION_ENABLED CFG_COMPACTION_MODEL CFG_COMPACTION_MAX_CHARS
  export CFG_PHASE_PLAN CFG_PHASE_DEV CFG_PHASE_REVIEW CFG_PHASE_COMMIT CFG_PHASE_PR
  export CFG_CHUNKING_ENABLED CFG_MAX_CHUNKS CFG_PLANNER_MODEL CFG_PLANNER_TIMEOUT
}
