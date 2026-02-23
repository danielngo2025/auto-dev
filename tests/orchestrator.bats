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

@test "init_workflow sets all fields correctly" {
  init_workflow "$MESSAGES_DIR" "docs/specs/feat.md" "auto-dev/feat" 5
  local spec branch round max_rounds
  spec="$(jq -r '.spec' "$MESSAGES_DIR/summary.json")"
  branch="$(jq -r '.branch' "$MESSAGES_DIR/summary.json")"
  round="$(jq -r '.round' "$MESSAGES_DIR/summary.json")"
  max_rounds="$(jq -r '.max_rounds' "$MESSAGES_DIR/summary.json")"
  [ "$spec" = "docs/specs/feat.md" ]
  [ "$branch" = "auto-dev/feat" ]
  [ "$round" = "1" ]
  [ "$max_rounds" = "5" ]
}

@test "init_workflow initializes empty agents object" {
  init_workflow "$MESSAGES_DIR" "docs/specs/feat.md" "auto-dev/feat" 3
  local agents
  agents="$(jq -r '.agents | length' "$MESSAGES_DIR/summary.json")"
  [ "$agents" = "0" ]
}

@test "init_workflow initializes null review" {
  init_workflow "$MESSAGES_DIR" "docs/specs/feat.md" "auto-dev/feat" 3
  local review
  review="$(jq -r '.review' "$MESSAGES_DIR/summary.json")"
  [ "$review" = "null" ]
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

@test "check_dev_status returns false when some devs done but not all" {
  echo '{"status":"done","round":1}' > "$MESSAGES_DIR/dev-1-status.json"
  echo '{"status":"in_progress","round":1}' > "$MESSAGES_DIR/dev-2-status.json"
  run check_dev_status "$MESSAGES_DIR" 2
  [ "$status" -ne 0 ]
}

@test "check_dev_status returns true when multiple devs all done" {
  echo '{"status":"done","round":1}' > "$MESSAGES_DIR/dev-1-status.json"
  echo '{"status":"done","round":1}' > "$MESSAGES_DIR/dev-2-status.json"
  run check_dev_status "$MESSAGES_DIR" 2
  [ "$status" -eq 0 ]
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

@test "get_review_verdict returns pending when file missing" {
  local verdict
  verdict="$(get_review_verdict "$MESSAGES_DIR")"
  [ "$verdict" = "pending" ]
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

@test "should_continue returns true at round 2 of 3 with changes_requested" {
  run should_continue "changes_requested" 2 3
  [ "$status" -eq 0 ]
}

@test "should_continue returns true for any non-approved verdict under max rounds" {
  run should_continue "revise" 1 3
  [ "$status" -eq 0 ]
}

@test "should_continue returns false for non-approved at max rounds" {
  run should_continue "revise" 3 3
  [ "$status" -ne 0 ]
}

@test "update_summary_phase updates phase in summary.json" {
  echo '{"phase":"setup","round":1}' > "$MESSAGES_DIR/summary.json"
  update_summary_phase "$MESSAGES_DIR" "development"
  local phase
  phase="$(jq -r '.phase' "$MESSAGES_DIR/summary.json")"
  [ "$phase" = "development" ]
}

@test "update_summary_phase preserves other fields" {
  echo '{"phase":"setup","round":1,"spec":"test.md"}' > "$MESSAGES_DIR/summary.json"
  update_summary_phase "$MESSAGES_DIR" "review"
  local round spec
  round="$(jq -r '.round' "$MESSAGES_DIR/summary.json")"
  spec="$(jq -r '.spec' "$MESSAGES_DIR/summary.json")"
  [ "$round" = "1" ]
  [ "$spec" = "test.md" ]
}

@test "increment_round updates round in summary.json" {
  echo '{"phase":"development","round":1}' > "$MESSAGES_DIR/summary.json"
  increment_round "$MESSAGES_DIR"
  local round
  round="$(jq -r '.round' "$MESSAGES_DIR/summary.json")"
  [ "$round" = "2" ]
}

@test "increment_round preserves phase" {
  echo '{"phase":"iteration","round":2}' > "$MESSAGES_DIR/summary.json"
  increment_round "$MESSAGES_DIR"
  local phase round
  phase="$(jq -r '.phase' "$MESSAGES_DIR/summary.json")"
  round="$(jq -r '.round' "$MESSAGES_DIR/summary.json")"
  [ "$phase" = "iteration" ]
  [ "$round" = "3" ]
}

@test "update_agent_status sets agent status in summary.json" {
  echo '{"phase":"development","round":1,"agents":{}}' > "$MESSAGES_DIR/summary.json"
  update_agent_status "$MESSAGES_DIR" "dev-1" "implementing"
  local agent_status
  agent_status="$(jq -r '.agents["dev-1"].status' "$MESSAGES_DIR/summary.json")"
  [ "$agent_status" = "implementing" ]
}

@test "update_agent_status updates existing agent" {
  echo '{"phase":"development","round":1,"agents":{"dev-1":{"status":"implementing"}}}' > "$MESSAGES_DIR/summary.json"
  update_agent_status "$MESSAGES_DIR" "dev-1" "done"
  local agent_status
  agent_status="$(jq -r '.agents["dev-1"].status' "$MESSAGES_DIR/summary.json")"
  [ "$agent_status" = "done" ]
}

@test "get_total_cost returns 0 when no costs file" {
  local cost
  cost="$(get_total_cost "$MESSAGES_DIR")"
  [ "$cost" = "0.0000" ]
}

@test "get_total_cost sums multiple entries" {
  printf "0.0100\n0.0250\n0.0050\n" > "$MESSAGES_DIR/costs.log"
  local cost
  cost="$(get_total_cost "$MESSAGES_DIR")"
  [ "$cost" = "0.0400" ]
}

@test "get_total_tokens returns 0 when no tokens file" {
  local tokens
  tokens="$(get_total_tokens "$MESSAGES_DIR")"
  [ "$tokens" = "0" ]
}

@test "get_total_tokens sums multiple entries" {
  printf "1500\n3200\n800\n" > "$MESSAGES_DIR/tokens.log"
  local tokens
  tokens="$(get_total_tokens "$MESSAGES_DIR")"
  [ "$tokens" = "5500" ]
}

@test "update_agent_status preserves other agents" {
  echo '{"phase":"development","round":1,"agents":{"dev-1":{"status":"done"},"reviewer":{"status":"waiting"}}}' > "$MESSAGES_DIR/summary.json"
  update_agent_status "$MESSAGES_DIR" "reviewer" "reviewing"
  local dev_status reviewer_status
  dev_status="$(jq -r '.agents["dev-1"].status' "$MESSAGES_DIR/summary.json")"
  reviewer_status="$(jq -r '.agents["reviewer"].status' "$MESSAGES_DIR/summary.json")"
  [ "$dev_status" = "done" ]
  [ "$reviewer_status" = "reviewing" ]
}
