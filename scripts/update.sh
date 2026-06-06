#!/usr/bin/env bash

# Update every dependency setup.sh installed. Updates the brew packages
# we manage but does NOT run `brew update` on Homebrew itself
# (HOMEBREW_NO_AUTO_UPDATE=1).
#
# What it updates:
#   1. helix-files repo itself: git pull --ff-only (so the steps below
#      and the zshrc managed-block content are current)
#   1b. Stale-artifact cleanup: remove broken ~/.config symlinks into this
#      repo (e.g. broot, replaced by treelix), stale broot sockets, orphaned
#      per-session treelix/helix sockets (conservatively), the broot brew
#      formula we no longer manage, and broot's leftover launcher `source`
#      line in ~/.zshrc (which errors on new shells after broot is removed).
#   2. Brew packages we installed: brew upgrade (with auto-update disabled)
#   3. mise-managed tools: mise upgrade (runtimes, LSPs, formatters)
#   4. Helix nightly: git pull + cargo install --path helix-term --locked.
#      Default checkout is the `local-patches` branch on the kodyberry23/helix
#      fork (PR #13896 socket + PR #13963 auto-reload + local follow-ups).
#      Pulls fork updates, fetches `upstream/master`, and reports drift
#      so the user can rebase deliberately. Skips rebuild when HEAD didn't
#      move.
#   4b. treelix (sidebar file tree): download the latest prebuilt release
#      binary if newer (or git pull + rebuild when TREELIX_FROM_SOURCE=1).
#   5. zsh-helix-mode: git pull --ff-only
#   6. ~/.zshrc managed block: re-stamp via `setup.sh --only-zshrc` so
#      drift between setup.sh's zshrc_block heredoc and the deployed
#      ~/.zshrc gets corrected on every update
#
# Caveat: step 1 pulls a new copy of common.sh / setup.sh / update.sh,
# but this script keeps running with the OLD versions it already sourced.
# If a pull changes BREW_FORMULAS, mise tools, or update.sh's own logic,
# re-run scripts/update.sh once more to apply the new behavior. Step 6
# shells out to a fresh `bash setup.sh`, so it always sees the latest
# zshrc_block content.
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
HELIX_SRC="$HOME/projects/helix"
TREELIX_SRC="$HOME/projects/treelix"
ZHM_DIR="$REPO_ROOT/zsh-helix-mode"

usage() {
	cat <<'USAGE'
Update dependencies installed by setup.sh. Skips `brew update` on Homebrew
itself - pass HOMEBREW_NO_AUTO_UPDATE=1 to `brew upgrade`.

Updates:
  1. helix-files repo (git pull --ff-only)
  1b. Stale-artifact cleanup (broken config symlinks, broot leftovers,
     orphaned sockets)
  2. Brew packages we manage (brew upgrade, no auto-update)
  3. mise-managed tools (runtimes, LSPs, formatters)
  4. Helix nightly (pull on master, or fetch + report-only on local-patches)
  5. zsh-helix-mode (git pull)
  6. ~/.zshrc managed block (setup.sh --only-zshrc)

Usage:
  scripts/update.sh             actually update
  scripts/update.sh --dry-run   preview without changing anything
  scripts/update.sh -n          same as --dry-run
  scripts/update.sh -h | --help this message
USAGE
}

parse_dry_run_args "$@"

dry_run_banner "$DRY_RUN"

# ─── 1. helix-files repo itself ───────────────────────────────────────────
# Pull this repo first so subsequent steps (and the --only-zshrc shellout)
# see the latest setup.sh/zshrc_block content. The currently-executing
# script keeps its OLD common.sh sourced - see the caveat in the header.
update_helix_files_repo() {
	info "helix-files repo"
	if [[ ! -d "$REPO_ROOT/.git" ]]; then
		warn "$REPO_ROOT is not a git checkout; skipping"
		return
	fi
	if $DRY_RUN; then
		would "git -C $REPO_ROOT pull --ff-only"
		return
	fi
	# --ff-only fails loudly if there are local commits or a dirty tree.
	# Better to surface the conflict than to silently merge or stash.
	git -C "$REPO_ROOT" pull --ff-only
	ok "up to date"
}

