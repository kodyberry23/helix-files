# helix-files

A Helix-centric dotfiles bundle for macOS - editor, terminal, multiplexer, sidebar file tree, prompt, mise tool config, project sessionizer, and a Helix-mode shell binding for zsh - all coordinated under a **Deep Nord Aurora** look. Built and tested on Ghostty + zellij + zsh.

## Layout

```
helix-files/
├── ghostty/                    # Ghostty terminal: config, themes, shaders, icon
│   └── themes/nord-aurora      # Deep Nord Aurora palette (cursor + transparency in config)
├── helix/
│   ├── config.toml             # editor settings, keymaps, statusline, A-r reveal
│   ├── languages.toml          # per-language LSP + formatter overrides
│   └── themes/nord-aurora.toml # custom Deep Nord Aurora theme
├── broot/
│   └── conf.hjson              # sidebar verbs: Enter → :open, Ctrl-V → :vsplit
├── mise/
│   └── config.toml             # global mise tools: runtimes, LSPs, formatters
├── oh-my-posh/                 # prompt themes; nord-aurora.omp.json is the default
├── scripts/
│   ├── setup.sh                # bootstrap: install tools, symlink, manage .zshrc block
│   ├── update.sh               # update brew, mise, Helix nightly, zsh-helix-mode
│   ├── sessionizer.sh          # zellij project session picker (alias: `hs`)
│   ├── dispatch-to-editor.sh   # broot → editor pane (route :open / :vsplit)
│   ├── dispatch-to-sidebar.sh  # helix A-r → broot :focus <buffer>
│   └── lib/common.sh           # shared shell helpers + brew lists
├── zellij/
│   ├── config.kdl              # multiplexer config (theme inlined, keybinds, layout)
│   └── layouts/default.kdl     # 2-pane sidebar (broot) + editor (helix)
└── zsh-helix-mode/             # upstream plugin: Helix-style modal editing in zsh
```

## Installation

`scripts/setup.sh` is the single entry point. It:

