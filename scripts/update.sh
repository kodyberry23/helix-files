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
#   4. Helix nightly: git sync + cargo install --path helix-term --locked.
#      Default checkout is the `local-patches` branch on the kodyberry23/helix
#      fork (PR #13896 socket + PR #14544 watcher auto-reload + VCS trigger
#      extension + window-pick/sidebar-follow). Syncs from origin (the fork):
#      fast-forwards when possible, and when origin's history was rewritten
#      (a deliberate force-push from the other machine) it saves the old tip
#      to a backup/ branch and hard-resets - no manual surgery needed on the
#      second machine. With --sync-upstream it additionally MERGES
#      upstream/master into local-patches (merge, never rebase: append-only
#      history keeps every machine's plain pull working), refreshes the
#      pristine `master` mirror, and pushes both back to the fork after a
#      successful build. Skips rebuild when HEAD didn't move.
#   4b. treelix (sidebar file tree): download the latest prebuilt release
#      binary if newer (or git pull + rebuild when TREELIX_FROM_SOURCE=1).
#   5. zsh-helix-mode: git pull --ff-only
#   5b. Theme system: re-run scripts/apply-theme.sh so a pulled change to
#      themes/*.toml or themes/templates/* regenerates the per-app theme
#      files and re-points them at the active theme from
#      ~/.config/helix-files.toml. This step also re-stamps the ~/.zshrc
#      managed block (apply-theme.sh ends with `setup.sh --only-zshrc` in
#      a fresh bash, so it always sees the just-pulled zshrc_block), which
#      is what keeps the deployed ~/.zshrc from drifting behind setup.sh
#      edits on every update.
#
# Caveat: step 1 pulls a new copy of common.sh / setup.sh / update.sh,
# but this script keeps running with the OLD versions it already sourced.
# If a pull changes BREW_FORMULAS, mise tools, or update.sh's own logic,
# re-run scripts/update.sh once more to apply the new behavior. Step 5b
# shells out to fresh `bash apply-theme.sh` / `bash setup.sh` processes,
# so themes and the zshrc block always come from the just-pulled tree.
#
# Usage:
#   scripts/update.sh                  # actually update
#   scripts/update.sh --sync-upstream  # also merge helix upstream/master in
#   scripts/update.sh --dry-run        # preview without changing anything
#   scripts/update.sh -n               # same as --dry-run
#   scripts/update.sh -h | --help      # usage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

REPO_ROOT="${HELIX_FILES:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# Env-overridable (like HELIX_FILES above) so tests can point update_helix
# at a sandbox checkout instead of the real one.
HELIX_SRC="${HELIX_SRC:-$HOME/projects/helix}"
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
  4. Helix nightly (sync local-patches from the fork - fast-forward, or
     backup + reset when origin was force-pushed; rebuild if HEAD moved.
     With --sync-upstream: also merge upstream/master into local-patches
     and push back to the fork after a successful build)
  5. zsh-helix-mode (git pull)
  5b. Theme system (apply-theme.sh: regenerate + re-point per-app themes;
     also re-stamps the ~/.zshrc managed block)

Usage:
  scripts/update.sh                  actually update
  scripts/update.sh --sync-upstream  also merge helix upstream/master in
  scripts/update.sh --dry-run        preview without changing anything
  scripts/update.sh -n               same as --dry-run
  scripts/update.sh -h | --help      this message
USAGE
}

# --sync-upstream is our own flag; strip it before handing the rest to the
# shared parser (which hard-errors on anything it doesn't know).
SYNC_UPSTREAM=false
_passthrough=()
for _arg in "$@"; do
	if [[ "$_arg" == "--sync-upstream" ]]; then
		SYNC_UPSTREAM=true
	else
		_passthrough+=("$_arg")
	fi
done
# ${arr[@]+...} guard: expanding an empty array errors under `set -u` on
# the bash 3.2 macOS ships.
parse_dry_run_args ${_passthrough[@]+"${_passthrough[@]}"}

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
#   - local-patches (default, fork-tracked): sync from origin (the
#     kodyberry23/helix fork) - fast-forward, or backup + reset when the
#     branch history was rewritten on the other machine. With
#     --sync-upstream, also merge upstream/master in and push back.
#   - master (vanilla): fast-forward + rebuild if HEAD moved

