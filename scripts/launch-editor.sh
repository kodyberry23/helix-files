#!/usr/bin/env bash
# Launch helix as the editor pane, after clearing any stale socket file
# from a previous session.
#
# Why this exists: helix-editor/helix PR #13896 tries `UnixListener::bind`
# on /tmp/helix/helix.sock at startup. If the file already exists (from a
# crashed prior helix or a zellij session that didn't clean up), bind
# fails with EADDRINUSE and helix silently runs without the command
# socket - the broot dispatcher (scripts/dispatch-to-editor.sh) then
# falls back to spawning fresh helix panes, which is what we just spent
# a lot of effort eliminating.
#
# Pre-rming the file before launch makes each new helix instance the
# primary socket target. Any other still-running helix retains its
# in-process listener but new clients now find this one.

set -euo pipefail

sock=${HELIX_SOCKET_PATH:-${XDG_RUNTIME_DIR:-/tmp}/helix/helix.sock}
rm -f "$sock"

exec hx "$@"
