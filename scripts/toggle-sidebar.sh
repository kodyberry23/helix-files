#!/usr/bin/env bash
# EXPERIMENT: toggle sidebar visibility via close-pane / new-pane instead
# of `zellij action toggle-fullscreen` on the editor.
#
# Goal: isolate whether the 50%->18% flicker on sidebar reopen is caused
# by helix's repaint latency under toggle-fullscreen's pane restoration,
# or by zellij's pane sizing itself.
#
# - toggle-fullscreen path: editor stays alive, sidebar pane is hidden then
#   restored. helix gets SIGWINCH (full-width -> 82%) and its cached buffer
#   may briefly overlap the sidebar slot until it reflows.
# - close/spawn path: sidebar pane is destroyed and recreated. No hidden
#   pane is "restored"; the new pane gets its size at creation.
#
# If the flicker disappears with this script, the cause is helix repaint
# under fullscreen restoration. If it persists, it's a zellij sizing bug
# independent of toggle-fullscreen.
#
# Caveats: when respawning, zellij's CLI only documents --direction
# right|down. We spawn to the right of the focused editor pane, then
# move-pane left so the sidebar ends up on the left side as it does in
# the layout. broot state (cursor position, expansion) is lost on each
# close - this is a diagnostic toggle, not a polished UX.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

sidebar_id=$(resolve_pane_id_by_name sidebar)

if [[ -n $sidebar_id ]]; then
	zellij action close-pane --pane-id "$sidebar_id"
else
	zellij action new-pane --name sidebar --direction right -- "$SCRIPT_DIR/launch-sidebar.sh"
	# move-pane takes direction as a positional arg, not --direction.
	zellij action move-pane left
fi
