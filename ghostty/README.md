# Ghostty Configuration

Personal configuration for [Ghostty](https://ghostty.org/), a fast, feature-rich, and GPU-accelerated terminal emulator written in Zig.

## Features

- **Rose Pine theme** integration with 88% opacity and blur
- **Custom keybindings** inspired by tmux (using `super+b` prefix)
- **Split management** for terminal panes
- **Tab navigation** with quick access keys
- **Custom shaders** for retro/CRT aesthetic (disabled by default)
- **Transparent titlebar** for native macOS look

## Theme

Using the Rose Pine color scheme with:
- Background opacity: 88%
- Background blur radius: 25px
- Maximized window on startup

Alternative theme available: Tokyo Night

## Font

**JetBrainsMonoNL Nerd Font** at 14pt
- Nerd Font icons for better terminal UI compatibility
- Optimized for readability at smaller sizes

## Keybindings

### Inspector & Quick Terminal
- `super+i` - Toggle inspector
- `super+b>,` - Toggle quick terminal

### Window Management (tmux-like with super+b prefix)
- `super+b>r` - Reload config
- `super+b>x` - Close surface/pane
- `super+b>c` - New tab
- `super+b>n` - New window

### Tab Navigation
- `super+b>1` through `super+b>9` - Jump to tab 1-9

### Split Management
- `super+b>\` - Split right (vertical split)
- `super+b>-` - Split down (horizontal split)
- `super+b>e` - Equalize splits

### Split Navigation
- `super+b>h` - Go to left split
- `super+b>j` - Go to bottom split
- `super+b>k` - Go to top split
- `super+b>l` - Go to right split

## Cursor

- **Style**: Block
- **Blinking**: Disabled for better focus
- **Colors**: Uses cell foreground/background for automatic contrast

## Shell Integration

- Feature disabled: `no-cursor` 
- Copy on select: Clipboard integration enabled
- System clipboard: `cmd+c` or `alt+c` for copy (independent of vim yank)

## Optional Shaders

Located in `shaders/` directory (commented out by default):
- `bettercrt.glsl` - CRT monitor effect
- `retro-terminal.glsl` - Vintage terminal aesthetic
- `bloom025.glsl` - Glow/bloom effect

Uncomment the `custom-shader` line in the config to enable.

## macOS Specific

- **Option key as Alt**: Enabled
- **Titlebar style**: Transparent
- **Mouse hide while typing**: Enabled
- **Auto-update**: Check for updates on stable channel

## Reload Config

Press `super+b>r` or restart Ghostty to apply config changes.
Default Ghostty reload: `shift+cmd+,`

## Files

```
ghostty/
├── config              # Main configuration file
├── shaders/
│   ├── bettercrt.glsl
│   ├── bloom025.glsl
│   └── retro-terminal.glsl
└── themes/
    ├── rosepine        # Rose Pine theme (active)
    └── tokyonight      # Tokyo Night theme
```

## Tips

- Ghostty's split navigation won't conflict with tmux if you use different prefixes
- The `super` key maps to `cmd` on macOS
- Splits and tabs are managed by Ghostty itself, no need for tmux inside Ghostty
- Use `-` keybind in Ghostty's Oil.nvim style for split navigation

## Resources

- [Ghostty Official Docs](https://ghostty.org/docs)
- [Ghostty GitHub](https://github.com/ghostty-org/ghostty)