1. Installs Homebrew if missing.
2. Installs the brew formulas (`zellij broot mise jdtls erlang_ls marksman oh-my-posh fzf fd zoxide eza bat tree git jq`) and the Ghostty cask.
3. Symlinks `~/.config/{helix,zellij,broot,mise,ghostty,oh-my-posh,zsh-helix-mode}` into the matching repo dirs.
4. Runs `mise install` (auto-trusting `mise/config.toml`) to fetch runtimes, LSPs, and formatters.
5. Builds **Helix nightly from source** at `~/projects/helix` via `cargo install --path helix-term --locked`.
6. Manages a single block in `~/.zshrc` (between `# >>> helix-files managed block >>>` markers) that:
   - Activates `mise` (guarded against double-init).
   - Prepends `~/.cargo/bin` to `PATH`, exports `HELIX_RUNTIME`.
   - Sets Deep Nord Aurora `FZF_DEFAULT_OPTS` plus ergonomic CTRL-T / ALT-C / CTRL-R options, defines `_fzf_comprun`, sources `fzf --zsh`.
   - Inits `zoxide` (`z` jumps to frecent dirs).
   - Inits `oh-my-posh` with the Deep Nord Aurora theme (guarded via `POSH_PID`).
   - Sources `zsh-helix-mode` with `ZHM_CURSOR_*` overrides and clipboard wiring (guarded by function existence).
   - Sets `KEYTIMEOUT=1` for snappy modal Esc.
   - Adds `precmd`/`preexec` hooks that emit OSC 0 so the zellij pane title shows `zsh <cwd>` at the prompt and switches to the running command's name while it executes (e.g. `npm install`, `git push`).
   - Defines an `hx()` wrapper that stamps a stable `hx <project>` pane title before launch.
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
ln -s "$PWD/broot"          ~/.config/broot
ln -s "$PWD/mise"           ~/.config/mise
ln -s "$PWD/ghostty"        ~/.config/ghostty
ln -s "$PWD/oh-my-posh"     ~/.config/oh-my-posh
ln -s "$PWD/zsh-helix-mode" ~/.config/zsh-helix-mode
```

### Helix nightly

Helix is intentionally _not_ a brew dependency - `setup.sh` follows the official ["Building from source"](https://docs.helix-editor.com/building-from-source.html) instructions:

```sh
git clone https://github.com/helix-editor/helix ~/projects/helix
cargo install --path ~/projects/helix/helix-term --locked
export HELIX_RUNTIME=~/projects/helix/runtime    # added to .zshrc managed block
```

`hx` lands in `~/.cargo/bin/`; `HELIX_RUNTIME` points at the matching `runtime/` for grammars and themes. Cargo comes from the rust toolchain that mise installs.

### Local Helix patches

Stock upstream Helix lacks two features this repo uses:

- **[PR #13896](https://github.com/helix-editor/helix/pull/13896)** - Unix-socket command listener. The broot file picker dispatches `:open <path>` over this socket via `scripts/helix-send.sh` so picking a file routes into the existing helix instead of spawning a fresh one.
- **[PR #13963](https://github.com/helix-editor/helix/pull/13963)** - auto-reload on external file changes. The `[editor.auto-reload]` block in `helix/config.toml` configures it. A local follow-up commit on top makes periodic reloads silent (statusline message instead of a modal prompt).

Both patches live on the `local-patches` branch of the fork at [github.com/kodyberry23/helix](https://github.com/kodyberry23/helix). `setup.sh` clones that branch directly into `~/projects/helix` and adds `upstream` as a second remote pointing at `helix-editor/helix`, so syncing from upstream is a one-liner:

```sh
cd ~/projects/helix
git fetch upstream master
git rebase upstream/master
git push --force-with-lease origin local-patches
cargo install --path helix-term --locked --force
```

`update.sh` pulls fork updates on the `local-patches` branch (so changes pushed from another machine land here) and reports whenever `upstream/master` drifts ahead, so you rebase deliberately.

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
| TOML              | `taplo`                      | mise (cargo backend)  |
| Java              | `jdtls`                      | Homebrew              |
| Erlang            | `erlang_ls`                  | Homebrew              |
| Markdown          | `marksman`                   | Homebrew              |

`jdtls`, `erlang_ls`, and `marksman` aren't in the mise registry, so they're brewed by `setup.sh`. Per-language entries in `helix/languages.toml` rely on Helix's bundled defaults for the primary LSP and only override when adding a formatter, tweaking inlay hints, or defining a new language (e.g. `text` for `.txt` / `.log` files).

Buffer auto-reload on external disk changes is handled inside helix via the `[editor.auto-reload]` block in `helix/config.toml`, courtesy of [helix-editor/helix#13963](https://github.com/helix-editor/helix/pull/13963) cherry-picked onto the local `local-patches` branch in `~/projects/helix`, with a follow-up commit that makes periodic reloads silent (statusline message, no prompt). See `helix/config.toml` for the configurable knobs.

Verify: `hx --health rust` (repeat per language).

## Helix bindings

Custom keys defined in `helix/config.toml` (on top of Helix's defaults):

| Key | Action |
|---|---|
| `space w` / `space q` / `space x` | `:w` / `:q` / `:x` (save / quit / save-quit) |
| `A-r` | reveal current buffer in the broot sidebar pane |
| `H` / `L` | goto-line-start / goto-line-end |
| `C-d` / `C-u` | half-page down / up, then center cursor |
| `jk` (insert mode) | escape to normal mode |

Plus:
- `auto-format = false` (manual `:format` only) so you don't fight a formatter you didn't invoke.
- `insecure = true` skips Helix's "trust this workspace" prompt for every new project. Removes the seatbelt for `.helix/config.toml` payloads in untrusted repos - fine if you only open projects you authored.
- `clipboard-provider = "pasteboard"` pins yank/paste to macOS pbcopy/pbpaste. Defensive: matches auto-detect today, but locks the choice if anything in the launch chain ever exports `$TMUX`.

### broot sidebar + persistent editor

The default zellij layout is a vertical split: `sidebar` (broot, 25% width, persistent) on the left, `editor` (helix, 75% width, persistent) on the right. Files routed sidebar → editor stay in helix's existing buffers/splits rather than spawning a fresh editor each time, which is the architectural fix for [zellij#4893](https://github.com/zellij-org/zellij/issues/4893) (alt-screen pollution on TUI exit): there is no TUI churn during normal use - helix and broot both stay in their alt-screens for the life of the session.

**Sidebar → editor (broot Enter / Ctrl-V):**

- `Enter` on a file → `scripts/dispatch-to-editor.sh open <path>` sends `:open <path>` to the running helix over its Unix socket (helix-editor/helix PR #13896, in `local-patches`), then resolves the editor pane by its layout name and shifts zellij focus there so the cursor follows the file.
- `Ctrl-V` on a file → same dispatcher with `vsplit` → `:vsplit <path>` over the socket.
- If the socket is missing (helix not running, or stock helix without PR #13896), the dispatcher falls back to `zellij action new-pane --direction right --name editor -- hx <path>`. `new-pane` focuses by default, so focus still lands correctly.

**Editor → sidebar (helix `A-r`):**

broot is started with `--listen $HOME/.cache/broot-${ZELLIJ_SESSION_NAME}.sock` per session. Helix's `A-r` binding shells out to `scripts/dispatch-to-sidebar.sh '%{buffer_name}'`, which calls `broot --send $sock --cmd ':focus <path>'`. broot scrolls/expands to the current buffer's location - helix retains the cursor.

**Why named panes:** zellij's pane `name` (set in `default.kdl` via `pane name="sidebar"`/`pane name="editor"`) is surfaced as the TITLE column by `list-panes` and is stable across resizes and tab moves. The dispatcher resolves by name → id once per invocation, avoiding the fragility of OSC-0 title scraping or `focus-next-pane` heuristics.

**Shell access:** the sidebar/editor split is dedicated. Spawn a shell in a new pane via zellij's pane mode (`Ctrl-p n`) or a floating pane (`Ctrl-p w`).

## Sessionizer (`hs`)

`scripts/sessionizer.sh` creates/attaches a zellij session named after a project directory. New sessions open the default layout - broot sidebar on the left, helix editor on the right.

```sh
hs              # fzf-pick a project from ~/projects + zoxide frecent dirs
hs ~/some/path  # skip the picker
```

How it works:

- Picks from `fd -d 1 ~/projects` and zoxide's frecent dirs (deduped).
- Session name = sanitized basename (alphanumerics + `-` / `_`).
- New session: zellij applies the `default` layout, which starts broot in the named `sidebar` pane (with `--listen` on a per-session socket) and helix in the named `editor` pane.
- Already inside zellij: refuses with a hint to detach first (Ctrl-q) - zellij has no in-place "switch session" action, and detach + re-attach is fast since sessions persist on disk (`session_serialization = true`).
- Adds the path to zoxide for future frecency-ranking.

## zellij

The previous tmux setup was replaced with zellij to get **proper 4-edge active pane borders** without tmux's shared-border corner spillover. `zellij/config.kdl` keeps zellij's mode-based defaults and overlays the direct-key shortcuts that mirror the old tmux setup.

**Direct (no mode prefix):**

| Key | Action |
|---|---|
| `Alt h` / `Alt j` / `Alt k` / `Alt l` | move pane focus (zellij default - kept) |
| `Alt [` / `Alt ]` | previous / next tab |
| `Alt 1` … `Alt 9` | jump to tab N |
| `Alt t` / `Alt w` | new tab / close tab |
| `Alt f` | toggle pane fullscreen |
| `Alt z` | toggle pane frames on/off (handy when copying with the mouse) |
| `Alt =` / `Alt -` | resize active pane (zellij default - kept) |
| `Ctrl q` | **detach** (overrides zellij's default Quit binding) |
| `Alt q` | quit zellij (the destructive form, kept addressable) |

**Mode entry (zellij default - kept):**

| Key | Mode |
|---|---|
| `Ctrl p` | pane (h/j/k/l focus, n/d/r split, x close, f fullscreen, c rename, w toggle floating) |
| `Ctrl t` | tab (1-9 jump, n new, x close, h/l prev/next, r rename, b break-out) |
| `Ctrl n` | resize (h/j/k/l increase, H/J/K/L decrease, =/+ / - shrink/grow) |
| `Ctrl s` | scroll / search (vim keys, `s` enter search, `e` edit scrollback) |
| `Ctrl o` | session (d detach, w workspace, c new client) |
| `Ctrl g` | locked (no zellij keybinds intercepted - useful for nested-zellij or apps that conflict) |

**Shell aliases for zellij session control:**

| Alias | Command |
|---|---|
| `zls` | `zellij list-sessions` |
| `za` | `zellij attach` (or `za <name>` / `za -c <name>`) |
| `zks <name>` | `zellij kill-session <name>` |
| `zka` | `zellij kill-all-sessions --yes` |

**Why zellij over tmux:** tmux's pane borders are *shared* between adjacent panes - the character at each junction is part of multiple panes' borders, so the active-pane accent always spills 1 cell into neighbours. There's no native option to avoid it (tmux issues #2540, #1786 - both open with no upstream fix). Zellij draws each pane's border independently, so all 4 edges of the active pane carry the accent without spillover. **Tradeoff:** zellij has chronic resize-after-startup bugs (zellij issues #2799, #3675, #3818) - if a pane goes blank or stops accepting input after resizing the Ghostty window, detach (`Ctrl-q`) and reattach (`za <name>`).

**On startup tips:** `show_startup_tips false` and `show_release_notes false` suppress zellij's first-run / version-bump info screens. The sessionizer always invokes zellij with a session name, so the welcome/session-manager screen never appears in normal use.

## Theming - Deep Nord Aurora

A darker, more saturated take on the canonical [Nord palette](https://www.nordtheme.com/docs/colors-and-palettes). Backgrounds drop into ink-black with a blue undertone; frosts and auroras gain saturation.

| Group        | Hex values                                                                  |
|--------------|-----------------------------------------------------------------------------|
| Polar Night  | `#1A1F28`, `#232934`, `#2C333E`, `#4F5870`                                  |
| Snow Storm   | `#D8DEE9`, `#E5E9F0`, `#ECEFF4`                                             |
| Frost        | `#6FBAB7`, `#74BCD9`, `#5F8FBF`, `#426F9E`                                  |
| Aurora       | `#D04E5C`, `#D97757`, `#DDB867`, `#8DBC6E`, `#B97AB6`                       |