# ─── 2. Brew packages ─────────────────────────────────────────────────────
# Package lists live in lib/common.sh (BREW_FORMULAS, BREW_CASKS) so setup.sh
# and update.sh stay in lockstep without a "keep in sync" comment.
update_brew_packages() {
	info "Brew packages (Homebrew itself untouched)"
	if ! has_cmd brew; then
		warn "brew not on PATH; skipping"
		return
	fi

	# HOMEBREW_NO_AUTO_UPDATE=1 disables the automatic `brew update` that
	# normally runs before any upgrade - this is what keeps Homebrew itself
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

# ─── 4. Helix nightly ─────────────────────────────────────────────────────
# Handles two checkout modes:
#   - local-patches (default, fork-tracked): fast-forward from origin
#     (the kodyberry23/helix fork) and report if upstream master has
#     drifted, so the user can rebase deliberately
#   - master (vanilla): fast-forward + rebuild if HEAD moved
update_helix() {
	info "Helix nightly"
	if [[ ! -d "$HELIX_SRC/.git" ]]; then
		warn "$HELIX_SRC not cloned yet - run setup.sh first; skipping"
		return
	fi

	if $DRY_RUN; then
		would "fetch origin + upstream; pull local-patches or master depending on branch"
		would "cargo install --path $HELIX_SRC/helix-term --locked (only if HEAD moved)"
		return
	fi

	if ! ensure_cargo_on_path; then
		err "cargo not found - install rust via mise / rustup and re-run"
		return 1
	fi

	if [[ -n "$(git -C "$HELIX_SRC" status --porcelain)" ]]; then
		warn "$HELIX_SRC has uncommitted changes; skipping pull (commit or stash first)"
		return
	fi

	# `origin` is the kodyberry23/helix fork (set up by setup.sh); `upstream`
	# is helix-editor/helix. Fetch both so we can both pull fork changes and
	# compare against upstream master for rebase prompts.
	git -C "$HELIX_SRC" fetch origin >/dev/null 2>&1 || true
	git -C "$HELIX_SRC" fetch upstream master >/dev/null 2>&1 || true
	local branch
	branch=$(git -C "$HELIX_SRC" branch --show-current)

	# local-patches: tracked on the fork. Pull --ff-only from origin (the
	# fork) so changes pushed from another machine land here; then check
	# upstream/master for drift and report if a rebase is offered.
	if [[ "$branch" == "local-patches" ]]; then
		local before_head
		before_head=$(git -C "$HELIX_SRC" rev-parse HEAD)
		if git -C "$HELIX_SRC" pull --ff-only origin local-patches >/dev/null 2>&1; then
			:
		else
			warn "fast-forward of local-patches from origin failed (diverged?); skipping pull"
		fi

		local behind
		behind=$(git -C "$HELIX_SRC" rev-list --count HEAD..upstream/master 2>/dev/null || echo 0)
		if [[ ${behind:-0} -gt 0 ]]; then
			warn "upstream/master has $behind new commit(s) since local-patches diverged"
			warn "  rebase manually:  cd $HELIX_SRC && git rebase upstream/master"
			warn "  then push:        git push --force-with-lease origin local-patches"
		fi

		local after_head
		after_head=$(git -C "$HELIX_SRC" rev-parse HEAD)
		if [[ "$before_head" == "$after_head" ]] && has_cmd hx; then
			ok "already built at $(git -C "$HELIX_SRC" rev-parse --short HEAD)"
			return
		fi

		info "  rebuilding helix-term"
		cargo install --path "$HELIX_SRC/helix-term" --locked --force
		ok "rebuilt ($(git -C "$HELIX_SRC" rev-parse --short HEAD))"
		return
	fi

	# Any other non-master branch: surface and bail, don't guess intent.
	if [[ "$branch" != "master" ]]; then
		warn "$HELIX_SRC is on branch '$branch'; skipping (unknown to update.sh)"
		return
	fi

	# Vanilla master path: fast-forward + rebuild if HEAD moved.
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

# ─── 4b. treelix (sidebar file tree) ──────────────────────────────────────
# Update treelix to the latest release binary (no compile). With
# TREELIX_FROM_SOURCE=1, pull the git checkout and rebuild only if HEAD moved.
update_treelix() {
	info "treelix"

	# Ensure ~/.config/treelix is linked. setup.sh normally does this, but a
	# machine switching from broot for the first time may run update before a
	# fresh setup; without the link treelix falls back to built-in defaults
	# (functionally identical, but link it so config edits take effect). Only
	# create when absent — never clobber a real dir/file; cleanup_stale (step
	# 1b) already removed any dangling link.
	local cfg="$HOME/.config/treelix" repo_cfg="$REPO_ROOT/treelix"
	if [[ -d "$repo_cfg" && ! -e "$cfg" && ! -L "$cfg" ]]; then
		if $DRY_RUN; then
			would "ln -s $repo_cfg $cfg"
		else
			mkdir -p "$(dirname "$cfg")"
			ln -s "$repo_cfg" "$cfg" && ok "linked ~/.config/treelix -> $repo_cfg"
		fi
	fi

	if [[ "${TREELIX_FROM_SOURCE:-0}" == "1" ]]; then
		update_treelix_from_source
		return
	fi

	# Both substitutions must tolerate failure under `set -e`: a rate-limited
	# or unreachable GitHub API makes treelix_latest_tag exit non-zero (curl -f
	# + pipefail), and an old treelix without --version makes that pipeline
	# fail too. Without the `|| true` either one would abort the whole update
	# run instead of falling through to a reinstall.
	local latest installed
	latest=$(treelix_latest_tag) || true
	installed=$(treelix --version 2>/dev/null | awk '{print $2}') || true
	if [[ -n $latest && "v${installed:-}" == "$latest" ]]; then
		ok "already up to date ($latest)"
		return
	fi
	if $DRY_RUN; then
		would "download latest treelix release (${latest:-latest}) -> ~/.cargo/bin/treelix"
		return
	fi
	if install_treelix_from_release; then
		ok "treelix -> $(treelix --version 2>/dev/null || echo "${latest:-latest}")"
	else
		warn "  release update failed (set TREELIX_FROM_SOURCE=1 to build from source)"
	fi
}

update_treelix_from_source() {
	if [[ ! -d "$TREELIX_SRC/.git" ]]; then
		warn "$TREELIX_SRC not cloned yet - run setup.sh first; skipping"
		return
	fi
	if $DRY_RUN; then
		would "git -C $TREELIX_SRC pull --ff-only"
		would "cargo install --path $TREELIX_SRC --locked (only if HEAD moved)"
		return
	fi
	if ! ensure_cargo_on_path; then
		warn "cargo not on PATH; skipping treelix"
		return
	fi
	if [[ -n "$(git -C "$TREELIX_SRC" status --porcelain)" ]]; then
		warn "$TREELIX_SRC has uncommitted changes; skipping pull (commit or stash first)"
		return
	fi
	local before after
	before=$(git -C "$TREELIX_SRC" rev-parse HEAD)
	git -C "$TREELIX_SRC" pull --ff-only
	after=$(git -C "$TREELIX_SRC" rev-parse HEAD)
	if [[ "$before" == "$after" ]]; then
		ok "already up to date ($(git -C "$TREELIX_SRC" rev-parse --short HEAD))"
		return
	fi
	info "  rebuilding treelix ($before -> $after)"
	cargo install --path "$TREELIX_SRC" --locked --force
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

# ─── 6. zsh-helix-mode ────────────────────────────────────────────────────
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

# ─── 7. ~/.zshrc managed block ────────────────────────────────────────────
# Shells out to setup.sh in a fresh bash process so it picks up the
# zshrc_block heredoc from the just-pulled tree (not whatever update.sh
# happened to source at startup).
refresh_zshrc_managed_block() {
	if $DRY_RUN; then
		bash "$SCRIPT_DIR/setup.sh" --only-zshrc --dry-run
	else
		bash "$SCRIPT_DIR/setup.sh" --only-zshrc
	fi
}

# ─── 1b. Clean up stale artifacts ─────────────────────────────────────────
# Remove things older versions of this setup left behind that are no longer
# used. Runs after the repo pull so removed files (e.g. the broot config that
# treelix replaced) are reflected. Conservative: only touches our own broken
# symlinks, broot's leftovers, and orphaned per-session sockets.
cleanup_stale() {
	info "Stale-artifact cleanup"
	local found=0

	# 1. Broken ~/.config symlinks pointing into THIS repo. Catches configs we
	#    removed from the repo (broot today, anything else later). Only dangling
	#    links are removed; live ones are left untouched.
	if [[ -d "$HOME/.config" ]]; then
		local link target
		shopt -s nullglob
		for link in "$HOME/.config"/*; do
			[[ -L "$link" ]] || continue
			target=$(readlink "$link")
			# `! -e` is true for a dangling link (it follows the link to test).
			if [[ "$target" == "$REPO_ROOT"/* && ! -e "$link" ]]; then
				found=1
				if $DRY_RUN; then
					would "rm dangling symlink $link -> $target"
				else
					rm -f "$link" && ok "removed dangling symlink ~/.config/$(basename "$link")"
				fi
			fi
		done
		shopt -u nullglob
	fi

	# 2. Stale broot server sockets (broot is no longer launched at all).
	local sock
	shopt -s nullglob
	for sock in /tmp/broot-server-*.sock; do
		found=1
		if $DRY_RUN; then
			would "rm stale broot socket $sock"
		else
			rm -f "$sock" && ok "removed stale broot socket $(basename "$sock")"
		fi
	done
	shopt -u nullglob

	# 3. Orphaned treelix/helix per-session sockets whose owning session is
	#    gone. Deliberately conservative to never break a live session: a socket
	#    is only removed when ALL of these hold — no matching live zellij session
	#    (names sanitized the same way the sockets are), not the session we're
	#    running inside, and older than 60 minutes (so we never race a session
	#    that just started). Skipped entirely if zellij isn't available.
	if has_cmd zellij; then
		local live="" raw current
		while IFS= read -r raw; do
			raw=${raw%% *}                                   # first field = name
			raw=$(printf '%s' "$raw" | sed -E 's/\x1b\[[0-9;]*m//g')  # strip ANSI
			[[ -z "$raw" ]] && continue
			live+="${raw//[^A-Za-z0-9_-]/_}"$'\n'            # sanitize like sockets
		done < <(zellij list-sessions 2>/dev/null || true)
		current=${ZELLIJ_SESSION_NAME:-}
		current=${current//[^A-Za-z0-9_-]/_}

		local base s name
		for base in "${XDG_RUNTIME_DIR:-/tmp}/treelix" "${XDG_RUNTIME_DIR:-/tmp}/helix"; do
			[[ -d "$base" ]] || continue
			shopt -s nullglob
			for s in "$base"/*.sock; do
				name=$(basename "$s" .sock)
				[[ -n "$current" && "$name" == "$current" ]] && continue   # our session
				grep -qxF "$name" <<<"$live" && continue                   # live session
				[[ -n "$(find "$s" -mmin +60 2>/dev/null)" ]] || continue  # too fresh
				found=1
				if $DRY_RUN; then
					would "rm orphaned socket $s (no live session '$name')"
				else
					rm -f "$s" && ok "removed orphaned socket $(basename "$s")"
				fi
			done
			shopt -u nullglob
		done
	fi

	# 4. broot brew formula (replaced by treelix; we no longer manage it).
	if has_cmd brew && brew_has formula broot; then
		found=1
		if $DRY_RUN; then
			would "brew uninstall broot (replaced by treelix)"
		else
			info "  uninstalling broot (replaced by treelix)"
			brew uninstall broot >/dev/null 2>&1 \
				&& ok "uninstalled broot" \
				|| warn "  brew uninstall broot failed (depended on, or in use?)"
		fi
	fi

	# 5. broot launcher hook in ~/.zshrc. `broot --install` appends a
	#    `source ~/.config/broot/launcher/bash/br` line (and sometimes a `# br`
	#    comment) OUTSIDE our managed block, so it survived the symlink removal
	#    and now errors on every new shell ("no such file or directory ... /br").
	#    Strip those lines; a one-time backup is kept at ~/.zshrc.bak.broot.
	local zrc="$HOME/.zshrc"
	if [[ -f "$zrc" ]] && grep -qE 'broot/launcher' "$zrc"; then
		found=1
		if $DRY_RUN; then
			would "remove broot launcher line(s) from $zrc (backup: $zrc.bak.broot)"
		else
			cp "$zrc" "$zrc.bak.broot" 2>/dev/null || true
			local tmp
			tmp=$(mktemp) || tmp=""
			if [[ -n "$tmp" ]]; then
				grep -vE 'broot/launcher|^# br$' "$zrc" >"$tmp" 2>/dev/null || true
				if [[ -s "$tmp" ]]; then
					mv "$tmp" "$zrc"
					ok "removed broot launcher line(s) from ~/.zshrc (backup: ~/.zshrc.bak.broot)"
				else
					rm -f "$tmp"
					warn "  skipped ~/.zshrc edit (filter produced empty file)"
				fi
			fi
		fi
	fi

	if (( found == 0 )); then
		ok "nothing stale to clean"
	fi
	# Never let this function's exit status fall through as non-zero (the
	# arithmetic test above returns 1 when found!=0), which under `set -e`
	# would silently abort the rest of update.sh after a successful cleanup.
	return 0
}

main() {
	update_helix_files_repo
	cleanup_stale
	update_brew_packages
	update_mise_tools
	update_helix
	update_treelix
	update_zsh_helix_mode
	refresh_zshrc_managed_block

	echo
	if $DRY_RUN; then
		info "Dry-run complete - no changes made"
		echo "  Re-run without --dry-run to apply."
	else
		info "Done"
	fi
}

main "$@"
