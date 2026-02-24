#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  # Create a minimal fake repo with .specify config
  mkdir -p "$TEST_DIR/.specify/messages"
  mkdir -p "$TEST_DIR/.specify/prompts"
  cp templates/config.yaml "$TEST_DIR/.specify/config.yaml"
  yq -i '.app_runner.command = "echo server-started"' "$TEST_DIR/.specify/config.yaml"
  yq -i '.project.name = "test-project"' "$TEST_DIR/.specify/config.yaml"
  cp prompts/*.md "$TEST_DIR/.specify/prompts/"
  echo "# Test Spec" > "$TEST_DIR/spec.md"
}

teardown() {
  tmux kill-session -t "auto-dev-test-project" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}

@test "auto-dev.sh shows help with --help" {
  run bash auto-dev.sh --help
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "auto-dev.sh errors when no specs found" {
  run bash auto-dev.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no spec"* ]]
}

@test "auto-dev.sh validates spec file exists" {
  run bash auto-dev.sh --spec /nonexistent/spec.md --repo "$TEST_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "auto-dev.sh validates .specify/config.yaml exists" {
  rm "$TEST_DIR/.specify/config.yaml"
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

@test "auto-dev.sh --dry-run shows phases" {
  run bash auto-dev.sh --spec "$TEST_DIR/spec.md" --repo "$TEST_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Phases:"* ]]
  [[ "$output" == *"plan=true"* ]]
  [[ "$output" == *"review=true"* ]]
}

@test "auto-dev.sh --dry-run shows fallback model when set" {
  yq -i '.workflow.dev_fallback_model = "opus"' "$TEST_DIR/.specify/config.yaml"
  run bash auto-dev.sh --spec "$TEST_DIR/spec.md" --repo "$TEST_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dev fallback:"* ]]
  [[ "$output" == *"opus"* ]]
}

@test "auto-dev.sh --dry-run shows dev and reviewer tools" {
  run bash auto-dev.sh --spec "$TEST_DIR/spec.md" --repo "$TEST_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dev tools:"* ]]
  [[ "$output" == *"Reviewer tools:"* ]]
}

@test "auto-dev.sh --dry-run reflects custom permission tiers" {
  yq -i '.permissions.reviewer_tools = "Read,Grep,Glob"' "$TEST_DIR/.specify/config.yaml"
  run bash auto-dev.sh --spec "$TEST_DIR/spec.md" --repo "$TEST_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read,Grep,Glob"* ]]
}
