#!/usr/bin/env bash

# tmux + helix sessionizer — create/attach a tmux session named after a
# chosen directory and open Helix in its first pane.
# Usage: sessionizer.sh [path]
#   - If a path arg is provided, use it.
#   - Otherwise, pick from PROJECT_ROOTS via fzf (combined with zoxide frecency).
#   - Handles switching when already inside tmux.

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Sessionizer is invoked as an alias (`hs`); a terse one-line error is more
# useful than the symbol-prefixed multi-step format.
err() { printf "sessionizer: %s\n" "$*" >&2; }

if ! has_cmd tmux; then
	err "tmux not found in PATH"
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
			zoxide_dirs=$(zoxide query -l 2>/dev/null | grep -E "^($HOME/projects)" || true)
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

# Sanitize: tmux session names cannot contain `.` or `:`; spaces are awkward.
session_name=$(basename "$selected" | tr ' .:' '___')

# ─── Create session if missing ────────────────────────────────────────────
# `new-session -ds` creates detached and is a no-op if it would clobber an
# existing session with the same name; we use has-session to gate it.
if ! tmux has-session -t="$session_name" 2>/dev/null; then
	# Open yazi as the pane's startup command. yazi loads near-instantly
	# (no LSPs, no tree-sitter), then defers to helix on file open via the
	# `block = true` opener in yazi/yazi.toml. Flow:
	#   1. tmux pane spawns directly into yazi (no zshrc preamble).
	#   2. Pick a file → yazi suspends to alternate screen, hx runs.
	#   3. `:q` in hx → yazi resumes.
	#   4. `q` in yazi → exec interactive shell takes over the pane.
	tmux new-session -ds "$session_name" -c "$selected" "yazi ; exec ${SHELL:-zsh} -i"
fi

# ─── Attach or switch ─────────────────────────────────────────────────────
if [[ -n ${TMUX:-} ]]; then
	exec tmux switch-client -t "$session_name"
else
	exec tmux attach -t "$session_name"
fi