# Merge upstream/master into local-patches. Called from update_helix with
# a clean tree, on local-patches, after the origin sync. MERGE, never
# rebase: rebasing rewrites local-patches, which forces a push --force and
# breaks the other machine's plain pull; merge history is append-only so
# every machine fast-forwards. Also refreshes (or creates - setup.sh
# clones only local-patches) the pristine `master` mirror branch. Sets
# HELIX_UPSTREAM_MERGED=true when a merge commit was created, so
# update_helix pushes only after the build succeeds. On conflict: abort,
# leave the repo exactly as it was, and say how to resolve deliberately.
HELIX_UPSTREAM_MERGED=false
sync_helix_upstream() {
	HELIX_UPSTREAM_MERGED=false

	# Keep the local `master` mirror at upstream. Create it when missing
	# (setup.sh's `git clone --branch local-patches` makes no local
	# master); only force-move it while it is a pristine ancestor - if
	# someone ever committed to master directly, refuse to discard that.
	if ! git -C "$HELIX_SRC" rev-parse -q --verify refs/heads/master >/dev/null; then
		git -C "$HELIX_SRC" branch master upstream/master >/dev/null 2>&1 \
			&& ok "created local 'master' mirror of upstream/master" \
			|| warn "could not create 'master' mirror (upstream/master not fetched?)"
	elif git -C "$HELIX_SRC" merge-base --is-ancestor master upstream/master 2>/dev/null; then
		git -C "$HELIX_SRC" branch -f master upstream/master >/dev/null
	else
		warn "local 'master' is not an ancestor of upstream/master; mirror not updated"
	fi

	local new
	new=$(git -C "$HELIX_SRC" rev-list --count HEAD..upstream/master 2>/dev/null || echo 0)
	if [[ ${new:-0} -eq 0 ]]; then
		ok "local-patches already contains upstream/master"
		# Keep the fork's master mirror current even on no-op runs
		# (best-effort: pure upstream commits, always fast-forward).
		git -C "$HELIX_SRC" push origin master >/dev/null 2>&1 || true
		return 0
	fi

	info "  merging $new upstream commit(s) into local-patches"
	if git -C "$HELIX_SRC" merge --no-edit upstream/master >/dev/null; then
		HELIX_UPSTREAM_MERGED=true
		ok "merged upstream/master into local-patches"
	else
		git -C "$HELIX_SRC" merge --abort >/dev/null 2>&1 || true
		warn "upstream merge conflicts with the local patches - aborted, repo left untouched"
		warn "  resolve deliberately:  cd $HELIX_SRC && git merge upstream/master"
	fi
	return 0
}

