#!/usr/bin/env bash
# Reveal a path in the "sidebar" zellij pane (treelix, running with
# $TREELIX_SOCKET_PATH via scripts/launch-sidebar.sh). Bound to `A-r` in
# helix/config.toml so the current buffer can be located in the tree with
# one keystroke.
#
# treelix's `reveal` subcommand connects to the per-session socket (derived
# the same way launch-sidebar.sh derived it) and tells the running instance
# to expand to and select <path>. It exits non-zero if no instance is
# listening, so we probe the socket first and fail loudly rather than hang.
#
# Usage: dispatch-to-sidebar.sh [--focus] <path>

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Move zellij focus into the sidebar pane. `|| true`: resolve_pane_id_by_name
# runs `zellij action list-panes`, which can exit non-zero; pipefail would
# otherwise abort the caller. A missing focus move is harmless; a hard abort
# isn't.
focus_sidebar() {
	local sidebar_id
	sidebar_id=$(resolve_pane_id_by_name sidebar) || true
	if [[ -n $sidebar_id ]]; then
		zellij action focus-pane-id "$sidebar_id"
	fi
}

# Parse args: an optional --focus flag (move zellij focus into the sidebar
# pane after revealing) plus the target path.
focus=0
target=
for arg in "$@"; do
	case "$arg" in
		--focus) focus=1 ;;
		*) target=$arg ;;
	esac
done
if [[ -z $target ]]; then
	# Nothing to reveal (e.g. a scratch/unnamed buffer). With --focus, still
	# move into the sidebar so the key reliably lands you there regardless.
	[[ $focus -eq 1 ]] && focus_sidebar
	exit 0
fi

abs=$(abs_path "$target")

# Match launch-sidebar.sh's per-session socket derivation exactly.
session=${ZELLIJ_SESSION_NAME:-default}
session=${session//[^A-Za-z0-9_-]/_}
sock_path="${XDG_RUNTIME_DIR:-/tmp}/treelix/${session}.sock"

if [[ ! -S $sock_path ]]; then
	echo "dispatch-to-sidebar.sh: no treelix socket at $sock_path (sidebar not running?)" >&2
	exit 1
fi

# Resolve treelix via PATH or ~/.cargo/bin (helix's :sh may run with a minimal
# PATH). treelix reveal reads TREELIX_SOCKET_PATH to find the instance.
if ! bin=$(treelix_bin); then
	echo "dispatch-to-sidebar.sh: treelix not found on PATH or in ~/.cargo/bin" >&2
	exit 1
fi
TREELIX_SOCKET_PATH="$sock_path" "$bin" reveal "$abs"

# With --focus, move zellij focus into the sidebar pane so this doubles as a
# "jump to the current file in treelix" action (mirrors dispatch-to-editor.sh
# focusing the editor pane after an open). The auto-follow reveals omit the
# flag, so they refresh the tree without stealing focus from helix.
[[ $focus -eq 1 ]] && focus_sidebar
