#!/usr/bin/env bash
# Open a file in the running helix instance.
#
# Called from the treelix sidebar (on `<CR>` / `Ctrl-V` / `Ctrl-X`) to route a
# chosen file into the editor pane. Talks to helix's external-command Unix
# socket (helix-editor/helix PR #13896) by way of scripts/helix-send.sh.
#
# If the socket isn't there — the editor pane was closed, helix quit, or
# helix is stock and lacks the PR — fall back to spawning a replacement
# editor pane in zellij with the file pre-loaded, through launch-editor.sh
# so it is a real editor pane: the next pick routes into it instead of
# spawning another.
#
# Usage: dispatch-to-editor.sh <open|vsplit|hsplit> <path>

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/lib/common.sh"

# Per-session socket - the same path launch-editor.sh bound, or we'd
# dispatch into the wrong session's helix when multiple sessions are alive
# (single derivation: helix_socket_path in lib/common.sh).
export HELIX_SOCKET_PATH="$(helix_socket_path)"

mode=${1:-}
target=${2:-}

if [[ -z $mode || -z $target ]]; then
	echo "dispatch-to-editor.sh: usage: $0 <open|vsplit|hsplit> <path>" >&2
	exit 2
fi

case "$mode" in
	open|vsplit|hsplit) ;;
	*) echo "dispatch-to-editor.sh: unknown mode '$mode' (expected: open | vsplit | hsplit)" >&2; exit 2 ;;
esac

abs=$(abs_path "$target")

# Map the dispatch mode to the helix command.
#
# Under zellij we focus the editor pane after arming (below), so the window
# picker's labels are reachable: route through the `*-pick` commands (helix
# local-patch). If the file is already visible in a split, helix just jumps to
# it; with one split the command acts immediately (open in place / new split);
# with several, helix labels each split and the next keypress opens the file
# IN the chosen split. Without zellij we can't move focus to the editor pane,
# so a picker would be armed but unreachable — send the plain command instead.
[[ -n ${ZELLIJ:-} ]] && pick="-pick" || pick=""

# The path is SINGLE-quoted so a filename containing spaces parses as a single
# argument on the helix side. Single quotes — not double — keep the path
# literal: a double-quoted token goes through helix's `%`/`%sh{}` expansion,
# which would break filenames containing `%` and could even execute `%sh{...}`
# embedded in a maliciously-named file. Embedded single quotes are escaped by
# doubling them (helix command-line escaping).
esc=${abs//\'/\'\'}

case "$mode" in
	open)   helix_cmd=":open$pick '$esc'"   ;;
	vsplit) helix_cmd=":vsplit$pick '$esc'" ;;
	hsplit) helix_cmd=":hsplit$pick '$esc'" ;;
	*)      exit 2                          ;;
esac

# Try the socket first. helix-send.sh exits non-zero (and prints to
# stderr) if the socket is missing, in which case we fall back to
# spawning a fresh helix pane with the file pre-loaded. vsplit has no
# meaning without an existing helix, so the fallback always opens.
#
# Assumes the running helix understands `:open-pick`/`:vsplit-pick` (built from
# the local-patches branch). `nc -U` returns 0 once it connects+writes, so a
# stale helix that has the socket (PR #13896) but not the picker patch would
# show a transient "no such command" and we'd focus an editor with nothing
# opened. Both patches ship together, so this only happens if helix wasn't
# restarted after an update — restart the editor pane to fix it.
send="$script_dir/helix-send.sh"
if "$send" "$helix_cmd" 2>/dev/null; then
	# Move zellij focus to the editor pane so the user lands in helix
	# after picking a file, instead of staying parked in the sidebar.
	# `|| true`: list-panes (inside resolve_pane_id_by_name) can exit non-zero
	# and pipefail propagates it, which would abort this script under `set -e`
	# *after* the file already opened. Missing focus is harmless; a hard abort
	# isn't.
	editor_id=$(resolve_pane_id_by_name editor) || true
	if [[ -n $editor_id ]]; then
		zellij action focus-pane-id "$editor_id"
	fi
else
	# Socket missing → the editor pane is gone. Spawn a replacement THROUGH
	# launch-editor.sh, exactly as the layout does: a bare `hx` would bind
	# helix's default socket instead of this session's, so every later pick
	# would miss it and open a third pane, and it would get no
	# TREELIX_SOCKET_PATH, so the sidebar would neither follow it nor hear
	# its diagnostics. --name editor keeps the focus step above working,
	# --close-on-exit matches the layout pane, and new-pane focuses the new
	# pane by default. The path is absolute: the command runs in the pane,
	# not in this shell.
	zellij action new-pane --direction right --name editor --close-on-exit -- "$script_dir/launch-editor.sh" "$abs"
fi
