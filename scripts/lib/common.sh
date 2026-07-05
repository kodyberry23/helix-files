# shellcheck shell=bash
# Shared helpers + shared constants for scripts in helix-files/scripts.
# Source this from the top of each script:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# ─── ANSI colours ─────────────────────────────────────────────────────────
C_BLUE="\033[34m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
C_CYAN="\033[36m"
C_RESET="\033[0m"

info()  { printf "${C_BLUE}==>${C_RESET} %s\n"        "$*";     }
ok()    { printf "${C_GREEN}  ✓${C_RESET} %s\n"       "$*";     }
warn()  { printf "${C_YELLOW}  !${C_RESET} %s\n"      "$*" >&2; }
err()   { printf "${C_RED}  ✗${C_RESET} %s\n"         "$*" >&2; }
would() { printf "${C_CYAN}  ~${C_RESET} would %s\n"  "$*";     }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Ensure `cargo` is callable in the current shell. setup.sh / update.sh
# may run non-interactively (no `mise activate`), in which case mise's
# rust shim isn't on PATH yet. Falls back to ~/.cargo/bin too. Returns
# 0 if cargo is reachable after the fixup, 1 otherwise.
ensure_cargo_on_path() {
	has_cmd cargo && return 0
	export PATH="$HOME/.local/share/mise/shims:$HOME/.cargo/bin:$PATH"
	has_cmd cargo
}

# Resolve $1 to an absolute path. Works for directories and for files that
# don't exist yet (resolves the parent, then appends the basename). Used
# by dispatch-to-editor / dispatch-to-sidebar so helix and treelix interpret
# routed paths the same regardless of caller cwd.
abs_path() {
	if [[ -d $1 ]]; then
		(cd "$1" && pwd)
	else
		echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
	fi
}

# ─── Per-session socket paths (single source of truth) ────────────────────
# helix (command listener, PR #13896) and treelix (reveal socket) each bind
# a per-zellij-session unix socket. Binder and sender MUST derive identical
# paths, so every script goes through these helpers; treelix's own Rust
# fallback (src/ipc.rs) mirrors the same derivation for when the env vars
# aren't set. Session names are sanitized to filename-safe characters.
zellij_session_slug() {
	local s=${ZELLIJ_SESSION_NAME:-default}
	printf '%s' "${s//[^A-Za-z0-9_-]/_}"
}

helix_socket_path() {
	printf '%s' "${XDG_RUNTIME_DIR:-/tmp}/helix/$(zellij_session_slug).sock"
}

treelix_socket_path() {
	printf '%s' "${XDG_RUNTIME_DIR:-/tmp}/treelix/$(zellij_session_slug).sock"
}

# Print the zellij pane id for the terminal pane whose TITLE matches $1,
# or nothing if no match. TITLE is the layout's `pane name="..."` and
# stable across resizes, tab moves, and restarts (but not manual rename
# via the zellij rename-pane action).
#
# zellij action list-panes returns a plain-text table - despite the
# `--help` text mentioning "table or JSON", there is no working --json
# flag, so awk-parsing the text is the only option today.
resolve_pane_id_by_name() {
	local name=${1:?usage: resolve_pane_id_by_name <name>}
	zellij action list-panes 2>/dev/null \
		| awk -v n="$name" '$2=="terminal" && $3==n {print $1; exit}'
}

# ─── Shared package lists (single source of truth) ────────────────────────
# setup.sh installs these; update.sh upgrades them. Helix, treelix, and zellij
# are intentionally excluded: helix/treelix are built from source in setup.sh,
# and zellij is pinned to a known-good version via cargo (see
# ZELLIJ_PINNED_VERSION below) rather than tracking brew's latest. bat and tree
# feed the FZF preview commands wired up in the .zshrc managed block.
BREW_FORMULAS=(mise jdtls erlang_ls marksman oh-my-posh fzf fd zoxide eza bat tree git jq)
BREW_CASKS=(ghostty)

# ─── zellij pinned install ────────────────────────────────────────────────
# zellij is pinned rather than tracking Homebrew's latest. 0.44.3 (PR #4992 /
# #5011, "preserve background color in trailing and skipped characters") broke
# terminal-background transparency: zellij now paints default-bg cells with a
# concrete colour instead of leaving them terminal-default (\e[49m), so
# ghostty's background-opacity no longer shows through helix's editing area,
# and the zellij theme's `background 0` trick can't work around it. 0.44.2 is
# the last release before the regression. Installed via cargo into
# ~/.cargo/bin (which precedes /opt/homebrew/bin on PATH), so it's excluded
# from BREW_FORMULAS above. Bump this only after confirming transparency still
# works on the newer version.
ZELLIJ_PINNED_VERSION="0.44.2"

# Installed zellij version (e.g. "0.44.2"), or empty if not installed.
zellij_installed_version() {
	zellij --version 2>/dev/null | awk '{print $2}'
}

# cargo-install the pinned zellij into ~/.cargo/bin. Pure: no dry-run gating or
# logging - callers handle those. Compiles from source (~4 min). Returns
# cargo's exit status.
install_zellij_pinned() {
	cargo install zellij --version "$ZELLIJ_PINNED_VERSION" --locked --force
}

