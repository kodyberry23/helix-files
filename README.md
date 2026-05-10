# helix-files

A Helix-centric dotfiles bundle for macOS — editor, terminal, multiplexer, file manager, prompt, mise tool config, project sessionizer, and a Helix-mode shell binding for zsh — all coordinated under a **Deep Nord Aurora** look. Built and tested on Ghostty + zellij + zsh.

## Layout

```
helix-files/
├── ghostty/                    # Ghostty terminal: config, themes, shaders, icon
│   └── themes/nord-aurora      # Deep Nord Aurora palette (cursor + transparency in config)
├── helix/
│   ├── config.toml             # editor settings, keymaps, statusline, yazi pickers
│   ├── languages.toml          # per-language LSP + formatter overrides
│   └── themes/nord-aurora.toml # custom Deep Nord Aurora theme
├── mise/
│   └── config.toml             # global mise tools: runtimes, LSPs, formatters
├── oh-my-posh/                 # prompt themes; nord-aurora.omp.json is the default
├── scripts/
│   ├── setup.sh                # bootstrap: install tools, symlink, manage .zshrc block
│   ├── update.sh               # update brew, mise, Helix nightly, zsh-helix-mode
│   ├── sessionizer.sh          # zellij project session picker (alias: `hs`)
│   ├── yazi-pick.sh            # yazi-as-helix-picker (used by space-e / C-v)
│   └── lib/common.sh           # shared shell helpers + brew lists
├── yazi/
│   ├── yazi.toml               # mgr layout, opener rules
│   ├── keymap.toml             # vim-style navigation
│   └── theme.toml              # Deep Nord Aurora theme
├── zellij/
│   ├── config.kdl              # multiplexer config (theme, keybinds, layout)
│   ├── themes/deep-nord-aurora.kdl
│   └── layouts/default.kdl     # auto-yazi on new-session start
└── zsh-helix-mode/             # upstream plugin: Helix-style modal editing in zsh
```

## Installation

`scripts/setup.sh` is the single entry point. It:

1. Installs Homebrew if missing.
2. Installs the brew formulas (`zellij yazi mise jdtls erlang_ls oh-my-posh fzf fd zoxide eza bat tree git`) and the Ghostty cask.
3. Symlinks `~/.config/{helix,zellij,yazi,mise,ghostty,oh-my-posh,zsh-helix-mode}` into the matching repo dirs.
4. Runs `mise install` (auto-trusting `mise/config.toml`) to fetch runtimes, LSPs, and formatters.
5. Builds **Helix nightly from source** at `~/src/helix` via `cargo install --path helix-term --locked`.
6. Manages a single block in `~/.zshrc` (between `# >>> helix-files managed block >>>` markers) that:
   - Activates `mise` (guarded against double-init).
   - Prepends `~/.cargo/bin` to `PATH`, exports `HELIX_RUNTIME`.
   - Sets Deep Nord Aurora `FZF_DEFAULT_OPTS` plus ergonomic CTRL-T / ALT-C / CTRL-R options, defines `_fzf_comprun`, sources `fzf --zsh`.
   - Inits `zoxide` (`z` jumps to frecent dirs).
   - Inits `oh-my-posh` with the Deep Nord Aurora theme (guarded via `POSH_PID`).
   - Sources `zsh-helix-mode` with `ZHM_CURSOR_*` overrides and clipboard wiring (guarded by function existence).
   - Sets `KEYTIMEOUT=1` for snappy modal Esc.
   - Aliases `hs` to the sessionizer; `zls`/`za`/`zks`/`zka` for zellij session control.

Every step is idempotent.

```sh
./scripts/setup.sh --dry-run    # preview every action
./scripts/setup.sh              # apply
```

For any pre-existing non-symlink at `~/.config/<tool>`, the script reports an error rather than clobbering. Resolve manually and re-run.

If you'd rather skip the script and symlink manually:

