#!/usr/bin/env bash

# Update every dependency setup.sh installed. Updates the brew packages
# we manage but does NOT run `brew update` on Homebrew itself
# (HOMEBREW_NO_AUTO_UPDATE=1).
#
# What it updates:
#   1. Brew packages we installed: brew upgrade (with auto-update disabled)
#   2. mise-managed tools: mise upgrade (runtimes, LSPs, formatters)
#   3. Helix nightly: git pull + cargo install --path helix-term --locked
#   4. zsh-helix-mode: git pull --ff-only
#
# Usage:
#   scripts/update.sh             # actually update
#   scripts/update.sh --dry-run   # preview without changing anything
#   scripts/update.sh -n          # same as --dry-run
#   scripts/update.sh -h | --help # usage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

REPO_ROOT="${HELIX_FILES:-$(cd "$SCRIPT_DIR/.." && pwd)}"
HELIX_SRC="$HOME/src/helix"
ZHM_DIR="$REPO_ROOT/zsh-helix-mode"

usage() {
	cat <<'USAGE'
Update dependencies installed by setup.sh. Skips `brew update` on Homebrew
itself — pass HOMEBREW_NO_AUTO_UPDATE=1 to `brew upgrade`.

Updates:
  1. Brew packages we manage (brew upgrade, no auto-update)
  2. mise-managed tools (runtimes, LSPs, formatters)
  3. Helix nightly (git pull + cargo install)
  4. zsh-helix-mode (git pull)

Usage:
  scripts/update.sh             actually update
  scripts/update.sh --dry-run   preview without changing anything
  scripts/update.sh -n          same as --dry-run
  scripts/update.sh -h | --help this message
USAGE
}

parse_dry_run_args "$@"

dry_run_banner "$DRY_RUN"

# ─── 1. Brew packages ─────────────────────────────────────────────────────
# Package lists live in lib/common.sh (BREW_FORMULAS, BREW_CASKS) so setup.sh
# and update.sh stay in lockstep without a "keep in sync" comment.
update_brew_packages() {
	info "Brew packages (Homebrew itself untouched)"
	if ! has_cmd brew; then
		warn "brew not on PATH; skipping"
		return
	fi

	# HOMEBREW_NO_AUTO_UPDATE=1 disables the automatic `brew update` that
	# normally runs before any upgrade — this is what keeps Homebrew itself
	# (the formula database / git repo) untouched.
	export HOMEBREW_NO_AUTO_UPDATE=1

	# Filter to only what's actually installed; brew complains if you upgrade
	# something it doesn't know about.
	local to_upgrade_f=() to_upgrade_c=()
	for pkg in "${BREW_FORMULAS[@]}"; do
		if brew_has formula "$pkg"; then
			to_upgrade_f+=("$pkg")
		else
			warn "$pkg not installed via brew; skipping"
		fi
	done
	for pkg in "${BREW_CASKS[@]}"; do
		if brew_has cask "$pkg"; then
			to_upgrade_c+=("$pkg")
		else
			warn "$pkg cask not installed via brew; skipping"
		fi
	done

	if [[ ${#to_upgrade_f[@]} -gt 0 ]]; then
		if $DRY_RUN; then
			would "brew upgrade --formula ${to_upgrade_f[*]}"
		else
			info "  upgrading formulas: ${to_upgrade_f[*]}"
			brew upgrade --formula "${to_upgrade_f[@]}"
		fi
	fi
	if [[ ${#to_upgrade_c[@]} -gt 0 ]]; then
		if $DRY_RUN; then
			would "brew upgrade --cask ${to_upgrade_c[*]}"
		else
			info "  upgrading casks: ${to_upgrade_c[*]}"
			brew upgrade --cask "${to_upgrade_c[@]}"
		fi
	fi
	ok "brew packages up to date"
}

# ─── 2. Helix nightly ─────────────────────────────────────────────────────
update_helix() {
	info "Helix nightly"
	if [[ ! -d "$HELIX_SRC/.git" ]]; then
		warn "$HELIX_SRC not cloned yet — run setup.sh first; skipping"
		return
	fi

	if $DRY_RUN; then
		would "git -C $HELIX_SRC pull --ff-only"
		would "cargo install --path $HELIX_SRC/helix-term --locked (only if HEAD moved)"
		return
	fi

	# Mise puts cargo on a shims path that our shell may not have if this
	# script is invoked from a non-interactive context.
	if ! has_cmd cargo; then
		export PATH="$HOME/.local/share/mise/shims:$HOME/.cargo/bin:$PATH"
	fi
	if ! has_cmd cargo; then
		err "cargo not found — install rust via mise / rustup and re-run"
		return 1
	fi

	# Capture HEAD before/after so we only rebuild when something actually changed.
	local before after
	before=$(git -C "$HELIX_SRC" rev-parse HEAD)
	git -C "$HELIX_SRC" pull --ff-only
	after=$(git -C "$HELIX_SRC" rev-parse HEAD)

	if [[ "$before" == "$after" ]]; then
		ok "already up to date ($(git -C "$HELIX_SRC" describe --always --dirty 2>/dev/null || echo "$after"))"
		return
	fi

	info "  rebuilding helix-term ($before -> $after)"
	cargo install --path "$HELIX_SRC/helix-term" --locked
	ok "rebuilt"
}

# ─── 3. mise-managed tools ────────────────────────────────────────────────
update_mise_tools() {
	info "mise tools"
	if ! has_cmd mise; then
		warn "mise not on PATH; skipping"
		return
	fi
	if $DRY_RUN; then
		would "run 'mise upgrade'"
		return
	fi
	# `mise upgrade` updates each tool to the newest version satisfying the
	# constraints in ~/.config/mise/config.toml. Idempotent; no-ops if
	# nothing's drifted.
	mise upgrade
	ok "mise tools upgraded"
}

# ─── 4. zsh-helix-mode ────────────────────────────────────────────────────
update_zsh_helix_mode() {
	info "zsh-helix-mode"
	if [[ ! -d "$ZHM_DIR/.git" ]]; then
		warn "$ZHM_DIR is not a git checkout; skipping"
		return
	fi
	if $DRY_RUN; then
		would "git -C $ZHM_DIR pull --ff-only"
		return
	fi
	git -C "$ZHM_DIR" pull --ff-only
	ok "up to date"
}

main() {
	update_brew_packages
	update_mise_tools
	update_helix
	update_zsh_helix_mode

	echo
	if $DRY_RUN; then
		info "Dry-run complete — no changes made"
		echo "  Re-run without --dry-run to apply."
	else
		info "Done"
	fi
}

main "$@"
