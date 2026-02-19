#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  export MESSAGES_DIR="$TEST_DIR/messages"
  mkdir -p "$MESSAGES_DIR"
  source lib/summary-watcher.sh
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "render_dashboard outputs dashboard when summary.json exists" {
  cat > "$MESSAGES_DIR/summary.json" <<'EOF'
{
  "spec": "docs/specs/add-auth.md",
  "branch": "auto-dev/add-auth",
  "round": 1,
  "max_rounds": 3,
  "agents": {
    "dev-1": {"status": "implementing", "files_changed": 5},
    "reviewer": {"status": "waiting"},
    "app": {"status": "running", "healthy": true}
  },
  "review": null,
  "phase": "development"
}
EOF
  run render_dashboard "$MESSAGES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"add-auth"* ]]
  [[ "$output" == *"Round"* ]]
  [[ "$output" == *"Dev-1"* ]]
}

@test "render_dashboard shows review findings when available" {
  cat > "$MESSAGES_DIR/summary.json" <<'EOF'
{
  "spec": "docs/specs/add-auth.md",
  "branch": "auto-dev/add-auth",
  "round": 2,
  "max_rounds": 3,
  "agents": {
    "dev-1": {"status": "fixing", "files_changed": 8},
    "reviewer": {"status": "done"},
    "app": {"status": "running", "healthy": true}
  },
  "review": {
    "critical": 0,
    "high": 1,
    "medium": 3,
    "low": 5,
    "verdict": "changes_requested"
  },
  "phase": "iteration"
}
EOF
  run render_dashboard "$MESSAGES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changes_requested"* ]]
}

@test "render_dashboard shows app output tail" {
  cat > "$MESSAGES_DIR/summary.json" <<'EOF'
{
  "spec": "test.md",
  "branch": "auto-dev/test",
  "round": 1,
  "max_rounds": 3,
  "agents": {},
  "review": null,
  "phase": "setup"
}
EOF
  echo "[INFO] Server started" > "$MESSAGES_DIR/app-output.log"
  echo "[INFO] Ready" >> "$MESSAGES_DIR/app-output.log"

  run render_dashboard "$MESSAGES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Server started"* ]]
}

@test "render_dashboard handles missing summary.json" {
  run render_dashboard "$MESSAGES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Waiting for workflow to start..."* ]]
}

@test "render_dashboard handles missing app-output.log" {
  cat > "$MESSAGES_DIR/summary.json" <<'EOF'
{
  "spec": "test.md",
  "branch": "auto-dev/test",
  "round": 1,
  "max_rounds": 3,
  "agents": {},
  "review": null,
  "phase": "setup"
}
EOF
  run render_dashboard "$MESSAGES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(no output yet)"* ]]
}

@test "render_dashboard capitalizes agent names" {
  cat > "$MESSAGES_DIR/summary.json" <<'EOF'
{
  "spec": "test.md",
  "branch": "auto-dev/test",
  "round": 1,
  "max_rounds": 3,
  "agents": {
    "dev-1": {"status": "implementing"},
    "reviewer": {"status": "waiting"}
  },
  "review": null,
  "phase": "development"
}
EOF
  run render_dashboard "$MESSAGES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dev-1"* ]]
  [[ "$output" == *"Reviewer"* ]]
}

@test "render_dashboard shows active icon for implementing agents" {
  cat > "$MESSAGES_DIR/summary.json" <<'EOF'
{
  "spec": "test.md",
  "branch": "auto-dev/test",
  "round": 1,
  "max_rounds": 3,
  "agents": {
    "dev-1": {"status": "implementing"}
  },
  "review": null,
  "phase": "development"
}
EOF
  run render_dashboard "$MESSAGES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"implementing"* ]]
}

@test "render_dashboard shows box drawing characters" {
  cat > "$MESSAGES_DIR/summary.json" <<'EOF'
{
  "spec": "test.md",
  "branch": "auto-dev/test",
  "round": 1,
  "max_rounds": 3,
  "agents": {},
  "review": null,
  "phase": "setup"
}
EOF
  run render_dashboard "$MESSAGES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"╔"* ]]
  [[ "$output" == *"╚"* ]]
}
