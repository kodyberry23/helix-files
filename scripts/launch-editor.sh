#!/usr/bin/env bash
# Launch helix as the editor pane on a per-zellij-session unix socket.
#
# Why per-session: helix's default socket path is the global
# /tmp/helix/helix.sock (helix-editor/helix PR #13896). If two zellij
# sessions are alive at once, both helix instances try to bind the same
# file - whoever started last wins, and the dispatcher in the other
# session quietly delivers commands to the wrong helix. The fix is to
# derive a session-scoped path from $ZELLIJ_SESSION_NAME and pass it via
# HELIX_SOCKET_PATH, which helix's listener honors. The matching
# dispatch-to-editor.sh / helix-send.sh derive the same path on the
# sender side, so messages always land in the same session.
#
# Pre-rming the file before bind handles the EADDRINUSE case after a
# crashed helix or a zellij session that didn't clean up.

set -euo pipefail

session=${ZELLIJ_SESSION_NAME:-default}
# Strip anything that's not safe (zellij sanitizes already, but defensive).
session=${session//[^A-Za-z0-9_-]/_}

base_dir=${XDG_RUNTIME_DIR:-/tmp}/helix
mkdir -p "$base_dir"
sock="$base_dir/${session}.sock"
rm -f "$sock"

export HELIX_SOCKET_PATH="$sock"
exec hx "$@"
