#!/usr/bin/env bash
# Open a file in the running helix instance.
#
# Called from broot via the `open` / `vsplit` verbs in broot/conf.hjson.
# Talks to helix's external-command Unix socket (helix-editor/helix
# PR #13896) by way of scripts/helix-send.sh.
#
# If the socket isn't there — either helix isn't running, or helix is
# stock and lacks the PR — fall back to spawning a fresh helix pane
# in zellij with the file pre-loaded.
#
# Usage: dispatch-to-editor.sh <open|vsplit> <path>

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

mode=${1:-}
target=${2:-}

if [[ -z $mode || -z $target ]]; then
	echo "dispatch-to-editor.sh: usage: $0 <open|vsplit> <path>" >&2
	exit 2
fi

case "$mode" in
	open|vsplit) ;;
	*) echo "dispatch-to-editor.sh: unknown mode '$mode' (expected: open | vsplit)" >&2; exit 2 ;;
esac

abs=$(abs_path "$target")

# Try the socket first. helix-send.sh exits non-zero (and prints to
# stderr) if the socket is missing, in which case we fall back to
# spawning a fresh helix pane with the file pre-loaded. vsplit has no
# meaning without an existing helix, so the fallback always opens.
send="$(dirname "${BASH_SOURCE[0]}")/helix-send.sh"
if "$send" ":$mode $abs" 2>/dev/null; then
	# Move zellij focus to the editor pane so the user lands in helix
	# after picking a file, instead of staying parked in broot.
	editor_id=$(resolve_pane_id_by_name editor)
	if [[ -n $editor_id ]]; then
		zellij action focus-pane-id "$editor_id"
	fi
else
	# Socket missing → spawn a fresh helix pane. new-pane focuses the
	# new pane by default, so focus lands correctly without a follow-up.
	zellij action new-pane --direction right --name editor -- hx "$abs"
fi
