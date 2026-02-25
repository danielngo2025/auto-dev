#!/usr/bin/env bash
# Terminal tab management for spex.
# Opens new terminal tabs to display agent output.
# Usage: source lib/terminal.sh

set -euo pipefail

# Opens a new terminal tab with a title and command.
# Args: <title> <command>
open_tab() {
  local title="$1"
  local cmd="$2"

  if [[ "$(uname)" != "Darwin" ]]; then
    return 0
  fi

  if [[ "${TERM_PROGRAM:-}" = "iTerm.app" ]]; then
    osascript <<EOF 2>/dev/null || true
tell application "iTerm"
  tell current window
    create tab with default profile
    tell current session
      set name to "$title"
      write text "$cmd"
    end tell
  end tell
end tell
EOF
  else
    osascript <<EOF 2>/dev/null || true
tell application "Terminal"
  activate
  do script "$cmd"
end tell
EOF
  fi
}
