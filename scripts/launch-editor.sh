#!/usr/bin/env bash
# Launch helix as the editor pane on a per-zellij-session unix socket.
#
# Why per-session: helix's default socket path is the global
# /tmp/helix/helix.sock (helix-editor/helix PR #13896). If two zellij
# sessions are alive at once, both helix instances try to bind the same
# file - whoever started last wins, and the dispatcher in the other
# session quietly delivers commands to the wrong helix. The fix is to
# derive a session-scoped path (helix_socket_path in lib/common.sh) and
# pass it via HELIX_SOCKET_PATH, which helix's listener honors. The
# matching dispatch-to-editor.sh / helix-send.sh use the same helper on
# the sender side, so messages always land in the same session.
#
# Pre-rming the file before bind handles the EADDRINUSE case after a
# crashed helix or a zellij session that didn't clean up.

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

sock="$(helix_socket_path)"
mkdir -p "$(dirname "$sock")"
rm -f "$sock"
export HELIX_SOCKET_PATH="$sock"

# Sidebar follow (helix local patch): tell helix where the treelix reveal
# socket lives so it pushes `reveal-follow <path>` on every focused-buffer
# change — the sidebar then always shows the active file, no matter how it
# was opened (helix's own picker, :open, goto commands, ...). Unset/missing
# socket is harmless: helix ignores send failures, and a stock hx ignores
# the variable entirely.
export TREELIX_SOCKET_PATH="$(treelix_socket_path)"

exec hx "$@"
