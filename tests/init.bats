#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  export AUTO_DEV_ROOT="$(pwd)"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "init creates .specify directory" {
  bash templates/init.sh "$TEST_DIR"
  [ -d "$TEST_DIR/.specify" ]
}

@test "init creates config.yaml from template" {
  bash templates/init.sh "$TEST_DIR"
  [ -f "$TEST_DIR/.specify/config.yaml" ]
  run yq '.workflow.max_rounds' "$TEST_DIR/.specify/config.yaml"
  [ "$output" = "3" ]
}

@test "init creates messages directory" {
  bash templates/init.sh "$TEST_DIR"
  [ -d "$TEST_DIR/.specify/messages" ]
}

@test "init creates prompts directory" {
  bash templates/init.sh "$TEST_DIR"
  [ -d "$TEST_DIR/.specify/prompts" ]
}

@test "init creates skills directory" {
  bash templates/init.sh "$TEST_DIR"
  [ -d "$TEST_DIR/.specify/skills" ]
}

@test "init does not overwrite existing config" {
  mkdir -p "$TEST_DIR/.specify"
  echo "existing" > "$TEST_DIR/.specify/config.yaml"
  bash templates/init.sh "$TEST_DIR"
  run cat "$TEST_DIR/.specify/config.yaml"
  [ "$output" = "existing" ]
}
