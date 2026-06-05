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
# Usage: dispatch-to-sidebar.sh <path>

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

target=${1:-}
if [[ -z $target ]]; then
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

# treelix reveal reads TREELIX_SOCKET_PATH to find the instance.
TREELIX_SOCKET_PATH="$sock_path" treelix reveal "$abs"
