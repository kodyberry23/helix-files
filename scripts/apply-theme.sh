#!/usr/bin/env bash

# Apply the helix-files theme system: render every canonical theme in
# themes/*.toml through themes/templates/* into the per-app config files,
# point each app at the ACTIVE theme from ~/.config/helix-files.toml, and
# re-stamp the ~/.zshrc managed block (fzf / zsh-helix-mode / oh-my-posh
# colors bind there).
#
# What it writes, per theme <n> in themes/:
#   helix/themes/<n>.toml     (from templates/helix.toml.tmpl)
#   treelix/themes/<n>.toml   (from templates/treelix.toml.tmpl)
#   ghostty/themes/<n>        (from templates/ghostty.tmpl)
#   zellij/themes/<n>.kdl     (from templates/zellij.kdl.tmpl)
#   oh-my-posh/<n>.omp.json   (from templates/omp.json.tmpl)
# ...and, for the active theme + [transparency] settings:
#   pointer lines in helix/config.toml, treelix/config.toml,
#   zellij/config.kdl, ghostty/config (config-file + opacity + blur),
#   and the ~/.zshrc managed block via `setup.sh --only-zshrc`.
#
# All generated files are COMMITTED - rendering is deterministic, so drift
# (or a hand-edit to a generated file) shows up in `git status`.
#
# Usage:
#   scripts/apply-theme.sh                 # apply theme from user config
#   scripts/apply-theme.sh --set <name>    # switch theme, then apply
#   scripts/apply-theme.sh --dry-run | -n  # preview without changing anything
#   scripts/apply-theme.sh -h | --help     # usage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

REPO_ROOT="${HELIX_FILES:-$(cd "$SCRIPT_DIR/.." && pwd)}"
. "$SCRIPT_DIR/lib/theme.sh"

usage() {
	cat <<'USAGE'
Apply the helix-files theme everywhere (helix, treelix, ghostty, zellij,
oh-my-posh, ~/.zshrc block). The active theme and the transparency toggle
live in ~/.config/helix-files.toml.

Usage:
  scripts/apply-theme.sh              apply the configured theme
  scripts/apply-theme.sh --set <name> set theme in ~/.config/helix-files.toml,
                                      then apply (aliased as `hft <name>`)
  scripts/apply-theme.sh --dry-run    preview without changing anything
  scripts/apply-theme.sh -n           same as --dry-run
  scripts/apply-theme.sh -h | --help  this message
USAGE
}

# Inline parser (common.sh's parse_dry_run_args doesn't know --set).
DRY_RUN=false
SET_THEME=""
while (( $# )); do
	case "$1" in
		--dry-run|-n) DRY_RUN=true ;;
		--set)        shift; SET_THEME="${1:-}"
		              [[ -n $SET_THEME ]] || { err "--set needs a theme name"; exit 2; } ;;
		--set=*)      SET_THEME="${1#--set=}"
		              [[ -n $SET_THEME ]] || { err "--set needs a theme name"; exit 2; } ;;
		-h|--help)    usage; exit 0 ;;
		*)            err "unknown argument: $1"; exit 2 ;;
	esac
	shift
done

dry_run_banner "$DRY_RUN"

require_theme_file() {
	local name=$1
	if [[ ! -f "$THEMES_DIR/$name.toml" ]]; then
		err "unknown theme '$name' - available: $(list_themes | tr '\n' ' ')"
		exit 1
	fi
}

