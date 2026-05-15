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
# by dispatch-to-editor / dispatch-to-sidebar so helix and broot interpret
# routed paths the same regardless of caller cwd.
abs_path() {
	if [[ -d $1 ]]; then
		(cd "$1" && pwd)
	else
		echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
	fi
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
# setup.sh installs these; update.sh upgrades them. Helix is intentionally
# excluded - it's built from source in setup.sh. bat and tree feed the FZF
# preview commands wired up in the .zshrc managed block.
BREW_FORMULAS=(zellij broot mise jdtls erlang_ls marksman oh-my-posh fzf fd zoxide eza bat tree git jq)
BREW_CASKS=(ghostty)

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
