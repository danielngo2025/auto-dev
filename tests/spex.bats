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
  rm -rf "$TEST_DIR"
}

@test "spex.sh shows help with --help" {
  run bash spex.sh --help
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "spex.sh errors when no specs found" {
  run bash spex.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no spec"* ]]
}

@test "spex.sh validates spec file exists" {
  run bash spex.sh --spec /nonexistent/spec.md --repo "$TEST_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "spex.sh validates .specify/config.yaml exists" {
  rm "$TEST_DIR/.specify/config.yaml"
  run bash spex.sh --spec "$TEST_DIR/spec.md" --repo "$TEST_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config"* ]]
}

@test "spex.sh --dry-run shows plan without executing" {
  run bash spex.sh --spec "$TEST_DIR/spec.md" --repo "$TEST_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-project"* ]]
  [[ "$output" == *"Dry run"* ]]
}

@test "spex.sh --dry-run shows phases" {
  run bash spex.sh --spec "$TEST_DIR/spec.md" --repo "$TEST_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Phases:"* ]]
  [[ "$output" == *"plan=true"* ]]
  [[ "$output" == *"review=true"* ]]
}

@test "spex.sh --dry-run shows fallback model when set" {
  yq -i '.workflow.dev_fallback_model = "opus"' "$TEST_DIR/.specify/config.yaml"
  run bash spex.sh --spec "$TEST_DIR/spec.md" --repo "$TEST_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dev fallback:"* ]]
  [[ "$output" == *"opus"* ]]
}

@test "spex.sh --dry-run shows dev and reviewer tools" {
  run bash spex.sh --spec "$TEST_DIR/spec.md" --repo "$TEST_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dev tools:"* ]]
  [[ "$output" == *"Reviewer tools:"* ]]
}

@test "spex.sh --dry-run reflects custom permission tiers" {
  yq -i '.permissions.reviewer_tools = "Read,Grep,Glob"' "$TEST_DIR/.specify/config.yaml"
  run bash spex.sh --spec "$TEST_DIR/spec.md" --repo "$TEST_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read,Grep,Glob"* ]]
}