main() {
	ensure_user_config

	# --set rewrites the user config's theme line first, then applies. The
	# file can only be absent under --dry-run (ensure_user_config just
	# printed `would create`); don't grep a nonexistent file - preview the
	# write instead of crashing.
	if [[ -n $SET_THEME ]]; then
		require_theme_file "$SET_THEME"
		if [[ -f $THEME_USER_CONFIG ]]; then
			set_pointer_line "$THEME_USER_CONFIG" '^theme = "' "theme = \"$SET_THEME\""
		else
			would "set 'theme = \"$SET_THEME\"' in $THEME_USER_CONFIG"
		fi
	fi

	local theme
	theme="${SET_THEME:-$(active_theme)}"
	require_theme_file "$theme"

	local enabled opacity blur
	enabled=$(transparency_enabled)
	if [[ $enabled == "true" ]]; then
		opacity=$(transparency_opacity)
		blur=$(transparency_blur)
	else
		opacity="1.0"
		blur="0"
	fi

	# ─── Render every theme's per-app files ────────────────────────────────
	# All themes render on every apply (not just the active one) so ad-hoc
	# preview works: `:theme oh-lucy` in helix, `treelix --theme oh-lucy`, ...
	# Only the ACTIVE theme validates strictly - an invalid non-active theme
	# (e.g. a half-filled copy from the "Adding a theme" flow) is warned
	# about and skipped so it can never block switching to a good theme or
	# abort an update mid-run. A failed render of a valid theme still aborts
	# (set -e), which - together with require_theme_file above - is what
	# keeps treelix from silently falling back to its built-in theme on a
	# missing generated file.
	info "rendering themes: $(list_themes | tr '\n' ' ')"
	local f name
	for f in "$THEMES_DIR"/*.toml; do
		[[ -f $f ]] || { err "no themes found in $THEMES_DIR"; exit 1; }
		name=$(basename "$f" .toml)
		if ! theme_validate "$f"; then
			if [[ $name == "$theme" ]]; then
				err "active theme '$theme' is invalid - fix it (or 'hft <other>') and re-run"
				exit 1
			fi
			warn "skipping '$name' (invalid; the active theme is unaffected)"
			continue
		fi
		render_template "$THEME_TEMPLATES_DIR/helix.toml.tmpl"   "$f" "$REPO_ROOT/helix/themes/$name.toml"
		render_template "$THEME_TEMPLATES_DIR/treelix.toml.tmpl" "$f" "$REPO_ROOT/treelix/themes/$name.toml"
		render_template "$THEME_TEMPLATES_DIR/ghostty.tmpl"      "$f" "$REPO_ROOT/ghostty/themes/$name"
		render_template "$THEME_TEMPLATES_DIR/zellij.kdl.tmpl"   "$f" "$REPO_ROOT/zellij/themes/$name.kdl"
		render_template "$THEME_TEMPLATES_DIR/omp.json.tmpl"     "$f" "$REPO_ROOT/oh-my-posh/$name.omp.json"
		ok "rendered $name"
	done

	# ─── Point every app at the active theme ───────────────────────────────
	# Two passes over one pointer list: verify EVERY anchor matches before
	# rewriting anything, so one hand-edited config can't leave the apps
	# half-switched (helix repointed, ghostty not). Fields are |-separated;
	# none of the anchors or replacements can contain '|'.
	info "activating '$theme' (transparency: $enabled)"
	local pointers=(
		"$REPO_ROOT/helix/config.toml|^theme = \"|theme = \"$theme\""
		"$REPO_ROOT/treelix/config.toml|^theme = \"|theme = \"$theme\""
		"$REPO_ROOT/zellij/config.kdl|^theme \"|theme \"$theme\""
		"$REPO_ROOT/ghostty/config|^config-file = themes/|config-file = themes/$theme"
		"$REPO_ROOT/ghostty/config|^background-opacity = |background-opacity = $opacity"
		"$REPO_ROOT/ghostty/config|^background-blur = |background-blur = $blur"
	)
	local entry pfile rest anchor missing=""
	for entry in "${pointers[@]}"; do
		pfile=${entry%%|*}
		rest=${entry#*|}
		anchor=${rest%%|*}
		grep -qE "$anchor" "$pfile" \
			|| missing+="  ${pfile#"$REPO_ROOT"/}: $anchor"$'\n'
	done
	if [[ -n $missing ]]; then
		err "pointer anchor(s) not found (hand-edited?) - no pointers were changed:"
		printf '%s' "$missing" >&2
		exit 1
	fi
	for entry in "${pointers[@]}"; do
		pfile=${entry%%|*}
		rest=${entry#*|}
		anchor=${rest%%|*}
		set_pointer_line "$pfile" "$anchor" "${rest#*|}"
	done

	# ─── Re-stamp the ~/.zshrc managed block ───────────────────────────────
	# fzf colors, the ZHM cursor/style overrides, and the oh-my-posh config
	# path are interpolated into the block from the active theme at stamp
	# time (setup.sh sources lib/theme.sh for this).
	if $DRY_RUN; then
		bash "$SCRIPT_DIR/setup.sh" --only-zshrc --dry-run
	else
		bash "$SCRIPT_DIR/setup.sh" --only-zshrc
	fi

	if ! $DRY_RUN; then
		echo
		info "theme '$theme' applied - to see it everywhere:"
		echo "  ghostty:  super+b r reloads colors; opacity/blur changes need a FULL"
		echo "            ghostty restart (macOS won't repaint them on reload)"
		echo "  zellij:   picks up the theme pointer live (config.kdl is watched);"
		echo "            detach/reattach (Ctrl q, then hs) if chrome looks stale"
		echo "  helix:    run :config-reload (or :theme $theme) in each instance"
		echo "  zsh:      open a new shell - fzf/ZHM/oh-my-posh bind colors at init"
		echo "  treelix:  restart sidebar panes (no hot reload)"
	fi
}

main
