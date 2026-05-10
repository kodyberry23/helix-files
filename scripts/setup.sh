#!/usr/bin/env bash

# Bootstrap helix-files on a fresh macOS machine (and re-run safely on an
# already-configured one — every step is idempotent).
#
# Usage:
#   scripts/setup.sh              # actually make changes
#   scripts/setup.sh --dry-run    # preview without touching anything
#   scripts/setup.sh -n           # same as --dry-run
#   scripts/setup.sh -h | --help  # usage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

REPO_ROOT="${HELIX_FILES:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ZSHRC="$HOME/.zshrc"
# Distinct from the `dotfiles managed block` markers so this block can
# coexist with the user's other dotfiles repo without clobbering it.
MARKER_START="# >>> helix-files managed block >>>"
MARKER_END="# <<< helix-files managed block <<<"
# Helix is built from source per https://docs.helix-editor.com/building-from-source.html
HELIX_SRC="$HOME/src/helix"
HELIX_REPO="https://github.com/helix-editor/helix"

usage() {
	cat <<'USAGE'
Bootstrap helix-files on a fresh macOS machine.

What it does:
  1. Installs Homebrew if missing
  2. Installs required Homebrew packages (zellij, yazi, mise, jdtls,
     erlang_ls, oh-my-posh, fzf, fd, zoxide, eza, bat, tree, git) and the
     Ghostty cask
  3. Symlinks ~/.config/{helix,zellij,yazi,mise,ghostty,oh-my-posh,zsh-helix-mode}
     -> <repo>/<name>
  4. Runs `mise install` to fetch runtimes / LSPs / formatters
  5. Builds Helix nightly from source (~/src/helix) via cargo
  6. Adds a managed block to ~/.zshrc with: mise activate, ~/.cargo/bin on
     PATH, HELIX_RUNTIME, Nord Aurora FZF colors + key bindings, zoxide
     init, oh-my-posh init, the `hx()` wrapper that sets TMUX=zellij inside
     zellij sessions (see README → "Helix transparency inside zellij"),
     and the `hs` sessionizer alias. Replaces an existing helix-files
     block if present; leaves other managed blocks alone.

Usage:
  scripts/setup.sh              actually make changes
  scripts/setup.sh --dry-run    preview without touching anything
  scripts/setup.sh -n           same as --dry-run
  scripts/setup.sh -h | --help  this message
USAGE
}

parse_dry_run_args "$@"

if [[ ! -d "$REPO_ROOT" ]]; then
	err "helix-files not found at $REPO_ROOT"
	exit 1
fi

if [[ "$(uname)" != "Darwin" ]]; then
	warn "this script targets macOS; some steps may not apply on $(uname)"
fi

dry_run_banner "$DRY_RUN"

# ─── Steps ────────────────────────────────────────────────────────────────

install_homebrew() {
	info "Homebrew"
	if has_cmd brew; then
		ok "already installed"
		return
	fi
	if $DRY_RUN; then
		would "install Homebrew from https://brew.sh"
		return
	fi
	/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
	if [[ -x /opt/homebrew/bin/brew ]]; then
		eval "$(/opt/homebrew/bin/brew shellenv)"
	fi
	ok "installed"
}

install_brew_packages() {
	info "Homebrew packages"
	if ! has_cmd brew; then
		if $DRY_RUN; then
			would "install formulas: ${BREW_FORMULAS[*]}"
			would "install casks: ${BREW_CASKS[*]}"
			return
		fi
		err "brew missing; install_homebrew() should have handled this"
		return 1
	fi

	# Some tools may already be installed outside brew (mise's own installer,
	# cargo install, direct .dmg download for casks, etc.).
	_have_outside_brew() {
		local pkg=$1 kind=$2
		if [[ $kind == formula ]]; then
			has_cmd "$pkg"
		else
			case "$pkg" in
				ghostty) [[ -d /Applications/Ghostty.app ]] ;;
				*)       false ;;
			esac
		fi
	}

	_install() {
		local pkg=$1 kind=$2 flag=${3-}
		local label=$pkg; [[ $kind == cask ]] && label="$pkg cask"

		if brew_has "$kind" "$pkg"; then
			ok "$label (already installed via brew)"
		elif _have_outside_brew "$pkg" "$kind"; then
			ok "$label (already installed outside brew)"
		elif $DRY_RUN; then
			would "install $label"
		else
			info "  installing $label"
			brew install $flag "$pkg"
		fi
	}

	for pkg in "${BREW_FORMULAS[@]}"; do _install "$pkg" formula; done
	for pkg in "${BREW_CASKS[@]}";    do _install "$pkg" cask --cask; done
	unset -f _install _have_outside_brew
}

