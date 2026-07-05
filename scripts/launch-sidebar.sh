#!/usr/bin/env bash
# Launch treelix as the persistent sidebar pane (the file tree), on a
# per-zellij-session unix socket used for the editor->sidebar reveal.
#
# treelix listens on $TREELIX_SOCKET_PATH so helix's `A-r` can ask it to
# reveal the current buffer (scripts/dispatch-to-sidebar.sh sends
# `treelix reveal <path>` to that socket). The path is derived per session,
# mirroring scripts/launch-editor.sh's helix-socket derivation, so two live
# zellij sessions never deliver reveals to each other's sidebar.
#
# Pre-rming the socket handles the EADDRINUSE case after a crashed treelix
# or a zellij session that didn't clean up (treelix also clears it on bind).

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

sock="$(treelix_socket_path)"
mkdir -p "$(dirname "$sock")"
rm -f "$sock"

# Resolve treelix via PATH or ~/.cargo/bin. zellij panes can spawn with a
# minimal PATH (e.g. before .zshrc has prepended ~/.cargo/bin), so don't rely
# on a bare `treelix` being found.
if ! bin=$(treelix_bin); then
	err "treelix is not installed (looked on PATH and in ~/.cargo/bin)"
	echo >&2
	echo "  Install it with:  $HOME/projects/helix-files/scripts/setup.sh" >&2
	echo "  Then close this pane and re-open the session." >&2
	echo >&2
	# Keep the pane alive as a usable shell rather than dying instantly.
	exec "${SHELL:-/bin/sh}"
fi

export TREELIX_SOCKET_PATH="$sock"
# Root the tree at the session's working directory (the project dir).
exec "$bin" --root "$PWD"
