#!/usr/bin/env bash
# Renders a TUI dashboard from summary.json written by auto-dev agents.
# Usage: source lib/summary-watcher.sh

set -euo pipefail

DASH_WIDTH=50

_draw_top() {
  printf '╔'
  printf '═%.0s' $(seq 1 $((DASH_WIDTH - 2)))
  printf '╗\n'
}

_draw_bottom() {
  printf '╚'
  printf '═%.0s' $(seq 1 $((DASH_WIDTH - 2)))
  printf '╝\n'
}

_draw_separator() {
  printf '╠'
  printf '═%.0s' $(seq 1 $((DASH_WIDTH - 2)))
  printf '╣\n'
}

_draw_line() {
  local text="$1"
  local content_width=$((DASH_WIDTH - 4))
  printf '║ %-'"${content_width}"'s ║\n' "$text"
}

_draw_empty() {
  _draw_line ""
}

_capitalize() {
  local input="$1"
  local result=""
  local IFS='-'
  local parts
  read -ra parts <<< "$input"
  local first=true
  for part in "${parts[@]}"; do
    if [[ "$first" == true ]]; then
      first=false
    else
      result="${result}-"
    fi
    result="${result}$(echo "${part:0:1}" | tr '[:lower:]' '[:upper:]')${part:1}"
  done
  echo "$result"
}

_agent_icon() {
  local agent_status="$1"
  case "$agent_status" in
    waiting|idle|done)
      echo "○"
      ;;
    *)
      echo "●"
      ;;
  esac
}

render_dashboard() {
  local messages_dir="$1"
  local summary_file="${messages_dir}/summary.json"
  local app_log="${messages_dir}/app-output.log"

  if [[ ! -f "$summary_file" ]]; then
    _draw_top
    _draw_line "Waiting for workflow to start..."
    _draw_bottom
    return 0
  fi

  local spec branch round max_rounds phase
  spec="$(jq -r '.spec' "$summary_file")"
  branch="$(jq -r '.branch' "$summary_file")"
  round="$(jq -r '.round' "$summary_file")"
  max_rounds="$(jq -r '.max_rounds' "$summary_file")"
  phase="$(jq -r '.phase' "$summary_file")"

  local feature_name
  feature_name="$(basename "$branch")"

  # Header
  _draw_top
  _draw_line "Feature: ${feature_name}"
  _draw_line "Spec:    ${spec}"
  _draw_line "Branch:  ${branch}"
  _draw_line "Round:   ${round} / ${max_rounds}"
  _draw_line "Phase:   ${phase}"

  # Agents section
  _draw_separator
  _draw_line "AGENTS"
  _draw_empty

  local agent_keys
  agent_keys="$(jq -r '.agents | keys[]' "$summary_file" 2>/dev/null || true)"

  if [[ -z "$agent_keys" ]]; then
    _draw_line "  (no agents)"
  else
    while IFS= read -r agent_key; do
      local agent_status icon capitalized
      agent_status="$(jq -r ".agents[\"${agent_key}\"].status // \"unknown\"" "$summary_file")"
      icon="$(_agent_icon "$agent_status")"
      capitalized="$(_capitalize "$agent_key")"
      _draw_line "  ${icon} ${capitalized}: ${agent_status}"
    done <<< "$agent_keys"
  fi

  # Review section
  _draw_separator
  _draw_line "REVIEW"
  _draw_empty

  local review_null
  review_null="$(jq '.review == null' "$summary_file")"

  if [[ "$review_null" == "true" ]]; then
    _draw_line "  No reviews yet"
  else
    local critical high medium low verdict
    critical="$(jq -r '.review.critical' "$summary_file")"
    high="$(jq -r '.review.high' "$summary_file")"
    medium="$(jq -r '.review.medium' "$summary_file")"
    low="$(jq -r '.review.low' "$summary_file")"
    verdict="$(jq -r '.review.verdict' "$summary_file")"
    _draw_line "  Critical: ${critical}  High: ${high}"
    _draw_line "  Medium:   ${medium}  Low:  ${low}"
    _draw_line "  Verdict:  ${verdict}"
  fi

  # App output section
  _draw_separator
  _draw_line "APP OUTPUT"
  _draw_empty

  if [[ -f "$app_log" ]]; then
    local lines
    lines="$(tail -3 "$app_log")"
    while IFS= read -r line; do
      _draw_line "  ${line}"
    done <<< "$lines"
  else
    _draw_line "  (no output yet)"
  fi

  _draw_bottom
}

watch_dashboard() {
  local messages_dir="$1"
  local interval="${2:-2}"

  while true; do
    clear
    render_dashboard "$messages_dir"
    sleep "$interval"
  done
}

# Standalone execution: bash lib/summary-watcher.sh watch <dir> [interval]
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    watch)
      shift
      watch_dashboard "$@"
      ;;
    *)
      echo "Usage: bash $(basename "$0") watch <messages_dir> [interval]" >&2
      exit 1
      ;;
  esac
fi
