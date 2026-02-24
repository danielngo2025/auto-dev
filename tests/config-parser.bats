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

@test "parse_config loads fallback models" {
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_DEV_FALLBACK_MODEL" = "opus" ]
  [ "$CFG_REVIEWER_FALLBACK_MODEL" = "" ]
}

@test "parse_config loads phase toggles with defaults" {
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_PHASE_PLAN" = "true" ]
  [ "$CFG_PHASE_DEV" = "true" ]
  [ "$CFG_PHASE_REVIEW" = "true" ]
  [ "$CFG_PHASE_COMMIT" = "true" ]
  [ "$CFG_PHASE_PR" = "true" ]
}

@test "parse_config respects custom phase toggles" {
  yq -i '.workflow.phases.review = false' "$TEST_DIR/config.yaml"
  yq -i '.workflow.phases.pr = false' "$TEST_DIR/config.yaml"
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_PHASE_REVIEW" = "false" ]
  [ "$CFG_PHASE_PR" = "false" ]
  [ "$CFG_PHASE_DEV" = "true" ]
}

@test "parse_config defaults fallback models when missing" {
  yq -i 'del(.workflow.dev_fallback_model)' "$TEST_DIR/config.yaml"
  yq -i 'del(.workflow.reviewer_fallback_model)' "$TEST_DIR/config.yaml"
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_DEV_FALLBACK_MODEL" = "" ]
  [ "$CFG_REVIEWER_FALLBACK_MODEL" = "" ]
}

@test "parse_config defaults phases when missing" {
  yq -i 'del(.workflow.phases)' "$TEST_DIR/config.yaml"
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_PHASE_PLAN" = "true" ]
  [ "$CFG_PHASE_DEV" = "true" ]
  [ "$CFG_PHASE_REVIEW" = "true" ]
  [ "$CFG_PHASE_COMMIT" = "true" ]
  [ "$CFG_PHASE_PR" = "true" ]
}

@test "parse_config loads permission tiers from config" {
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_DEV_TOOLS" = "Edit,Write,Read,Bash,Grep,Glob" ]
  [ "$CFG_REVIEWER_TOOLS" = "Read,Write,Bash,Grep,Glob" ]
  [ "$CFG_PLANNER_TOOLS" = "Read,Write,Bash,Grep,Glob" ]
}

@test "parse_config respects custom permission tiers" {
  yq -i '.permissions.dev_tools = "Edit,Write,Read"' "$TEST_DIR/config.yaml"
  yq -i '.permissions.reviewer_tools = "Read,Grep,Glob"' "$TEST_DIR/config.yaml"
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_DEV_TOOLS" = "Edit,Write,Read" ]
  [ "$CFG_REVIEWER_TOOLS" = "Read,Grep,Glob" ]
}

@test "parse_config defaults permission tiers when missing" {
  yq -i 'del(.permissions)' "$TEST_DIR/config.yaml"
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_DEV_TOOLS" = "Edit,Write,Read,Bash,Grep,Glob" ]
  [ "$CFG_REVIEWER_TOOLS" = "Read,Write,Bash,Grep,Glob" ]
  [ "$CFG_PLANNER_TOOLS" = "Read,Write,Bash,Grep,Glob" ]
}

@test "parse_config loads context compaction defaults" {
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_COMPACTION_ENABLED" = "false" ]
  [ "$CFG_COMPACTION_MODEL" = "haiku" ]
  [ "$CFG_COMPACTION_MAX_CHARS" = "50000" ]
}

@test "parse_config respects custom compaction settings" {
  yq -i '.context_compaction.enabled = true' "$TEST_DIR/config.yaml"
  yq -i '.context_compaction.model = "sonnet"' "$TEST_DIR/config.yaml"
  yq -i '.context_compaction.max_log_chars = 25000' "$TEST_DIR/config.yaml"
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_COMPACTION_ENABLED" = "true" ]
  [ "$CFG_COMPACTION_MODEL" = "sonnet" ]
  [ "$CFG_COMPACTION_MAX_CHARS" = "25000" ]
}

@test "parse_config defaults compaction when missing" {
  yq -i 'del(.context_compaction)' "$TEST_DIR/config.yaml"
  parse_config "$TEST_DIR/config.yaml"
  [ "$CFG_COMPACTION_ENABLED" = "false" ]
  [ "$CFG_COMPACTION_MODEL" = "haiku" ]
  [ "$CFG_COMPACTION_MAX_CHARS" = "50000" ]
}

@test "parse_config fails on missing file" {
  run parse_config "/nonexistent/config.yaml"
  [ "$status" -ne 0 ]
}
