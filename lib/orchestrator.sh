#!/usr/bin/env bash
# Core workflow engine for auto-dev: manages rounds, agent status, review
# verdicts, and phase transitions.
# Usage: source lib/orchestrator.sh

set -euo pipefail

# Creates summary.json with the initial workflow state.
# Args: <messages_dir> <spec_path> <branch_name> <max_rounds>
init_workflow() {
  local messages_dir="$1"
  local spec_path="$2"
  local branch_name="$3"
  local max_rounds="$4"

  jq -n \
    --arg spec "$spec_path" \
    --arg branch "$branch_name" \
    --argjson max_rounds "$max_rounds" \
    '{
      spec: $spec,
      branch: $branch,
      round: 1,
      max_rounds: $max_rounds,
      phase: "setup",
      agents: {},
      review: null
    }' > "${messages_dir}/summary.json"
}

# Checks whether all dev agents have reported "done" status.
# Returns 0 if all done, 1 otherwise.
# Args: <messages_dir> <dev_count>
check_dev_status() {
  local messages_dir="$1"
  local dev_count="$2"

  local i
  for ((i = 1; i <= dev_count; i++)); do
    local status_file="${messages_dir}/dev-${i}-status.json"

    if [[ ! -f "$status_file" ]]; then
      return 1
    fi

    local dev_status
    dev_status="$(jq -r '.status' "$status_file")"

    if [[ "$dev_status" != "done" ]]; then
      return 1
    fi
  done

  return 0
}

# Reads the reviewer verdict from reviewer-feedback.md.
# Extracts value from "## Verdict: <value>" line.
# Returns "pending" if the feedback file does not exist.
# Args: <messages_dir>
get_review_verdict() {
  local messages_dir="$1"
  local feedback_file="${messages_dir}/reviewer-feedback.md"

  if [[ ! -f "$feedback_file" ]]; then
    echo "pending"
    return 0
  fi

  local verdict
  verdict="$(grep '^## Verdict:' "$feedback_file" | sed 's/^## Verdict: //' | head -1)"

  if [[ -z "$verdict" ]]; then
    echo "pending"
    return 0
  fi

  echo "$verdict"
}

# Determines whether the workflow loop should continue.
# Returns 0 (true) if verdict is "changes_requested" AND current_round < max_rounds.
# Returns 1 (false) otherwise.
# Args: <verdict> <current_round> <max_rounds>
should_continue() {
  local verdict="$1"
  local current_round="$2"
  local max_rounds="$3"

  if [[ "$verdict" == "changes_requested" ]] && (( current_round < max_rounds )); then
    return 0
  fi

  return 1
}

# Updates the phase field in summary.json.
# Args: <messages_dir> <new_phase>
update_summary_phase() {
  local messages_dir="$1"
  local new_phase="$2"
  local summary_file="${messages_dir}/summary.json"

  local tmp_file
  tmp_file="$(mktemp)"

  jq --arg phase "$new_phase" '.phase = $phase' "$summary_file" > "$tmp_file"
  mv "$tmp_file" "$summary_file"
}

# Increments the round counter in summary.json.
# Args: <messages_dir>
increment_round() {
  local messages_dir="$1"
  local summary_file="${messages_dir}/summary.json"

  local tmp_file
  tmp_file="$(mktemp)"

  jq '.round += 1' "$summary_file" > "$tmp_file"
  mv "$tmp_file" "$summary_file"
}

# Updates an agent's status in the agents object of summary.json.
# Args: <messages_dir> <agent_name> <status>
update_agent_status() {
  local messages_dir="$1"
  local agent_name="$2"
  local agent_status="$3"
  local summary_file="${messages_dir}/summary.json"

  local tmp_file
  tmp_file="$(mktemp)"

  jq --arg name "$agent_name" --arg status "$agent_status" \
    '.agents[$name].status = $status' "$summary_file" > "$tmp_file"
  mv "$tmp_file" "$summary_file"
}