ensure_symlink() {
	local src=$1 dst=$2 name; name=$(basename "$dst")

	# Already correctly linked → done.
	if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
		ok "$name (already linked)"
		return 0
	fi

	# Refuse to clobber a real file/dir at the destination.
	if [[ -e "$dst" && ! -L "$dst" ]]; then
		err "$dst exists and is not a symlink — move or delete it, then re-run"
		return 1
	fi

	# Either no $dst or it's a symlink pointing somewhere else — replace.
	local note=""
	if [[ -L "$dst" ]]; then
		note=" (replaced)"
		warn "$dst points to $(readlink "$dst")"
	fi

	if $DRY_RUN; then
		would "${note:+replace }${note:-create} symlink: $dst -> $src"
		return 0
	fi
	mkdir -p "$(dirname "$dst")"
	rm -f "$dst"
	ln -s "$src" "$dst"
	ok "$name -> $src$note"
}

symlink_configs() {
	info "~/.config symlinks"
	local names=(helix zellij yazi mise ghostty oh-my-posh zsh-helix-mode)
	local failures=0
	for name in "${names[@]}"; do
		if [[ ! -d "$REPO_ROOT/$name" ]]; then
			err "$REPO_ROOT/$name not found in repo"
			failures=$((failures + 1))
			continue
		fi
		ensure_symlink "$REPO_ROOT/$name" "$HOME/.config/$name" || failures=$((failures + 1))
	done
	return "$failures"
}

