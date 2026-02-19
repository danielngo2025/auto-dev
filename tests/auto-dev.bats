#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  # Create a minimal fake repo with .auto-dev config
  mkdir -p "$TEST_DIR/.auto-dev/messages"
  mkdir -p "$TEST_DIR/.auto-dev/prompts"
  cp templates/config.yaml "$TEST_DIR/.auto-dev/config.yaml"
  yq -i '.app_runner.command = "echo server-started"' "$TEST_DIR/.auto-dev/config.yaml"
  yq -i '.project.name = "test-project"' "$TEST_DIR/.auto-dev/config.yaml"
  cp prompts/*.md "$TEST_DIR/.auto-dev/prompts/"
  echo "# Test Spec" > "$TEST_DIR/spec.md"
}

teardown() {
  tmux kill-session -t "auto-dev-test-project" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}

@test "auto-dev.sh shows usage without arguments" {
  run bash auto-dev.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "auto-dev.sh validates spec file exists" {
  run bash auto-dev.sh --spec /nonexistent/spec.md --repo "$TEST_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "auto-dev.sh validates .auto-dev/config.yaml exists" {
  rm "$TEST_DIR/.auto-dev/config.yaml"
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
