# helix-files

A Helix-centric dotfiles bundle for macOS — editor, terminal, multiplexer, file manager, prompt, mise tool config, project sessionizer, and a Helix-mode shell binding for zsh — all coordinated under a **Nord Aurora** look. Built and tested on Ghostty + tmux + zsh.

## Layout

```
helix-files/
├── ghostty/                    # Ghostty terminal: config, themes, shaders, icon
│   └── themes/nord-aurora      # Nord Aurora palette (cursor + transparency in config)
├── helix/
│   ├── config.toml             # editor settings, keymaps, statusline, yazi pickers
│   ├── languages.toml          # per-language LSP + formatter overrides
│   └── themes/nord-aurora.toml # custom Nord Aurora theme
├── mise/
│   └── config.toml             # global mise tools: runtimes, LSPs, formatters
├── oh-my-posh/                 # prompt themes; nord-aurora.omp.json is the default
├── scripts/
│   ├── setup.sh                # bootstrap: install tools, symlink, manage .zshrc block
│   ├── update.sh               # update brew, mise, Helix nightly, zsh-helix-mode
│   ├── sessionizer.sh          # tmux project session picker (alias: `hs`)
│   ├── yazi-pick.sh            # yazi-as-helix-picker (used by space-e / C-v)
│   └── lib/common.sh           # shared shell helpers + brew lists
├── tmux/
│   └── tmux.conf               # zellij-style modal pane sizing, bottom Nord status
├── yazi/
│   ├── yazi.toml               # mgr layout, opener rules
│   ├── keymap.toml             # vim-style navigation
│   └── theme.toml              # Nord Aurora theme
└── zsh-helix-mode/             # upstream plugin: Helix-style modal editing in zsh
```

## Installation

`scripts/setup.sh` is the single entry point. It:

1. Installs Homebrew if missing.
2. Installs the brew formulas (`tmux yazi mise jdtls erlang_ls oh-my-posh fzf fd zoxide eza bat tree git`) and the Ghostty cask.
3. Symlinks `~/.config/{helix,tmux,yazi,mise,ghostty,oh-my-posh,zsh-helix-mode}` into the matching repo dirs.
4. Runs `mise install` (auto-trusting `mise/config.toml`) to fetch runtimes, LSPs, and formatters.
5. Builds **Helix nightly from source** at `~/src/helix` via `cargo install --path helix-term --locked`.
6. Manages a single block in `~/.zshrc` (between `# >>> helix-files managed block >>>` markers) that:
   - Activates `mise` (guarded against double-init).
   - Prepends `~/.cargo/bin` to `PATH`, exports `HELIX_RUNTIME`.
   - Sets Nord-Aurora `FZF_DEFAULT_OPTS` plus ergonomic CTRL-T / ALT-C / CTRL-R options, defines `_fzf_comprun`, sources `fzf --zsh`.
   - Inits `zoxide` (`z` jumps to frecent dirs).
   - Inits `oh-my-posh` with the Nord Aurora theme (guarded via `POSH_PID`).
   - Sources `zsh-helix-mode` with `ZHM_CURSOR_*` overrides and clipboard wiring (guarded by function existence).
   - Sets `KEYTIMEOUT=1` for snappy modal Esc.
   - Aliases `hs` to the sessionizer; `tls`/`ta`/`tks`/`tka` for tmux session control.

Every step is idempotent.

```sh
./scripts/setup.sh --dry-run    # preview every action
./scripts/setup.sh              # apply
```

For any pre-existing non-symlink at `~/.config/<tool>`, the script reports an error rather than clobbering. Resolve manually and re-run.

If you'd rather skip the script and symlink manually:

```sh
ln -s "$PWD/helix"          ~/.config/helix
ln -s "$PWD/tmux"           ~/.config/tmux
ln -s "$PWD/yazi"           ~/.config/yazi
ln -s "$PWD/mise"           ~/.config/mise
ln -s "$PWD/ghostty"        ~/.config/ghostty
ln -s "$PWD/oh-my-posh"     ~/.config/oh-my-posh
ln -s "$PWD/zsh-helix-mode" ~/.config/zsh-helix-mode
```