update_helix() {
	info "Helix nightly"
	if [[ ! -d "$HELIX_SRC/.git" ]]; then
		warn "$HELIX_SRC not cloned yet - run setup.sh first; skipping"
		return
	fi

	if $DRY_RUN; then
		would "fetch origin + upstream; sync local-patches from origin (ff, or backup + reset if origin was rewritten)"
		$SYNC_UPSTREAM && would "merge upstream/master into local-patches; push branch + master mirror after a successful build"
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
	# compare against upstream master. A failed origin fetch must be loud:
	# silently comparing against a stale ref would report "already built"
	# while the other machine's push never actually landed here.
	local origin_fetched=true
	if ! git -C "$HELIX_SRC" fetch origin >/dev/null 2>&1; then
		origin_fetched=false
		warn "fetch from the fork failed (offline?); skipping helix sync this run"
	fi
	git -C "$HELIX_SRC" fetch upstream master >/dev/null 2>&1 || true
	local branch
	branch=$(git -C "$HELIX_SRC" branch --show-current)

	# local-patches: tracked on the fork. Sync from origin (the fork) so
	# changes pushed from another machine land here, then optionally merge
	# upstream/master in (--sync-upstream).
	if [[ "$branch" == "local-patches" ]]; then
		local need_push=false

		# Sync cases against origin/local-patches (only with a fresh fetch -
		# stale refs would misclassify):
		#   behind only -> plain fast-forward
		#   diverged, every local commit previously on the fork
		#               -> origin's history was rewritten (a deliberate
		#                  force-push from the other machine, e.g. a patch-
		#                  stack rework). The tree is clean (checked above)
		#                  and nothing local-only exists, so save the old
		#                  tip to a backup/ branch and hard-reset - no
		#                  manual surgery on the second machine.
		#   diverged with local-only commits -> never auto-reset; report.
		#   ahead only  -> local commits not pushed yet; keep them.
		if $origin_fetched; then
			local ahead behind
			ahead=$(git -C "$HELIX_SRC" rev-list --count origin/local-patches..HEAD 2>/dev/null || echo 0)
			behind=$(git -C "$HELIX_SRC" rev-list --count HEAD..origin/local-patches 2>/dev/null || echo 0)
			if [[ ${behind:-0} -gt 0 && ${ahead:-0} -eq 0 ]]; then
				if git -C "$HELIX_SRC" merge --ff-only origin/local-patches >/dev/null 2>&1; then
					ok "fast-forwarded local-patches (+$behind commit(s) from the fork)"
				else
					warn "fast-forward from origin failed unexpectedly; skipping pull"
				fi
			elif [[ ${behind:-0} -gt 0 && ${ahead:-0} -gt 0 ]]; then
				# Distinguish "fork history rewritten" from "genuine local
				# work + new fork commits": resetting is safe only if HEAD
				# was itself a past tip of the fork (or behind one), i.e.
				# every local commit has been on origin/local-patches at
				# some point. The remote-tracking ref's reflog records
				# every value it has had on this machine.
				local safe_to_reset=false entry
				while IFS= read -r entry; do
					if git -C "$HELIX_SRC" merge-base --is-ancestor HEAD "$entry" 2>/dev/null; then
						safe_to_reset=true
						break
					fi
				done < <(git -C "$HELIX_SRC" reflog show --format=%H origin/local-patches 2>/dev/null | head -50)
				if $safe_to_reset; then
					local backup
					backup="backup/local-patches-$(git -C "$HELIX_SRC" rev-parse --short HEAD)"
					git -C "$HELIX_SRC" branch -f "$backup" HEAD >/dev/null
					git -C "$HELIX_SRC" reset --hard origin/local-patches >/dev/null
					warn "origin/local-patches was rewritten (force-push); resynced this checkout to it"
					warn "  previous local tip kept as branch '$backup' - delete it once all is well"
				else
					warn "local-patches and the fork have diverged and this checkout has"
					warn "  local-only commits; not touching it. Reconcile manually:"
					warn "  cd $HELIX_SRC && git log --oneline origin/local-patches..HEAD"
				fi
			elif [[ ${ahead:-0} -gt 0 ]]; then
				if $SYNC_UPSTREAM; then
					# --sync-upstream means "get everything in sync": push
					# the local commits too (below, after a good build).
					need_push=true
					info "  local-patches is $ahead commit(s) ahead; will push after a successful build"
				else
					warn "local-patches is $ahead commit(s) ahead of the fork; push when ready:"
					warn "  git -C $HELIX_SRC push origin local-patches"
				fi
			fi
		fi

		if $SYNC_UPSTREAM; then
			sync_helix_upstream
			if [[ "$HELIX_UPSTREAM_MERGED" == true ]]; then
				need_push=true
			fi
		else
			local drift
			drift=$(git -C "$HELIX_SRC" rev-list --count HEAD..upstream/master 2>/dev/null || echo 0)
			if [[ ${drift:-0} -gt 0 ]]; then
				info "  upstream/master has $drift new commit(s); take them with:  hfu --sync-upstream"
			fi
		fi

		# Rebuild when the installed binary wasn't built from HEAD. Compare
		# the git hash hx embeds in --version (e.g. "helix 25.07.1
		# (55d9030a)") instead of a before/after HEAD check: this also
		# catches a previous run whose build FAILED after moving HEAD -
		# there, HEAD never moves again but the binary is stale.
		local head_full installed_sha rebuilt=false
		head_full=$(git -C "$HELIX_SRC" rev-parse HEAD)
		installed_sha=$({ hx --version 2>/dev/null || true; } | sed -nE 's/.*\(([0-9a-f]{7,40})\).*/\1/p')
		if [[ -n "$installed_sha" && "$head_full" == "$installed_sha"* ]]; then
			ok "already built at $(git -C "$HELIX_SRC" rev-parse --short HEAD)"
		else
			info "  rebuilding helix-term"
			cargo install --path "$HELIX_SRC/helix-term" --locked --force
			ok "rebuilt ($(git -C "$HELIX_SRC" rev-parse --short HEAD))"
			rebuilt=true
		fi

		# Push only with a binary that matches HEAD (just rebuilt, or
		# already matching), so the other machine can never pull an
		# upstream merge that doesn't build. (`set -e` aborts above on a
		# failed build, leaving the merge local-only; the next
		# --sync-upstream run retries the build and then pushes.) The
		# master mirror is pushed separately, best-effort - a problem with
		# it must never block the branch that matters.
		if $need_push; then
			if git -C "$HELIX_SRC" push origin local-patches >/dev/null 2>&1; then
				ok "pushed local-patches to the fork"
			else
				warn "push to the fork failed (offline?); push manually:"
				warn "  git -C $HELIX_SRC push origin local-patches"
			fi
			git -C "$HELIX_SRC" push origin master >/dev/null 2>&1 || true
		fi

		if $rebuilt; then
			warn "  restart open editor panes to load it - a running old helix still"
			warn "  accepts socket dispatches but may lack :open-pick (sidebar picks"
			warn "  would show 'no such command' and open nothing until restarted)"
		fi
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
	warn "  restart open editor panes to load it (running ones keep the old binary)"
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
		warn "  restart open treelix sidebar panes to load it (running ones keep the old binary)"
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
	warn "  restart open treelix sidebar panes to load it (running ones keep the old binary)"
}

