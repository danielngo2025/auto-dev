#!/usr/bin/env bash
# Creates and manages tmux sessions for auto-dev workflow.
# Usage: source lib/tmux-setup.sh

set -euo pipefail

# Initialize the global associative array for pane role mapping.
# Using declare -gA ensures the variable is global even when sourced
# inside a function (e.g., bats setup()).
declare -gA PANE_MAP=()

create_session() {
  local session_name="$1"
  local dev_agent_count="$2"

  # Reset the pane map for a fresh session.
  PANE_MAP=()

  # Create session with first window (summary pane).
  tmux new-session -d -s "$session_name" -x 200 -y 50

  local summary_pane="${session_name}:0.0"

  # Split horizontally to create the app-runner pane (right side).
  tmux split-window -h -t "$summary_pane"

  # Split the left pane (summary) vertically to create the reviewer pane below it.
  tmux split-window -v -t "$summary_pane"

  # Split the right pane (app-runner) vertically to create the dev-1 pane below it.
  tmux split-window -v -t "${session_name}:0.1"

  # Add extra dev agent panes (dev-2, dev-3, etc.).
  local current_pane_count
  current_pane_count="$(tmux list-panes -t "${session_name}:0" | wc -l | tr -d ' ')"

  local i
  for ((i = 2; i <= dev_agent_count; i++)); do
    local last_index=$((current_pane_count - 1))
    tmux split-window -v -t "${session_name}:0.${last_index}"
    current_pane_count=$((current_pane_count + 1))
  done

  # Rebalance the layout so all panes are evenly sized.
  tmux select-layout -t "${session_name}:0" tiled

  # Assign roles to pane indices after layout is finalized.
  # Order: summary(0), app-runner(1), reviewer(2), dev-1(3), dev-2(4), ...
  PANE_MAP["summary"]="${session_name}:0.0"
  PANE_MAP["app-runner"]="${session_name}:0.1"
  PANE_MAP["reviewer"]="${session_name}:0.2"

  for ((i = 1; i <= dev_agent_count; i++)); do
    local pane_index=$((i + 2))
    PANE_MAP["dev-${i}"]="${session_name}:0.${pane_index}"
  done
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