```sh
ln -s "$PWD/helix"          ~/.config/helix
ln -s "$PWD/zellij"         ~/.config/zellij
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

**How the vsplit handoff works:** yazi can't natively communicate "use vsplit" back through `--chooser-file`. The yazi keymap binds `Ctrl-V` to a Lua plugin that writes `VSPLIT:<path>` to a marker file (`$YAZI_PICK_MARKER` exported by the wrapper) and then quits yazi. The wrapper reads either the chooser-file (Enter case) or the marker (Ctrl-V case) and dispatches accordingly. Helix's keybind chain runs both `:open` and `:vsplit` with mode-aware fallbacks — only the matching command is non-no-op.

**Suppressing the leader-menu flash:** before yazi enters alt-screen, the wrapper writes CSI 2J + CSI H to the main screen so the restored frame on yazi exit is blank instead of "helix-with-which-key-popup." Helix's `:redraw` is async (callback-queued) and doesn't paint synchronously inside a keybind chain, so this main-screen scrub is what actually eliminates the flicker.

## Sessionizer (`hs`)

`scripts/sessionizer.sh` creates/attaches a zellij session named after a project directory. New sessions auto-launch yazi via `zellij/layouts/default.kdl` (yazi → pick a file → `hx <file>` via yazi's `[opener]`).

```sh
hs              # fzf-pick a project from ~/projects + zoxide frecent dirs
hs ~/some/path  # skip the picker
```

How it works:

- Picks from `fd -d 1 ~/projects` and zoxide's frecent dirs (deduped).
- Session name = sanitized basename (alphanumerics + `-` / `_`).
- New session: zellij applies the `default` layout, which spawns `yazi ; exec $SHELL -i` — yazi appears immediately; when you quit yazi an interactive shell takes over the pane.
- Already inside zellij: refuses with a hint to detach first (Ctrl-q) — zellij has no in-place "switch session" action, and detach + re-attach is fast since sessions persist on disk (`session_serialization = true`).
- Adds the path to zoxide for future frecency-ranking.

## zellij

The previous tmux setup was replaced with zellij to get **proper 4-edge active pane borders** without tmux's shared-border corner spillover. `zellij/config.kdl` keeps zellij's mode-based defaults and overlays the direct-key shortcuts that mirror the old tmux setup.

**Direct (no mode prefix):**

| Key | Action |
|---|---|
| `Alt h` / `Alt j` / `Alt k` / `Alt l` | move pane focus (zellij default — kept) |
| `Alt ,` / `Alt .` | previous / next tab |
| `Alt 1` … `Alt 9` | jump to tab N |
| `Alt t` / `Alt w` | new tab / close tab |
| `Alt f` | toggle pane fullscreen |
| `Alt =` / `Alt -` | resize active pane (zellij default — kept) |
| `Ctrl q` | **detach** (overrides zellij's default Quit binding) |

**Mode entry (zellij default — kept):**

| Key | Mode |
|---|---|
| `Ctrl p` | pane (h/j/k/l focus, n/d/r split, x close, f fullscreen, c rename, w toggle floating) |
| `Ctrl t` | tab (1-9 jump, n new, x close, h/l prev/next, r rename, b break-out) |
| `Ctrl n` | resize (h/j/k/l increase, H/J/K/L decrease, =/+ / - shrink/grow) |
| `Ctrl s` | scroll / search (vim keys, `s` enter search, `e` edit scrollback) |
| `Ctrl o` | session (d detach, w workspace, c new client) |
| `Ctrl g` | locked (no zellij keybinds intercepted — useful for nested-zellij or apps that conflict) |

**Shell aliases for zellij session control:**

| Alias | Command |
|---|---|
| `zls` | `zellij list-sessions` |
| `za` | `zellij attach` (or `za <name>` / `za -c <name>`) |
| `zks <name>` | `zellij kill-session <name>` |
| `zka` | `zellij kill-all-sessions --yes` |

**Why zellij over tmux:** tmux's pane borders are *shared* between adjacent panes — the character at each junction is part of multiple panes' borders, so the active-pane accent always spills 1 cell into neighbours. There's no native option to avoid it (tmux issues #2540, #1786 — both open with no upstream fix). Zellij draws each pane's border independently, so all 4 edges of the active pane carry the accent without spillover. **Tradeoff:** zellij has chronic resize-after-startup bugs (zellij issues #2799, #3675, #3818) — if a pane goes blank or stops accepting input after resizing the Ghostty window, detach (`Ctrl-q`) and reattach (`za <name>`).

**On startup tips:** `show_startup_tips false` and `show_release_notes false` suppress zellij's first-run / version-bump info screens. The sessionizer always invokes zellij with a session name, so the welcome/session-manager screen never appears in normal use.

## Theming — Deep Nord Aurora

A darker, more saturated take on the canonical [Nord palette](https://www.nordtheme.com/docs/colors-and-palettes). Backgrounds drop into ink-black with a blue undertone; frosts and auroras gain saturation.

| Group        | Hex values                                                                  |
|--------------|-----------------------------------------------------------------------------|
| Polar Night  | `#1A1F28`, `#232934`, `#2C333E`, `#4F5870`                                  |
| Snow Storm   | `#D8DEE9`, `#E5E9F0`, `#ECEFF4`                                             |
| Frost        | `#6FBAB7`, `#74BCD9`, `#5F8FBF`, `#426F9E`                                  |
| Aurora       | `#D04E5C`, `#D97757`, `#DDB867`, `#8DBC6E`, `#B97AB6`                       |

