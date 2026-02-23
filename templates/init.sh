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

# Copy config template if not already present
if [[ ! -f "$TARGET_DIR/.auto-dev/config.yaml" ]]; then
  cp "$AUTO_DEV_ROOT/templates/config.yaml" "$TARGET_DIR/.auto-dev/config.yaml"
  echo "Created .auto-dev/config.yaml — edit this to configure your workflow."
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

echo "Done. Edit .auto-dev/config.yaml to configure your workflow."
