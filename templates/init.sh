#!/usr/bin/env bash
# Scaffolds .auto-dev/ directory in a target repo.
# Usage: bash templates/init.sh /path/to/repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_DEV_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="${1:-.}"

echo "Initializing .auto-dev in: $TARGET_DIR"

mkdir -p "$TARGET_DIR/.auto-dev/messages"
mkdir -p "$TARGET_DIR/.auto-dev/prompts"
mkdir -p "$TARGET_DIR/.auto-dev/skills"
mkdir -p "$TARGET_DIR/.auto-dev/specs"

# --- Discover skills from .claude/skills/ and .cursor/rules/ ---
DISCOVERED_SKILLS=()

if [[ -d "$TARGET_DIR/.claude/skills" ]]; then
  for skill in "$TARGET_DIR/.claude/skills"/*/; do
    [[ ! -d "$skill" ]] && continue
    skill_name="$(basename "$skill")"
    if [[ ! -d "$TARGET_DIR/.auto-dev/skills/$skill_name" ]]; then
      cp -r "$skill" "$TARGET_DIR/.auto-dev/skills/$skill_name"
      echo "  Copied skill: $skill_name (from .claude/skills/)"
    fi
    DISCOVERED_SKILLS+=("$skill_name")
  done
fi

if [[ -d "$TARGET_DIR/.cursor/rules" ]]; then
  for rule in "$TARGET_DIR/.cursor/rules"/*; do
    [[ ! -f "$rule" ]] && continue
    rule_name="$(basename "$rule")"
    base_name="${rule_name%.*}"
    if [[ ! -f "$TARGET_DIR/.auto-dev/skills/$rule_name" ]]; then
      cp "$rule" "$TARGET_DIR/.auto-dev/skills/$rule_name"
      echo "  Copied rule: $rule_name (from .cursor/rules/)"
    fi
    DISCOVERED_SKILLS+=("$base_name")
  done
fi

# --- Detect standards file ---
STANDARDS_FILE="CLAUDE.md"
if [[ -f "$TARGET_DIR/CLAUDE.md" ]]; then
  STANDARDS_FILE="CLAUDE.md"
elif [[ -f "$TARGET_DIR/claude.md" ]]; then
  STANDARDS_FILE="claude.md"
elif [[ -f "$TARGET_DIR/.cursorrules" ]]; then
  STANDARDS_FILE=".cursorrules"
fi

# --- Detect project name ---
PROJECT_NAME="$(basename "$(cd "$TARGET_DIR" && pwd)")"

# --- Generate config.yaml ---
if [[ ! -f "$TARGET_DIR/.auto-dev/config.yaml" ]]; then
  # Build skills YAML list
  SKILLS_YAML=""
  if [[ ${#DISCOVERED_SKILLS[@]} -gt 0 ]]; then
    for s in "${DISCOVERED_SKILLS[@]}"; do
      SKILLS_YAML="${SKILLS_YAML}    - \"${s}\"\n"
    done
  else
    SKILLS_YAML="    - \"code-review\"\n"
  fi

  cat > "$TARGET_DIR/.auto-dev/config.yaml" << CFGEOF
project:
  name: "$PROJECT_NAME"
  repo_path: "."

workflow:
  max_rounds: 3
  dev_agents: 1
  branch_prefix: "auto-dev/"

spec:
  path: "docs/specs/"

app_runner:
  command: ""
  health_check: ""
  watch_patterns:
    - "panic:"
    - "FAIL"
    - "Error:"
    - "fatal"

reviewer:
  skills:
$(echo -en "$SKILLS_YAML")
  standards_file: "$STANDARDS_FILE"
  severity_gate: "high"

summary:
  refresh_interval: 5
CFGEOF

  echo "Created .auto-dev/config.yaml with ${#DISCOVERED_SKILLS[@]} skill(s) discovered."
else
  echo "Config already exists, skipping."
fi

# Copy prompt templates
for prompt in "$AUTO_DEV_ROOT/prompts"/*.md; do
  local_name="$(basename "$prompt")"
  if [[ ! -f "$TARGET_DIR/.auto-dev/prompts/$local_name" ]]; then
    cp "$prompt" "$TARGET_DIR/.auto-dev/prompts/$local_name"
  fi
done

echo ""
echo "Done. Skills discovered: ${DISCOVERED_SKILLS[*]:-none}"
echo "Edit .auto-dev/config.yaml to customize your workflow."