Where each tool's theme lives:

- **Helix** — `helix/themes/nord-aurora.toml` (`theme = "nord-aurora"` in `config.toml`).
- **Ghostty** — `ghostty/themes/nord-aurora` palette + `background-opacity = 0.92`, `background-blur = 20`. `shell-integration-features = no-cursor` so apps (zsh-helix-mode, helix) drive cursor shape.
- **zellij** — `zellij/themes/deep-nord-aurora.kdl`.
- **oh-my-posh** — `oh-my-posh/nord-aurora.omp.json`.
- **Yazi** — `yazi/theme.toml`.
- **fzf** — `FZF_DEFAULT_OPTS` exports in the `.zshrc` managed block.

Cursor colour is unified to **`#74BCD9`** (Frost-cyan) across Helix, ZHM, Ghostty, and oh-my-posh prompts; mode is shown by *shape* (block / bar / underline) rather than colour.

## zsh-helix-mode

The `zsh-helix-mode/` directory is a clone of [Multirious/zsh-helix-mode](https://github.com/Multirious/zsh-helix-mode). `setup.sh` symlinks it to `~/.config/zsh-helix-mode` and the managed block sources it for you:

- Starts each shell in **normal mode** (plugin's default is insert) by calling `__zhm_mode_normal` after sourcing.
- Source guard checks for the function `__zhm_mode_normal` rather than `$ZHM_MODE` — that env var is exported by the plugin and would inherit into child shells (notably zellij panes), incorrectly skipping the source. Function defs don't inherit, so the check is per-shell-instance.
- `KEYTIMEOUT=1` (10 ms) outside the guarded block so Esc → normal-mode is instant. Must be a plain assignment (no `export`) — the `export` form gets reset by zsh's terminal init.
- `ZHM_CLIPBOARD_PIPE_CONTENT_TO=pbcopy` / `ZHM_CLIPBOARD_READ_CONTENT_FROM=pbpaste` for clipboard integration.
- `ZHM_CURSOR_*` overrides so the prompt cursor colour matches Helix.

`update.sh` keeps the checkout current via `git pull --ff-only`.

## Notes

- macOS only. Yazi opener rules use `open` and `open -R`; the zellij `copy_command` is `pbcopy`. Adjust for Linux.
- The `.zshrc` block is designed to coexist with another managed block (e.g. an existing `dotfiles managed block`) — guards prevent double-init for mise / oh-my-posh / zsh-helix-mode.
- Setup auto-trusts `mise/config.toml` (`mise trust`) — without this, `mise install` errors on first run with an unfamiliar config.
- Helix `:vsplit ""` (yazi cancel in vsplit mode) errors silently in the status bar with no split created — this is by design via the wrapper's mode-aware cancel path.
