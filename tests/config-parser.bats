#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  cp templates/config.yaml "$TEST_DIR/config.yaml"
  yq -i '.project.name = "test-project"' "$TEST_DIR/config.yaml"
  yq -i '.app_runner.command = "echo hello"' "$TEST_DIR/config.yaml"
  source lib/config-parser.sh
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "parse_config loads project name" {
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_PROJECT_NAME" = "test-project" ]
}

@test "parse_config loads workflow settings" {
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_MAX_ROUNDS" = "3" ]
  [ "$CFG_DEV_AGENTS" = "1" ]
  [ "$CFG_BRANCH_PREFIX" = "auto-dev/" ]
}

@test "parse_config loads app runner settings" {
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_APP_COMMAND" = "echo hello" ]
}

@test "parse_config loads reviewer skills as array" {
  parse_config "$TEST_DIR/config.yaml"
  [ "${CFG_REVIEWER_SKILLS[0]}" = "code-review" ]
}

@test "parse_config loads severity gate" {
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_SEVERITY_GATE" = "high" ]
}

@test "parse_config loads watch patterns as array" {
  parse_config "$TEST_DIR/config.yaml"
  [ "${#CFG_WATCH_PATTERNS[@]}" -ge 1 ]
  [[ " ${CFG_WATCH_PATTERNS[*]} " == *"panic:"* ]]
}

@test "parse_config fails on missing file" {
  run parse_config "/nonexistent/config.yaml"
  [ "$status" -ne 0 ]
}
