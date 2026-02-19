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