# ─── 4c. zellij (pinned, NOT upgraded) ────────────────────────────────────
# zellij is deliberately excluded from BREW_FORMULAS, so update_brew_packages
# never touches it. Instead we enforce the pin here: if the installed zellij
# isn't ZELLIJ_PINNED_VERSION (e.g. a stray `brew upgrade zellij` or manual
# install pulled the transparency-breaking 0.44.3 back), remove the brew copy
# and reinstall the pinned version via cargo. See the regression note in
# lib/common.sh. No-op in the common case where the pin already holds.
update_zellij() {
	info "zellij (pinned $ZELLIJ_PINNED_VERSION, not upgraded)"

	# `|| true`: zellij may be absent, which under `set -e` + pipefail would
	# otherwise abort the run (same guard as update_treelix's version probe).
	local installed brew_managed=false
	installed=$(zellij_installed_version) || true
	if has_cmd brew && brew_has formula zellij; then
		brew_managed=true
	fi

	# Fast path: the pinned cargo build is active and nothing brew-managed
	# lingers - the steady state, no work to do.
	if [[ "$installed" == "$ZELLIJ_PINNED_VERSION" && $brew_managed == false ]]; then
		ok "already at $ZELLIJ_PINNED_VERSION (cargo)"
		return
	fi

	if $DRY_RUN; then
		$brew_managed && would "brew uninstall zellij (drop brew-managed copy)"
		# A cargo build already at the pin needs no recompile even if a brew
		# copy is being removed alongside it.
		[[ "$installed" != "$ZELLIJ_PINNED_VERSION" ]] \
			&& would "cargo install zellij --version $ZELLIJ_PINNED_VERSION --locked --force"
		return
	fi

	if ! ensure_cargo_on_path; then
		err "cargo not found - install rust via mise / rustup and re-run"
		return 1
	fi

	# Remove any brew-managed copy first, then re-probe: dropping brew's zellij
	# can change which binary is first on PATH (brew's was only active if no
	# cargo build existed), so decide whether to compile from what survives.
	if $brew_managed; then
		info "  removing brew-managed zellij"
		brew uninstall zellij >/dev/null 2>&1 \
			&& ok "  uninstalled brew zellij" \
			|| warn "  brew uninstall zellij failed (detach running sessions and re-run)"
		installed=$(zellij_installed_version) || true
	fi

	if [[ "$installed" == "$ZELLIJ_PINNED_VERSION" ]]; then
		ok "already at $ZELLIJ_PINNED_VERSION (cargo)"
		return
	fi

	if [[ -n $installed ]]; then
		info "  pinning zellij $installed -> $ZELLIJ_PINNED_VERSION (compiles, ~4 min)"
	else
		info "  installing pinned zellij $ZELLIJ_PINNED_VERSION (compiles, ~4 min)"
	fi
	install_zellij_pinned
	ok "zellij -> $(zellij_installed_version) (pinned via cargo)"
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

# ─── 5b. Theme system (+ ~/.zshrc managed block) ──────────────────────────
# Shells out to apply-theme.sh in a fresh bash process so it picks up
# just-pulled templates/themes, not whatever this script sourced at
# startup. Regenerates every theme's per-app files, re-points them at the
# active theme, and (as its last step) re-stamps the ~/.zshrc managed
# block via `setup.sh --only-zshrc` - also in a fresh bash, so the block
# content is the just-pulled zshrc_block. No separate zshrc step: that
# would stamp the identical block a second time per update.
apply_theme() {
	info "theme system (apply-theme.sh)"
	if $DRY_RUN; then
		bash "$SCRIPT_DIR/apply-theme.sh" --dry-run
	else
		bash "$SCRIPT_DIR/apply-theme.sh"
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
	update_zellij
	update_zsh_helix_mode
	apply_theme

	echo
	if $DRY_RUN; then
		info "Dry-run complete - no changes made"
		echo "  Re-run without --dry-run to apply."
	else
		info "Done"
	fi
}

# Run main only when executed, not when sourced (tests source this file to
# exercise individual update_* functions against sandbox checkouts).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
