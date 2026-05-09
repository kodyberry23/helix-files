#!/usr/bin/env bash
# yazi-as-helix-picker. Single helix entrypoint (`space e`); the action
# (open vs. vsplit) is decided inside yazi:
#   Enter  → yazi writes path to chooser-file → wrapper emits path on
#            `open` mode  → :open <path>      ; `vsplit` mode emits empty
#                                              → :vsplit "" silent error
#   Ctrl-V → yazi keymap writes "VSPLIT:<path>" to YAZI_PICK_MARKER and
#            quits → wrapper emits stripped path on `vsplit` mode →
#            :vsplit <path>; `open` mode emits current path → :open is
#            no-op (helix.editor.open with already-open path returns
#            existing doc id)
#   q/Esc  → cancel; both modes emit a no-op fallback (`open` → current,
#            `vsplit` → empty).
#
# The helix keybind chain runs all three modes ("run", then "open", then
# "vsplit") with $PPID-keyed temp files so the wrapper's three calls share
# state. $PPID is helix's own PID — stable across helix's spawned shells.
#
# Usage:
#   yazi-pick.sh run    <current-buffer-path>   (blocking — runs yazi)
#   yazi-pick.sh open   <current-buffer-path>   (reads result, emits :open arg)
#   yazi-pick.sh vsplit <current-buffer-path>   (reads result, emits :vsplit arg)

set -uo pipefail

MODE="${1:-}"
CURRENT="${2:-.}"
RESULT="/tmp/helix-yazi-pick.$PPID"
MARKER="/tmp/helix-yazi-pick-vsplit.$PPID"

case "$MODE" in
	run)
		# Wipe stale state from a previous invocation in this helix.
		rm -f "$RESULT" "$MARKER"

		# Clear the main screen BEFORE yazi takes alt-screen — yazi's exit
		# restores main-screen pixels, which would otherwise still contain
		# helix's which-key popup until helix's :redraw (async) completes.
		printf '\033[2J\033[H' > /dev/tty

		# Where yazi opens to. Real path → its parent; otherwise cwd.
		local_start="$CURRENT"
		[[ -e "$CURRENT" ]] || local_start="."

		# Yazi's Ctrl-V keybind reads YAZI_PICK_MARKER and writes the
		# vsplit marker file. Export so yazi's child shell sees it.
		export YAZI_PICK_MARKER="$MARKER"
		yazi "$local_start" --chooser-file="$RESULT" </dev/tty >/dev/tty 2>/dev/null

		# If Ctrl-V was pressed, marker has "VSPLIT:<path>". Promote it
		# into the result file (overwriting any chooser-file contents)
		# so the read modes below have a single source of truth.
		[[ -s "$MARKER" ]] && cat "$MARKER" > "$RESULT"
		rm -f "$MARKER"
		;;

	open)
		# `:open <emitted>` runs whether we picked open, vsplit, or
		# canceled. Emit a path that's a no-op for non-open scenarios.
		if [[ -s "$RESULT" ]]; then
			line=$(<"$RESULT")
			if [[ "$line" == VSPLIT:* ]]; then
				# vsplit mode — re-target the already-open buffer (no-op)
				[[ -e "$CURRENT" ]] && printf '%s' "$CURRENT"
			else
				printf '%s' "$line"
			fi
		else
			# Cancel — re-target current buffer
			[[ -e "$CURRENT" ]] && printf '%s' "$CURRENT"
		fi
		;;

	vsplit)
		# `:vsplit <emitted>` runs in every chain. Emit the picked path
		# only when Ctrl-V was actually pressed; otherwise emit
		# `/dev/null` — a character device, metadata.is_file=false, so
		# helix's Document::open returns IrregularFile and the split is
		# skipped. (Empirically `:vsplit ""` can create an empty-buffer
		# split despite the source's IrregularFile branch — `/dev/null`
		# is the reliable sentinel.)
		line=""
		[[ -s "$RESULT" ]] && line=$(<"$RESULT")
		if [[ "$line" == VSPLIT:* ]]; then
			printf '%s' "${line#VSPLIT:}"
		else
			printf '/dev/null'
		fi
		;;

	*)
		echo "yazi-pick.sh: unknown mode '$MODE' (expected: run | open | vsplit)" >&2
		exit 2
		;;
esac