### Helix nightly

Helix is intentionally _not_ a brew dependency — `setup.sh` follows the official ["Building from source"](https://docs.helix-editor.com/building-from-source.html) instructions:

```sh
git clone https://github.com/helix-editor/helix ~/src/helix
cargo install --path ~/src/helix/helix-term --locked
export HELIX_RUNTIME=~/src/helix/runtime    # added to .zshrc managed block
```

`hx` lands in `~/.cargo/bin/`; `HELIX_RUNTIME` points at the matching `runtime/` for grammars and themes. Cargo comes from the rust toolchain that mise installs.

## Updating

`scripts/update.sh` updates everything `setup.sh` installed. It does **not** run `brew update` on Homebrew itself (`HOMEBREW_NO_AUTO_UPDATE=1` is exported before each `brew upgrade`).

```sh
./scripts/update.sh --dry-run
./scripts/update.sh
```

Order: brew packages → mise tools → Helix nightly (rebuilt only if HEAD moved) → zsh-helix-mode.

## Language servers

`mise/config.toml` declares the runtimes (Node, Rust, Java 21, Elixir, Erlang) and the LSPs / formatters mise can install:

| Language          | LSP binary                   | Source                |
|-------------------|------------------------------|-----------------------|
| Rust              | `rust-analyzer`              | mise (aqua)           |
| TypeScript / JS   | `typescript-language-server` | mise (npm backend)    |
| Elixir            | `elixir-ls`                  | mise (asdf plugin)    |
| _all (auto-reload)_ | `fs_watcher_lsp`           | mise (cargo backend)  |
| Java              | `jdtls`                      | Homebrew              |
| Erlang            | `erlang_ls`                  | Homebrew              |

`jdtls` and `erlang_ls` aren't in the mise registry, so they're brewed by `setup.sh`. Helix's `language-servers` key replaces (rather than extends) the default list, so each `[[language]]` entry in `helix/languages.toml` re-declares its primary LSP alongside [`fs_watcher_lsp`](https://codeberg.org/Zentropivity/fs_watcher_lsp), which auto-reloads buffers when files change on disk.

Verify: `hx --health rust` (repeat per language).

## Helix bindings

Custom keys defined in `helix/config.toml` (on top of Helix's defaults):

| Key | Action |
|---|---|
| `space w` / `space q` / `space x` | `:w` / `:q` / `:x` (save / quit / save-quit) |
| `space e` | open yazi as a file picker (Enter → current view; `Ctrl-V` *inside yazi* → vertical split) |
| `H` / `L` | goto-line-start / goto-line-end |
| `C-d` / `C-u` | half-page down / up, then center cursor |
| `jk` (insert mode) | escape to normal mode |

Plus:
- `auto-format = false` (manual `:format` only) so you don't fight a formatter you didn't invoke.
- `insecure = true` skips Helix's "trust this workspace" prompt for every new project. Removes the seatbelt for `.helix/config.toml` payloads in untrusted repos — fine if you only open projects you authored.

### yazi as file picker

`scripts/yazi-pick.sh` wraps yazi for use as a file picker from inside a running Helix instance. **Single entry point**: press `space e` in helix to launch yazi. Inside yazi:

- `Enter` (default) → picked file opens in the **current view** in helix.
- `Ctrl-V` → picked file opens in a **vertical split** in helix.
- `q` / `Esc` → cancel; helix stays on the buffer you were on.

**How the vsplit handoff works:** yazi can't natively communicate "use vsplit" back through `--chooser-file`. The yazi keymap binds `Ctrl-V` to a `shell` action that writes `VSPLIT:<path>` to a marker file (`$YAZI_PICK_MARKER` exported by the wrapper) and then quits yazi. The wrapper reads either the chooser-file (Enter case) or the marker (Ctrl-V case) and dispatches accordingly. Helix's keybind chain runs both `:open` and `:vsplit` with mode-aware fallbacks — only the matching command is non-no-op.

**Why no tmux popup:** yazi runs inline (not in a `display-popup`) so tmux's regular pane emulator answers yazi's DA1 startup query instantly. Popups don't, which causes a visible 1-second delay — see [yazi issue #2266](https://github.com/sxyazi/yazi/issues/2266). The wrapper writes the picked path to `--chooser-file`, which short-circuits yazi's `[opener]` rules so the existing `hx %s` opener doesn't fire (no nested helix instance).

## Sessionizer (`hs`)

`scripts/sessionizer.sh` creates/attaches a tmux session named after a project directory and launches yazi inside it (yazi → pick a file → `hx <file>` via yazi's `[opener]`).

```sh
hs              # fzf-pick a project from ~/projects + zoxide frecent dirs
hs ~/some/path  # skip the picker
```

How it works:

- Picks from `fd -d 1 ~/projects` and zoxide's frecent dirs (deduped).
- Session name = sanitized basename (tmux disallows `.` and `:`).
- New session: spawns `yazi <path> ; exec $SHELL -i` directly — yazi appears immediately (no zshrc preamble flash); when you quit yazi an interactive shell takes over the pane.
- Already inside tmux → `switch-client`; otherwise → `attach`.
- Adds the path to zoxide for future frecency-ranking.

## tmux

Custom bindings in `tmux/tmux.conf` (defaults still apply except where overridden):

**Prefixes:** `C-a` (primary) and `C-p` (secondary, mirrors zellij's pane-mode entry).

**Direct (no prefix needed):**

| Key | Action |
|---|---|
| `M-h` / `M-j` / `M-k` / `M-l` | move pane focus |
| `M-,` / `M-.` | previous / next window (avoids `M-[` which conflicts with CSI escape sequences) |
| `M-1` … `M-9` | jump to window N |
| `M-t` / `M-w` | new window / kill window (with confirm) |
| `M-f` | toggle pane zoom |
| `C-q` | detach |
| `M-q` | kill session (with confirm) |
| `C-s` | enter copy mode (vi keys + `d`/`u` half-page; `C-c` jump to bottom + exit) |
| `C-n` | enter resize mode (see below); ignored when Helix is the focused pane |

**Resize mode** (zellij-style modal pane sizing): `C-n` flips into a key-table where `h/j/k/l` resize the active pane by 5 cells (stay in mode for repeated presses), `Esc`/`q` exits, `C-n` toggles back out. Helix is detected via `pane_current_command` so `C-n` passes through to Helix when it's foreground (Helix uses `Ctrl-N` for `move_line_down`).

**After prefix:**

| Key | Action |
|---|---|
| `h/j/k/l` | pane focus |
| `H/J/K/L` | resize (repeatable for 500ms) |
| `\|` / `-` | split horizontal / vertical |
| `n/d/r` | new pane / split-down / split-right (zellij-style) |
| `x/f/c` | kill pane / fullscreen toggle / rename window |
| `R` | reload tmux config |
| `v` | enter copy mode |

**Shell aliases for tmux session control:**

| Alias | Command |
|---|---|
| `tls` | `tmux ls` |
| `ta` | `tmux attach` (or `ta -t name`) |
| `tks <name>` | `tmux kill-session -t <name>` |
| `tka` | `tmux kill-server` (kill **all** sessions) |

**Visual:** status bar at the **bottom**, slightly recessed shade (`#252A33`), Nord Aurora text segments (no filled-tab badges); `RESIZE` and `PREFIX` indicators light up when active. Double-line pane borders (Frost-cyan when active). Pane-border-status row shows pane index • current command • cwd when relevant. Cell height bumped 12% so border + content have visual breathing room.

**Terminal-features**: `cstyle` and `ccolour` declared for `xterm-ghostty` / `xterm-256color` so `zsh-helix-mode`'s cursor-shape / OSC-12 cursor-color escape sequences pass through tmux. `extended-keys always` so Shift+Enter and similar modified-key sequences reach apps inside tmux (notably Claude Code). `allow-passthrough on` + `update-environment TERM/TERM_PROGRAM` so yazi can detect Ghostty and render images via the kitty unicode placeholder protocol.

## Theming — Nord Aurora

[Canonical Nord palette](https://www.nordtheme.com/docs/colors-and-palettes) with Aurora accents:

| Group        | Hex values                                                                  |
|--------------|-----------------------------------------------------------------------------|
| Polar Night  | `#2E3440`, `#3B4252`, `#434C5E`, `#4C566A`                                  |
| Snow Storm   | `#D8DEE9`, `#E5E9F0`, `#ECEFF4`                                             |
| Frost        | `#8FBCBB`, `#88C0D0`, `#81A1C1`, `#5E81AC`                                  |
| Aurora       | `#BF616A`, `#D08770`, `#EBCB8B`, `#A3BE8C`, `#B48EAD`                       |

Where each tool's theme lives:

- **Helix** — `helix/themes/nord-aurora.toml` (`theme = "nord-aurora"` in `config.toml`).
- **Ghostty** — `ghostty/themes/nord-aurora` palette + `background-opacity = 0.92`, `background-blur = 20`. `shell-integration-features = no-cursor` so apps (zsh-helix-mode, helix) drive cursor shape.
- **tmux** — inline in `tmux/tmux.conf`.
- **oh-my-posh** — `oh-my-posh/nord-aurora.omp.json`.
- **Yazi** — `yazi/theme.toml`.
- **fzf** — `FZF_DEFAULT_OPTS` exports in the `.zshrc` managed block.

Cursor colour is unified to **`#88C0D0`** (Frost-cyan) across Helix, ZHM, and Ghostty; mode is shown by *shape* (block / bar / underline) rather than colour.

## zsh-helix-mode

The `zsh-helix-mode/` directory is a clone of [Multirious/zsh-helix-mode](https://github.com/Multirious/zsh-helix-mode). `setup.sh` symlinks it to `~/.config/zsh-helix-mode` and the managed block sources it for you:

- Starts each shell in **normal mode** (plugin's default is insert) by calling `__zhm_mode_normal` after sourcing.
- Source guard checks for the function `__zhm_mode_normal` rather than `$ZHM_MODE` — that env var is exported by the plugin and would inherit into child shells (notably tmux panes), incorrectly skipping the source. Function defs don't inherit, so the check is per-shell-instance.
- `KEYTIMEOUT=1` (10 ms) outside the guarded block so Esc → normal-mode is instant. Must be a plain assignment (no `export`) — the `export` form gets reset by zsh's terminal init.
- `ZHM_CLIPBOARD_PIPE_CONTENT_TO=pbcopy` / `ZHM_CLIPBOARD_READ_CONTENT_FROM=pbpaste` for clipboard integration.
- `ZHM_CURSOR_*` overrides so the prompt cursor colour matches Helix.

`update.sh` keeps the checkout current via `git pull --ff-only`.

## Notes

- macOS only. tmux's copy-pipe uses `pbcopy`; Yazi opener rules use `open` and `open -R`. Adjust for Linux.
- The `.zshrc` block is designed to coexist with another managed block (e.g. an existing `dotfiles managed block`) — guards prevent double-init for mise / oh-my-posh / zsh-helix-mode.
- Setup auto-trusts `mise/config.toml` (`mise trust`) — without this, `mise install` errors on first run with an unfamiliar config.
- Helix `:vsplit ""` (yazi cancel in vsplit mode) errors silently in the status bar with no split created — this is by design via the wrapper's mode-aware cancel path.
