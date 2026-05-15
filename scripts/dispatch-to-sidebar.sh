#!/usr/bin/env bash
# Reveal a path in the named "sidebar" zellij pane (broot, running with
# --listen $name via scripts/launch-sidebar.sh). Bound to `A-r` in
# helix/config.toml so the current buffer can be located in the tree with
# one keystroke.
#
# IMPORTANT: broot's `--send <name>` takes a server NAME, not a path -
# broot computes /tmp/broot-server-<name>.sock internally. The name must
# match what launch-sidebar.sh passed to `--listen`. By convention both
# use $ZELLIJ_SESSION_NAME (sanitized identically).
#
# Usage: dispatch-to-sidebar.sh <path>

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

target=${1:-}
if [[ -z $target ]]; then
	exit 0
fi

abs=$(abs_path "$target")

# Match launch-sidebar.sh's sanitization exactly.
server=${BROOT_SERVER:-${ZELLIJ_SESSION_NAME:-default}}
server=${server//[^A-Za-z0-9_-]/_}

# Probe the socket file directly - if the sidebar isn't running, fail
# loudly rather than blocking on a `broot --send` that would hang.
sock_path="/tmp/broot-server-${server}.sock"
if [[ ! -S $sock_path ]]; then
	echo "dispatch-to-sidebar.sh: no broot socket at $sock_path (sidebar not running?)" >&2
	exit 1
fi

broot --send "$server" --cmd ":focus $abs"
