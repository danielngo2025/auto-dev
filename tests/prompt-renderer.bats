#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  source lib/prompt-renderer.sh
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "render_prompt replaces single placeholder" {
  echo "Hello {{NAME}}" > "$TEST_DIR/template.md"
  run render_prompt "$TEST_DIR/template.md" "NAME=World"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hello World"* ]]
  [[ "$output" != *"{{NAME}}"* ]]
}

@test "render_prompt replaces multiple placeholders" {
  echo "{{GREETING}} {{NAME}}, round {{ROUND}}" > "$TEST_DIR/template.md"
  run render_prompt "$TEST_DIR/template.md" "GREETING=Hello" "NAME=Dev" "ROUND=2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hello Dev, round 2"* ]]
}

@test "render_prompt leaves unknown placeholders as-is" {
  echo "{{KNOWN}} and {{UNKNOWN}}" > "$TEST_DIR/template.md"
  run render_prompt "$TEST_DIR/template.md" "KNOWN=replaced"
  [ "$status" -eq 0 ]
  [[ "$output" == *"replaced"* ]]
  [[ "$output" == *"{{UNKNOWN}}"* ]]
}

@test "render_prompt fails on missing template" {
  run render_prompt "/nonexistent/template.md" "NAME=test"
  [ "$status" -ne 0 ]
}

@test "render_prompt handles multiline templates" {
  printf "Line 1: {{A}}\nLine 2: {{B}}\nLine 3: {{A}}" > "$TEST_DIR/template.md"
  run render_prompt "$TEST_DIR/template.md" "A=alpha" "B=beta"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Line 1: alpha"* ]]
  [[ "$output" == *"Line 2: beta"* ]]
  [[ "$output" == *"Line 3: alpha"* ]]
}

@test "render_prompt handles values containing spaces" {
  echo "{{MSG}}" > "$TEST_DIR/template.md"
  run render_prompt "$TEST_DIR/template.md" "MSG=hello world"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello world"* ]]
}

@test "render_prompt handles empty value" {
  echo "before {{KEY}} after" > "$TEST_DIR/template.md"
  run render_prompt "$TEST_DIR/template.md" "KEY="
  [ "$status" -eq 0 ]
  [[ "$output" == *"before  after"* ]]
}

@test "render_prompt_to_file writes rendered output to file" {
  echo "Hello {{NAME}}" > "$TEST_DIR/template.md"
  run render_prompt_to_file "$TEST_DIR/template.md" "$TEST_DIR/output.md" "NAME=World"
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/output.md" ]
  result="$(cat "$TEST_DIR/output.md")"
  [[ "$result" == *"Hello World"* ]]
}
