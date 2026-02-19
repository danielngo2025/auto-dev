#!/usr/bin/env bash
# Renders prompt templates by replacing {{PLACEHOLDER}} with values.
# Usage: source lib/prompt-renderer.sh && render_prompt template.md KEY=value ...

set -euo pipefail

render_prompt() {
  local template_file="$1"
  shift

  if [[ ! -f "$template_file" ]]; then
    echo "Error: template not found: $template_file" >&2
    return 1
  fi

  local content
  content="$(cat "$template_file")"

  for pair in "$@"; do
    local key="${pair%%=*}"
    local value="${pair#*=}"
    content="${content//\{\{${key}\}\}/${value}}"
  done

  echo "$content"
}

render_prompt_to_file() {
  local template_file="$1"
  local output_file="$2"
  shift 2

  render_prompt "$template_file" "$@" > "$output_file"
}
