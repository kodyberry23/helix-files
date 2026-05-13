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

		# Note: we intentionally do NOT pre-clear the terminal here. The
		# previous version ran `printf '\033[2J\033[H' > /dev/tty` to
		# pre-empt a brief which-key popup re-flash after yazi exits, but
		# the clear adds a visible blank frame between helix and yazi's
		# alt-screen — making `space e` feel noticeably laggy. Yazi's own
		# `\033[?1049h` switch and the `:redraw` later in the helix chain
		# handle the cleanup; any residual popup flash is sub-perceptual.

		# Where yazi opens to. Real path → its parent; otherwise cwd.
		local_start="$CURRENT"
		[[ -e "$CURRENT" ]] || local_start="."

		# Yazi's Ctrl-V keybind reads YAZI_PICK_MARKER and writes the
		# vsplit marker file. Export so yazi's child shell sees it.
		export YAZI_PICK_MARKER="$MARKER"

		# Lock yazi navigation to the project root via the stay-root
		# plugin (yazi/plugins/stay-root.yazi). Probe from the buffer's
		# parent dir first, falling back to PWD (helix's cwd — typically
		# the sessionizer's chosen project).
		ref_dir="$CURRENT"
		[[ -d "$ref_dir" ]] || ref_dir=$(dirname "$ref_dir")
		root=$(git -C "$ref_dir" rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
		export YAZI_LOCK_ROOT="$root"

		# Explicit terminal-brand hints so yazi doesn't probe the tty
		# under zellij — under zellij `/dev/tty` opens fail (see yazi's
		# ~/.local/state/yazi/yazi.log: "Failed to open /dev/tty, falling
		# back to stdin/stdout") and yazi falls through to chafa /
		# ueberzug detection. Setting these env vars short-circuits brand
		# detection in yazi-emulator/src/brand.rs to "ghostty" directly.
		# (No-op if already set; helix usually inherits them from zsh.)
		export TERM_PROGRAM="${TERM_PROGRAM:-ghostty}"
		export GHOSTTY_RESOURCES_DIR="${GHOSTTY_RESOURCES_DIR:-/Applications/Ghostty.app/Contents/Resources/ghostty}"

		yazi "$local_start" --chooser-file="$RESULT" </dev/tty >/dev/tty 2>/dev/null

		# If Ctrl-V was pressed, marker has "VSPLIT:<path>". Promote it
		# into the result file (overwriting any chooser-file contents)
		# so the read modes below have a single source of truth.
		[[ -s "$MARKER" ]] && cat "$MARKER" > "$RESULT"
		rm -f "$MARKER"

		# Yazi cleared the OSC 0 title on suspend (same behavior the
		# yazi.toml `edit` opener calls out and works around with its own
		# printf). Restore it so the zellij pane frame isn't blank for
		# the rest of the helix session. Title is the lock-root basename
		# — any picked file is guaranteed to live inside $root.
		printf '\033]0;hx %s\007' "${root##*/}" > /dev/tty
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
