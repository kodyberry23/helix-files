#!/usr/bin/env bash

# zellij + helix sessionizer - create/attach a zellij session named after
# a chosen directory. New sessions open the default layout at
# zellij/layouts/default.kdl (treelix sidebar + persistent helix editor).
# Usage: sessionizer.sh [path | project-name]
#   - With an arg: resolve a path OR a bare project name (e.g. `hs helix-files`)
#     to a directory and open it directly, skipping the picker.
#   - Without an arg: pick from PROJECT_ROOTS via fzf (combined with zoxide
#     frecency).
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

# Resolve a single argument to a project directory, supporting both a path
# (absolute/relative) and a bare project NAME (e.g. `hs helix-files`). Prints
# the resolved absolute dir on success; returns non-zero if nothing matches.
# Resolution order: existing path → exact name under a project root → zoxide
# frecency → unique fuzzy substring match (interactive fzf only if ambiguous).
resolve_project() {
	local q="$1" root match dirs filtered count

	# 1. An actual path (absolute or relative to cwd).
	if [[ -d "$q" ]]; then
		(cd "$q" && pwd)
		return 0
	fi

	# 2. Exact directory name under a configured project root.
	for root in "${PROJECT_ROOTS[@]}"; do
		if [[ -d "$root/$q" ]]; then
			printf '%s\n' "$root/$q"
			return 0
		fi
	done

	# 3. zoxide's best frecent match (covers projects outside PROJECT_ROOTS).
	if has_cmd zoxide; then
		match=$(zoxide query "$q" 2>/dev/null || true)
		if [[ -n "$match" && -d "$match" ]]; then
			printf '%s\n' "$match"
			return 0
		fi
	fi

	# 4. Fuzzy: case-insensitive substring match among project dirs. Use it
	#    directly if exactly one matches; if several, fall back to fzf with the
	#    query pre-filled (auto-selecting on a single narrowed match).
	if has_cmd fd; then
		dirs=$(fd -H -t d -d 1 . "${PROJECT_ROOTS[@]}" 2>/dev/null | awk 'NF' || true)
		filtered=$(printf '%s\n' "$dirs" | grep -i -F -- "$q" || true)
		count=$(printf '%s' "$filtered" | grep -c . || true)
		if [[ "${count:-0}" -eq 1 ]]; then
			printf '%s\n' "$filtered"
			return 0
		fi
		if [[ "${count:-0}" -gt 1 ]] && has_cmd fzf; then
			printf '%s\n' "$filtered" | fzf --query="$q" --select-1 --exit-0 \
				--prompt="🚀 Helix session > "
			return $?
		fi
	fi

	return 1
}

# ─── Choose directory ─────────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
	selected=$(resolve_project "$1") || { err "no project matching: $1"; exit 1; }
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
# Inside zellij: zellij has no in-place "switch-session" - refuse with a
# hint so the user detaches first. ZELLIJ env var is set inside sessions.
if [[ -n ${ZELLIJ:-} ]]; then
	err "already inside zellij; detach first (Ctrl-q) then re-run hs"
	exit 1
fi

cd "$selected"

# Create the session detached first, THEN attach - never both in one shot.
#
# `zellij attach --create` couples three things into a single cold start:
# spawning the server, running the default layout (which launches the
# treelix sidebar + helix editor panes), and attaching this client. On a
# fresh first attach those overlap, and the client's terminal-capability
# handshake (DA/color-scheme queries) can race with pane startup. The reply
# lands after the client's parser has moved on, leaking as literal text
# (e.g. `^[[?997;2n`) and wedging the client - the server stays healthy but
# no keystroke registers, so the whole view looks frozen. zellij 0.44.3
# narrowed this window but did not close it for the ghostty cold-attach case.
#
# `--create-background` spawns the server and runs the layout with NO client
# attached, so the panes settle with nothing in the query loop. We then
# attach to the already-stable server - the ordinary re-attach path, which
# is exactly the "close the tab and reopen and it works" that dodged the
# race by hand. Existing sessions skip straight to attach (this is also the
# reattach path for `hs <name>`).
if ! zellij_session_exists "$session_name"; then
	zellij attach --create-background "$session_name"
	# --create-background returns immediately; wait for the session to
	# register so the attach below connects to the settled session instead
	# of racing its spawn (typically well under a second).
	for _ in $(seq 1 25); do
		zellij_session_exists "$session_name" && break
		sleep 0.2
	done
fi
# `--create` here is a safety net, not the normal path: after the block above
# the session already exists, so this just attaches (no spawn, no race). It
# only re-creates in the pathological case where the detached session never
# registered or died before we got here - preserving the old atomic
# create-or-attach guarantee instead of dead-ending on "session not found".
exec zellij attach --create "$session_name"