# ─── Dry-run flag handling ────────────────────────────────────────────────
# parse_dry_run_args sets DRY_RUN=true if --dry-run / -n appears anywhere in
# the args. Calls a script-supplied `usage` function on -h / --help. Errors
# on any other flag (positional args aren't expected for setup/update). Each
# script defines its own usage() before sourcing this.
parse_dry_run_args() {
	DRY_RUN=false
	for arg in "$@"; do
		case "$arg" in
			--dry-run|-n) DRY_RUN=true ;;
			-h|--help)    usage; exit 0 ;;
			*)            err "unknown argument: $arg"; exit 2 ;;
		esac
	done
}

# Print "DRY RUN - no changes will be made" if $1 is true.
dry_run_banner() {
	if [[ "${1:-false}" == "true" ]]; then
		info "DRY RUN - no changes will be made"
		echo
	fi
}

# ─── brew package probing ─────────────────────────────────────────────────
# brew_has formula <name>   → 0 if installed via brew (formula), else 1
# brew_has cask    <name>   → 0 if installed via brew (cask),    else 1
# Caches the brew list output per kind so repeated probes don't fork brew.
__brew_list_formula=""
__brew_list_cask=""
__brew_list_loaded=0
__brew_list_load() {
	(( __brew_list_loaded == 1 )) && return
	__brew_list_formula=$(brew list --formula -1 2>/dev/null || true)
	__brew_list_cask=$(brew list --cask -1 2>/dev/null || true)
	__brew_list_loaded=1
}
brew_has() {
	__brew_list_load
	local kind=$1 pkg=$2 list=""
	case "$kind" in
		formula) list=$__brew_list_formula ;;
		cask)    list=$__brew_list_cask    ;;
		*)       return 1                  ;;
	esac
	grep -qFx "$pkg" <<<"$list"
}

# ─── treelix prebuilt-release install ─────────────────────────────────────
# treelix ships prebuilt macOS binaries from its release workflow, so we
# install those instead of compiling from source. Set TREELIX_FROM_SOURCE=1
# (handled by setup.sh / update.sh) to build from the git checkout instead.
TREELIX_REPO_SLUG="kodyberry23/treelix"

# Map `uname -m` to the release target triple, or fail on an unknown arch.
treelix_target() {
	case "$(uname -m)" in
		arm64|aarch64) echo "aarch64-apple-darwin" ;;
		x86_64)        echo "x86_64-apple-darwin"  ;;
		*)             return 1                    ;;
	esac
}

# Latest release tag (e.g. v0.1.1) via the public GitHub API. Empty on failure.
treelix_latest_tag() {
	curl -fsSL "https://api.github.com/repos/${TREELIX_REPO_SLUG}/releases/latest" 2>/dev/null \
		| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
		| head -1
}

# Download, checksum-verify, and install the latest treelix release binary into
# ~/.cargo/bin/treelix. Returns 0 on success, non-zero on any failure (callers
# fall back to a source build).
install_treelix_from_release() {
	local target url tmp bin want have
	target=$(treelix_target) || { warn "  unsupported arch for prebuilt treelix"; return 1; }
	url="https://github.com/${TREELIX_REPO_SLUG}/releases/latest/download/treelix-${target}.tar.gz"

	tmp=$(mktemp -d) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp'" RETURN

	if ! curl -fsSL "$url" -o "$tmp/treelix.tar.gz"; then
		warn "  could not download $url"
		return 1
	fi
	# Verify the published sha256 when present.
	if curl -fsSL "$url.sha256" -o "$tmp/treelix.sha256" 2>/dev/null; then
		want=$(awk '{print $1}' "$tmp/treelix.sha256")
		have=$(shasum -a 256 "$tmp/treelix.tar.gz" | awk '{print $1}')
		if [[ -n $want && $want != "$have" ]]; then
			err "  treelix checksum mismatch (expected $want, got $have)"
			return 1
		fi
	fi

	tar -xzf "$tmp/treelix.tar.gz" -C "$tmp" || return 1
	bin="$tmp/treelix-${target}/treelix"
	[[ -x $bin ]] || { err "  treelix binary missing in archive"; return 1; }

	mkdir -p "$HOME/.cargo/bin"
	install -m 0755 "$bin" "$HOME/.cargo/bin/treelix" || return 1
	# curl doesn't set the quarantine xattr, but strip it defensively.
	xattr -d com.apple.quarantine "$HOME/.cargo/bin/treelix" 2>/dev/null || true
	return 0
}

# Resolve a runnable treelix binary: PATH first, then ~/.cargo/bin (zellij panes
# may spawn with a minimal PATH that omits ~/.cargo/bin). Prints the path and
# returns 0, or returns 1 if treelix isn't installed anywhere we know.
treelix_bin() {
	if command -v treelix >/dev/null 2>&1; then
		command -v treelix
	elif [[ -x "$HOME/.cargo/bin/treelix" ]]; then
		echo "$HOME/.cargo/bin/treelix"
	else
		return 1
	fi
}