zshrc_block() {
	# Single-quoted heredoc keeps $(...) and $HOME literal so they expand at
	# .zshrc load time. __REPO__ is our substitution placeholder.
	local block
	block=$(cat <<'EOF'
# >>> helix-files managed block >>>
# Managed by __REPO__/scripts/setup.sh — re-run setup.sh to update.
# Remove these markers and the lines between to disable.

# Activate mise only if a previous block (e.g. dotfiles) hasn't already.
# Mise binaries (LSPs, runtimes) need to be on PATH for Helix to find them.
if [[ -z ${MISE_SHELL:-} ]] && command -v mise >/dev/null 2>&1; then
	eval "$(mise activate zsh)"
fi

# Cargo bin dir — needed for the source-built `hx` binary.
if [[ ":$PATH:" != *":$HOME/.cargo/bin:"* ]]; then
	export PATH="$HOME/.cargo/bin:$PATH"
fi

# Helix runtime files (built-from-source install lives in ~/src/helix).
# `hx` uses HELIX_RUNTIME first, then falls back to compiled-in defaults.
export HELIX_RUNTIME="$HOME/src/helix/runtime"

# fzf — Deep Nord Aurora colors and ergonomic defaults. These exports
# replace any previous FZF_* values, so the last block to define them wins.
export FZF_DEFAULT_OPTS="
  --color=bg:-1,bg+:-1,gutter:-1,fg:#D8DEE9,fg+:#ECEFF4
  --color=hl:#74BCD9,hl+:#D97757,header:#74BCD9,info:#DDB867
  --color=prompt:#74BCD9,pointer:#D97757,marker:#8DBC6E,spinner:#74BCD9
  --color=border:#4F5870
  --prompt='∼ ' --pointer='▶' --marker='✓'
  --layout='reverse' --border='rounded' --height='60%'
  --preview-window='border-rounded'
  --bind='ctrl-/:change-preview-window(down|hidden|)'"
export FZF_DEFAULT_COMMAND='fd --type f --strip-cwd-prefix --hidden --follow --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_CTRL_T_OPTS="
  --walker-skip .git,node_modules,target,.next
  --preview 'bat -n --color=always --line-range :500 {}'
  --preview-window='right:60%:border-left'"
export FZF_ALT_C_OPTS="
  --walker-skip .git,node_modules,target
  --preview 'eza -la --color=always --icons --git {} 2>/dev/null || tree -C {} | head -100'
  --preview-window='right:60%:border-left'"
export FZF_CTRL_R_OPTS="
  --preview 'echo {}' --preview-window down:3:wrap
  --bind 'ctrl-y:execute-silent(echo -n {2..} | pbcopy)+abort'
  --color header:italic
  --header 'Press CTRL-Y to copy command'"

_fzf_comprun() {
  local command=$1; shift
  if [[ "$command" == "cd" ]]; then
    fzf --preview 'eza -la --color=always --icons --git {} 2>/dev/null || tree -C {} | head -200' "$@"
  elif [[ "$command" == "export" || "$command" == "unset" ]]; then
    fzf --preview "eval 'echo \${}'" "$@"
  elif [[ "$command" == "ssh" ]]; then
    fzf --preview 'dig {}' "$@"
  else
    fzf --preview 'bat -n --color=always {} 2>/dev/null || tree -C {}' "$@"
  fi
}

# fzf shell integration (key bindings + completions). Idempotent re-source.
if command -v fzf >/dev/null 2>&1; then
	source <(fzf --zsh)
fi

# zoxide — `z <fragment>` jumps to frecent dirs. Re-running init redefines
# the same functions, so no guard needed.
if command -v zoxide >/dev/null 2>&1; then
	eval "$(zoxide init zsh)"
fi

# oh-my-posh prompt (nord-aurora theme). POSH_PID is exported by `init zsh`,
# so this is a no-op if a previous block already initialized the prompt.
if [[ -z ${POSH_PID:-} ]] && command -v oh-my-posh >/dev/null 2>&1; then
	eval "$(oh-my-posh init zsh --config "$HOME/.config/oh-my-posh/nord-aurora.omp.json")"
fi

# zsh-helix-mode — Helix-style modal line editor in zsh.
# Guarded so a previous block can win if it already loaded ZHM.
# KEYTIMEOUT=1 (10ms) makes mode-switch via Esc feel instant; the default
# of 400ms makes ZHM seem laggy or "broken" especially inside multiplexers.
# Guard on the FUNCTION existing rather than $ZHM_MODE — the plugin exports
# ZHM_MODE, so it's inherited by every child shell (including zellij panes),
# which would skip a value-based guard on init. Functions don't export, so
# this correctly detects "ZHM not yet loaded *in this shell*".
if (( ! ${+functions[__zhm_mode_normal]} )) && [[ -f "$HOME/.config/zsh-helix-mode/zsh-helix-mode.plugin.zsh" ]]; then
	export ZHM_CLIPBOARD_PIPE_CONTENT_TO="pbcopy"
	export ZHM_CLIPBOARD_READ_CONTENT_FROM="pbpaste"
	# Override ZHM cursor colour to frost1 (matches Helix / Ghostty cursor
	# colours). Shape differs per mode: \e[2 q = steady block, \e[5 q =
	# blinking beam. These must be set BEFORE sourcing — the plugin uses `:=`.
	# Placeholder is __SHAPE__ rather than %s because zsh's `${var//%s/N}`
	# parameter expansion silently fails to match `%s` (treats `%` specially
	# in patterns regardless of EXTENDED_GLOB), leaving a literal `\e[%s q`
	# in the cursor escape — invalid DECSCUSR, so the cursor shape never
	# updates per mode. Alphanumeric placeholder sidesteps the quirk.
	__zhm_cursor=$'\e[0m\e[__SHAPE__ q\e]12;#74BCD9\a'
	export ZHM_CURSOR_NORMAL=${__zhm_cursor//__SHAPE__/2}
	export ZHM_CURSOR_INSERT=${__zhm_cursor//__SHAPE__/5}
	export ZHM_CURSOR_SELECT=${__zhm_cursor//__SHAPE__/2}
	unset __zhm_cursor
	source "$HOME/.config/zsh-helix-mode/zsh-helix-mode.plugin.zsh"
	# Start each shell in normal mode. __zhm_mode_normal does the full
	# switch: keymap → hxnor, ZHM_MODE=normal, and emits the block-cursor
	# DECSCUSR escape so the visual cursor matches the mode immediately.
	__zhm_mode_normal
fi
# KEYTIMEOUT must be a plain assignment (no `export`) and live OUTSIDE the
# guarded block — otherwise zsh's terminal init resets it to the 40-cs
# default. This is the wait-for-multi-key timeout in centiseconds; 1 = 10ms
# so Esc → ZHM normal mode feels instant instead of dragging for 400ms.
KEYTIMEOUT=1

# Dynamic OSC 0 terminal title — zellij surfaces this as the pane title.
# precmd fires before each prompt: "zsh %1~" (zsh + last cwd component,
# tilde-substituted, e.g. "zsh helix-files" or "zsh ~").
# preexec fires before each command: the typed command line, so a long-
# running `npm install` shows up as "npm install" until it finishes.
# `print -P` enables prompt expansion (%1~). Helix doesn't fire zsh hooks,
# so its yazi-opener-set "hx <filename>" survives until the editor exits;
# the next prompt then redraws "zsh ...".
__hf_precmd_title() { print -Pn "\e]0;zsh %1~\a" }
__hf_preexec_title() { printf '\e]0;%s\a' "$1" }
typeset -ga precmd_functions preexec_functions
(( ${precmd_functions[(I)__hf_precmd_title]} )) || precmd_functions+=(__hf_precmd_title)
(( ${preexec_functions[(I)__hf_preexec_title]} )) || preexec_functions+=(__hf_preexec_title)

# helix's OSC 11 background-color carve-out only checks TMUX, not ZELLIJ
# (helix-tui/src/backend/termina.rs:104-105). Without faking TMUX inside a
# zellij session, helix queries the bg, zellij always answers black
# (zellij-org/zellij#3590), and helix writes that black back via OSC 11 SET
# — painting the pane opaque and defeating ghostty's transparency. Pairs
# with clipboard-provider=pasteboard in helix/config.toml so the faked
# TMUX doesn't reroute yank/paste through `tmux save-buffer`. yazi/yazi.toml
# duplicates this for the yazi → hx launch path (bash opener doesn't read
# ~/.zshrc).
# Trailing `clear` works around zellij/4893 — fragments from helix's
# alt-screen buffer leak into the pane scrollback on exit, leaving file
# content visible above the next prompt. clear wipes the visible viewport
# so you land on a clean line. Same pattern works for any TUI (yazi, less,
# htop) — add `; clear` to the call site if you hit the same artifact.
hx() {
	if [[ -n ${ZELLIJ:-} ]]; then
		TMUX=zellij command hx "$@"
	else
		command hx "$@"
	fi
	clear
}

# Helix + zellij sessionizer
alias hs="__REPO__/scripts/sessionizer.sh"

# zellij session helpers
alias zls='zellij list-sessions'              # list sessions
alias za='zellij attach'                      # attach (with -c create); usage: za <name>
alias zks='zellij kill-session'               # kill one session — usage: zks <name>
alias zka='zellij kill-all-sessions --yes'    # kill all sessions

# <<< helix-files managed block <<<
EOF
)
	printf "%s" "${block//__REPO__/$REPO_ROOT}"
}

# Install/update a managed block in $1 using the body emitted by $2.
setup_managed_block() {
	local target=$1 block_fn=$2
	local label="$(basename "$target") helix-files block"
	info "$label"

	if [[ ! -f "$target" ]]; then
		if $DRY_RUN; then
			would "create $target with helix-files block"
			return
		fi
		touch "$target"
	fi

	local new_block
	new_block=$("$block_fn")

	if grep -qF "$MARKER_START" "$target"; then
		local current_block
		current_block=$(awk -v s="$MARKER_START" -v e="$MARKER_END" '
			$0 ~ s { inside=1 }
			inside { print }
			$0 ~ e { inside=0 }
		' "$target")
		if [[ "$current_block" == "$new_block" ]]; then
			ok "already up to date"
			return
		fi

		if $DRY_RUN; then
			would "replace existing helix-files block in $target"
			return
		fi

		# BSD awk on macOS rejects embedded newlines in `-v var=val`, so we
		# pass the new block via a file and slurp it inside the END action.
		local tmp new_file
		tmp=$(mktemp)
		new_file=$(mktemp)
		printf "%s\n" "$new_block" > "$new_file"
		awk -v s="$MARKER_START" -v e="$MARKER_END" -v new_file="$new_file" '
			$0 ~ s { skip=1; next }
			$0 ~ e { skip=0; next }
			!skip  { print }
			END {
				printf "\n"
				while ((getline line < new_file) > 0) print line
			}
		' "$target" > "$tmp"
		mv "$tmp" "$target"
		rm -f "$new_file"
		ok "updated (existing block replaced)"
	else
		if $DRY_RUN; then
			would "append helix-files block to $target"
			return
		fi
		printf "\n%s\n" "$new_block" >> "$target"
		ok "added"
	fi
}

mise_install() {
	info "mise install (runtimes + LSPs + formatters)"
	if ! has_cmd mise; then
		warn "mise not on PATH; skipping"
		return
	fi
	# `mise install` reads ~/.config/mise/config.toml — only meaningful once
	# the symlink step succeeded.
	if [[ ! -L "$HOME/.config/mise" ]]; then
		warn "~/.config/mise is not a symlink yet; skipping (resolve symlink errors and re-run)"
		return
	fi
	if $DRY_RUN; then
		would "mise trust $REPO_ROOT/mise/config.toml"
		would "run 'mise install'"
		return
	fi
	# mise refuses to read a new config until it's marked trusted; do it
	# here so a fresh setup just works.
	mise trust "$REPO_ROOT/mise/config.toml" >/dev/null
	mise install
	ok "mise tools installed"
}

clone_zsh_helix_mode() {
	info "zsh-helix-mode (upstream plugin clone)"
	local target="$REPO_ROOT/zsh-helix-mode"
	if [[ -d "$target/.git" ]]; then
		ok "already cloned"
		return
	fi
	if $DRY_RUN; then
		would "git clone https://github.com/Multirious/zsh-helix-mode.git $target"
		return
	fi
	git clone https://github.com/Multirious/zsh-helix-mode.git "$target"
	ok "cloned"
}

install_helix_nightly() {
	info "Helix (nightly from source at $HELIX_SRC)"

	# In dry-run, mise hasn't actually installed rust yet, so cargo may not
	# exist on a fresh machine. Print intent and return.
	if $DRY_RUN; then
		if [[ -d "$HELIX_SRC/.git" ]]; then
			would "git -C $HELIX_SRC pull --ff-only (skipped on first install)"
		else
			would "git clone $HELIX_REPO $HELIX_SRC"
		fi
		would "cargo install --path $HELIX_SRC/helix-term --locked"
		return
	fi

	# Mise installs rust to its shims dir; if `mise activate` hasn't run for
	# this script's shell, prepend the shims explicitly.
	if ! has_cmd cargo; then
		export PATH="$HOME/.local/share/mise/shims:$HOME/.cargo/bin:$PATH"
	fi
	if ! has_cmd cargo; then
		err "cargo not found — ensure rust is installed (mise install / rustup) and re-run"
		return 1
	fi
	if ! has_cmd git; then
		err "git not found — install via brew first"
		return 1
	fi

	if [[ -d "$HELIX_SRC/.git" ]]; then
		ok "$HELIX_SRC already cloned"
	else
		mkdir -p "$(dirname "$HELIX_SRC")"
		git clone "$HELIX_REPO" "$HELIX_SRC"
		ok "cloned"
	fi

	info "  building helix-term (this can take a few minutes on a fresh build)"
	cargo install --path "$HELIX_SRC/helix-term" --locked
	ok "hx installed to ~/.cargo/bin (HELIX_RUNTIME=$HELIX_SRC/runtime via .zshrc)"
}

main() {
	install_homebrew
	install_brew_packages

	local symlink_failures=0
	symlink_configs || symlink_failures=$?

	mise_install
	install_helix_nightly
	clone_zsh_helix_mode
	setup_managed_block "$ZSHRC" zshrc_block

	echo
	if [[ $symlink_failures -gt 0 ]]; then
		err "completed with $symlink_failures symlink problem(s) above"
		err "resolve those and re-run setup.sh"
		exit 1
	fi
	if $DRY_RUN; then
		info "Dry-run complete — no changes made"
		echo "  Re-run without --dry-run to apply."
	else
		info "Done"
		echo
		echo "Next steps:"
		echo "  1. Open a new terminal tab so the new .zshrc is sourced"
		echo "  2. Try the sessionizer:  hs"
		echo "  3. Verify Helix sees LSPs:  hx --health rust"
	fi
}

main "$@"
