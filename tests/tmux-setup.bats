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
  pane_count="$(tmux list-panes -t "${AUTO_DEV_SESSION}" -a | wc -l | tr -d ' ')"
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
