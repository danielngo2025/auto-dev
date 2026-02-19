#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  export ORIGINAL_PATH="$PATH"
  export PATH="$TEST_DIR/bin:$PATH"

  # Create a mock claude CLI that writes status files
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Mock claude CLI: simulate dev/reviewer behavior
MOCK
  chmod +x "$TEST_DIR/bin/claude"

  # Create mock gh CLI
  cat > "$TEST_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo "https://github.com/test/repo/pull/1"
MOCK
  chmod +x "$TEST_DIR/bin/gh"

  # Set up a fake repo with .auto-dev
  mkdir -p "$TEST_DIR/repo"
  cd "$TEST_DIR/repo"
  git init --quiet
  git commit --allow-empty -m "init" --quiet

  export OLDPWD_SAVE="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  bash "$OLDPWD_SAVE/templates/init.sh" "$TEST_DIR/repo"
  yq -i '.app_runner.command = ""' "$TEST_DIR/repo/.auto-dev/config.yaml"
  yq -i '.project.name = "integration-test"' "$TEST_DIR/repo/.auto-dev/config.yaml"

  echo "# Add user login" > "$TEST_DIR/repo/spec.md"
}

teardown() {
  export PATH="$ORIGINAL_PATH"
  tmux kill-session -t "auto-dev-integration-test" 2>/dev/null || true
  cd /
  rm -rf "$TEST_DIR"
}

@test "dry-run succeeds with valid config" {
  run bash "$OLDPWD_SAVE/auto-dev.sh" --spec "$TEST_DIR/repo/spec.md" --repo "$TEST_DIR/repo" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"integration-test"* ]]
  [[ "$output" == *"Dry run"* ]]
}

@test "dry-run shows correct spec and branch" {
  run bash "$OLDPWD_SAVE/auto-dev.sh" --spec "$TEST_DIR/repo/spec.md" --repo "$TEST_DIR/repo" --dry-run
  [[ "$output" == *"spec.md"* ]]
  [[ "$output" == *"auto-dev/"* ]]
}

@test "dry-run shows review skills from config" {
  run bash "$OLDPWD_SAVE/auto-dev.sh" --spec "$TEST_DIR/repo/spec.md" --repo "$TEST_DIR/repo" --dry-run
  [[ "$output" == *"code-review"* ]]
}

@test "init creates complete .auto-dev structure" {
  # Verify the init from setup created everything
  [ -f "$TEST_DIR/repo/.auto-dev/config.yaml" ]
  [ -d "$TEST_DIR/repo/.auto-dev/messages" ]
  [ -d "$TEST_DIR/repo/.auto-dev/prompts" ]
  [ -d "$TEST_DIR/repo/.auto-dev/skills" ]
  [ -f "$TEST_DIR/repo/.auto-dev/prompts/dev-agent.md" ]
  [ -f "$TEST_DIR/repo/.auto-dev/prompts/reviewer-agent.md" ]
  [ -f "$TEST_DIR/repo/.auto-dev/prompts/orchestrator.md" ]
}