Where each tool's theme lives:

- **Helix** - `helix/themes/nord-aurora.toml` (`theme = "nord-aurora"` in `config.toml`).
- **Ghostty** - `ghostty/themes/nord-aurora` palette + `background-opacity = 0.92`, `background-blur = 20`. `shell-integration-features = no-cursor` so apps (zsh-helix-mode, helix) drive cursor shape.
- **zellij** - inline `themes { deep-nord-aurora { … } }` block at the bottom of `zellij/config.kdl`. (Inline rather than `zellij/themes/*.kdl` because zellij 0.44.0 silently ignored external theme files - fixed in 0.44.1, but inlining is more robust against future regressions.)
- **oh-my-posh** - `oh-my-posh/nord-aurora.omp.json`.
- **broot** - uses broot's default skin (no theme override yet - `broot/skins/` would be the right place if/when one is wanted).
- **fzf** - `FZF_DEFAULT_OPTS` exports in the `.zshrc` managed block.

Cursor colour is unified to **`#74BCD9`** (Frost-cyan) across Helix, ZHM, Ghostty, and oh-my-posh prompts; mode is shown by *shape* (block / bar / underline) rather than colour.

## zsh-helix-mode

The `zsh-helix-mode/` directory is a clone of [Multirious/zsh-helix-mode](https://github.com/Multirious/zsh-helix-mode). `setup.sh` symlinks it to `~/.config/zsh-helix-mode` and the managed block sources it for you:

- Starts each shell in **normal mode** (plugin's default is insert) by calling `__zhm_mode_normal` after sourcing.
- Source guard checks for the function `__zhm_mode_normal` rather than `$ZHM_MODE` - that env var is exported by the plugin and would inherit into child shells (notably zellij panes), incorrectly skipping the source. Function defs don't inherit, so the check is per-shell-instance.
- `KEYTIMEOUT=1` (10 ms) outside the guarded block so Esc → normal-mode is instant. Must be a plain assignment (no `export`) - the `export` form gets reset by zsh's terminal init.
- `ZHM_CLIPBOARD_PIPE_CONTENT_TO=pbcopy` / `ZHM_CLIPBOARD_READ_CONTENT_FROM=pbpaste` for clipboard integration.
- `ZHM_CURSOR_*` overrides so the prompt cursor colour matches Helix.

`update.sh` keeps the checkout current via `git pull --ff-only`.

## Notes

- macOS only. The zellij `copy_command` is `pbcopy`. Adjust for Linux.
- The `.zshrc` block is designed to coexist with another managed block (e.g. an existing `dotfiles managed block`) - guards prevent double-init for mise / oh-my-posh / zsh-helix-mode.
- Setup auto-trusts `mise/config.toml` (`mise trust`) - without this, `mise install` errors on first run with an unfamiliar config.
- Sidebar broot must be running with `--listen` (the layout handles this) for helix's `A-r` reveal to work. If you spawn broot in a side pane manually, it won't accept `--send` commands.
