#!/usr/bin/env bash

# zellij + helix sessionizer - create/attach a zellij session named after
# a chosen directory. New sessions open the default layout at
# zellij/layouts/default.kdl (broot sidebar + persistent helix editor).
# Usage: sessionizer.sh [path]
#   - If a path arg is provided, use it.
#   - Otherwise, pick from PROJECT_ROOTS via fzf (combined with zoxide frecency).
#   - Handles switching when already inside zellij.

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Sessionizer is invoked as an alias (`hs`); a terse one-line error is more
# useful than the symbol-prefixed multi-step format.
err() { printf "sessionizer: %s\n" "$*" >&2; }

if ! has_cmd zellij; then
	err "zellij not found in PATH"
	exit 1
fi
if ! has_cmd hx; then
	err "hx (Helix) not found in PATH"
	exit 1
fi

PROJECT_ROOTS=("$HOME/projects")

# ─── Choose directory ─────────────────────────────────────────────────────
if [[ $# -eq 1 ]]; then
	selected=$(cd "$1" 2>/dev/null && pwd) || { err "invalid path: $1"; exit 1; }
else
	if has_cmd fzf && has_cmd fd; then
		project_dirs=$(fd -H -t d -d 1 . "${PROJECT_ROOTS[@]}" 2>/dev/null || true)

		if has_cmd zoxide; then
			zoxide_dirs=$(zoxide query -l 2>/dev/null | grep -F "$HOME/projects/" || true)
			candidates=$(printf '%s\n%s\n' "$project_dirs" "$zoxide_dirs" | awk 'NF && !seen[$0]++')
		else
			candidates=$project_dirs
		fi

		if [[ -n ${candidates:-} ]]; then
			selected=$(printf '%s\n' "$candidates" | fzf \
				--prompt="🚀 Helix session > " \
				--header="Project & frecent dirs (Ctrl-/ toggles preview)" \
				--preview='eza -la --color=always --icons --git {} 2>/dev/null || ls -la --color=always {} 2>/dev/null || tree -L 1 -C {} 2>/dev/null || echo "Preview unavailable"' \
				--preview-window=right:50%:wrap)
		fi
	fi
	# Fallback to first project root or cwd
	if [[ -z ${selected:-} ]]; then
		if [[ -d ${PROJECT_ROOTS[0]:-} ]]; then
			selected="${PROJECT_ROOTS[0]}"
		else
			selected=$(pwd)
		fi
	fi
fi

if [[ -z ${selected:-} ]]; then
	err "no selection"
	exit 1
fi

# Track frecency
if has_cmd zoxide; then
	zoxide add "$selected" 2>/dev/null || true
fi

# Sanitize: zellij session names disallow some shell-special chars; keep
# things alphanumeric-with-hyphens.
session_name=$(basename "$selected" | tr ' .:' '___')

# ─── Attach or create ─────────────────────────────────────────────────────
# `zellij attach -c` attaches if the session exists, creates it otherwise.
# When created fresh, default_layout (set in config.kdl to "default")
# spawns the broot sidebar + helix editor pair.
#
# Inside zellij: zellij has no in-place "switch-session" - refuse with a
# hint so the user detaches first. ZELLIJ env var is set inside sessions.
if [[ -n ${ZELLIJ:-} ]]; then
	err "already inside zellij; detach first (Ctrl-q) then re-run hs"
	exit 1
fi

cd "$selected"
exec zellij attach --create "$session_name"
