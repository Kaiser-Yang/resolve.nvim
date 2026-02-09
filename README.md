<h1 align="center">resolve.nvim</h1>

<p align="center">A Neovim plugin for resolving merge conflicts with ease.</p>

<p align="center">
  <video src="https://github.com/user-attachments/assets/a6b55e7a-c490-4a43-8562-1851b93610fd" width="876" controls muted loop>
    ![Demo Screencast](https://github.com/user-attachments/assets/a6b55e7a-c490-4a43-8562-1851b93610fd)
  </video>
</p>

You can watch [a three-minute demo on YouTube](https://www.youtube.com/watch?v=8twR5lfrGN4)

## Features

- Automatically detect merge conflicts in buffers
- Semantic highlighting for both markers and content sections with automatic light/dark theme support
- Navigate between conflicts quickly
- Resolve conflicts with simple commands
- Support for standard 3-way merge and diff3 formats
- View diffs between base and each version separately or together in a floating window
- List all conflicts in quickfix window
- Buffer-local keymaps (only active in buffers with conflicts)
- Matchit integration for `%` jumping between conflict markers
- `<Plug>` mappings for easy custom keybinding
- Customisable hooks/callbacks on conflict detection

## Development

This plugin was inspired by prior work:

- [conflict-marker.vim](https://github.com/rhysd/conflict-marker.vim)
- [git-conflict.nvim](https://github.com/akinsho/git-conflict.nvim)

The feature I was missing in other plugins was a quick way to compare the local or remote side of the conflict with the common base (which is included in conflicted files if enabled, e.g. by the `merge.conflictStyle` setting in git set to `diff3`).

Development was aided by Claude Code. Pull requests are welcome. If you use AI coding tools, please read and understand all code changes before submitting them as a PR.

## Requirements

- Neovim >= 0.9
- [delta](https://github.com/dandavison/delta) - required for diff view features (optional if you only use highlighting and conflict resolution)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "spacedentist/resolve.nvim",
  event = { "BufReadPre", "BufNewFile" },
  opts = {},
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "spacedentist/resolve.nvim",
  config = function()
    require("resolve").setup()
  end,
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'spacedentist/resolve.nvim'

lua << EOF
  require("resolve").setup()
EOF
```

## Configuration

Default configuration:

```lua
require("resolve").setup({
  -- Conflict marker patterns (Lua patterns, must match from start of line)
  markers = {
    ours = "^<<<<<<<+",      -- Start of "ours" section
    theirs = "^>>>>>>>+",    -- End of "theirs" section
    ancestor = "^|||||||+",  -- Start of ancestor/base section (diff3)
    separator = "^=======+$", -- Separator between sections
  },
  -- Set to false to disable default keymaps
  default_keymaps = true,
  -- Labels for diff view window titles
  -- Useful for rebasing where "incoming" is actually "ours"
  diff_view_labels = {
    ours = "Ours",
    theirs = "Theirs",
    base = "Base",
  },
  -- Enable automatic conflict detection on text changes (e.g., after undo)
  auto_detect_enabled = true,
  -- Callback function called when conflicts are detected
  -- Receives: { bufnr = number, conflicts = table }
  on_conflict_detected = nil,
  -- Callback function called when all conflicts are resolved
  -- Receives: { bufnr = number }
  on_conflicts_resolved = nil,
})
```

### Customizing Diff View Labels

You can customize the labels shown in diff view window titles. This is particularly useful when rebasing, where the terms "ours" and "theirs" can be confusing:

```lua
require("resolve").setup({
  diff_view_labels = {
    ours = "Current",
    theirs = "Incoming",
    base = "Base",
  },
})
```

With this configuration, diff windows will show titles like "Current → Incoming" instead of "Ours → Theirs".

### Theming and Highlights

The plugin creates highlight groups for both conflict markers and their content sections, with semantic colours that automatically adapt to light/dark backgrounds:

#### Marker Highlights (bold lines)

| Highlight Group | Marker | Dark Theme | Light Theme | Meaning |
|----------------|--------|------------|-------------|---------|
| `ResolveOursMarker` | `<<<<<<<` | Green tint | Light green | Your changes (keep) |
| `ResolveTheirsMarker` | `>>>>>>>` | Blue tint | Light blue | Incoming changes |
| `ResolveSeparatorMarker` | `=======` | Grey | Light grey | Neutral divider |
| `ResolveAncestorMarker` | `\|\|\|\|\|\|\|` | Amber tint | Light amber | Original/base (diff3) |

All markers are displayed in **bold** with normal text colour and a tinted background.

#### Section Highlights (content between markers)

| Highlight Group | Section | Dark Theme | Light Theme | Meaning |
|----------------|---------|------------|-------------|---------|
| `ResolveOursSection` | Ours content | Subtle green | Very light green | Your changes |
| `ResolveTheirsSection` | Theirs content | Subtle blue | Very light blue | Incoming changes |
| `ResolveAncestorSection` | Base content | Subtle amber | Very light amber | Original (diff3) |

The section highlights provide a subtle background tint to help visually distinguish which code belongs to which side.

The highlights automatically update when you change colour schemes or toggle between light/dark backgrounds.

#### Customising Highlights

Override the highlight groups in your config to customise the appearance:

```lua
-- After calling setup(), override any highlights you want to change

-- Marker highlights (bold lines)
vim.api.nvim_set_hl(0, "ResolveOursMarker", { bg = "#3d5c3d", bold = true })
vim.api.nvim_set_hl(0, "ResolveTheirsMarker", { bg = "#3d4d5c", bold = true })
vim.api.nvim_set_hl(0, "ResolveSeparatorMarker", { bg = "#4a4a4a", bold = true })
vim.api.nvim_set_hl(0, "ResolveAncestorMarker", { bg = "#5c4d3d", bold = true })

-- Section highlights (content areas)
vim.api.nvim_set_hl(0, "ResolveOursSection", { bg = "#2a3a2a" })
vim.api.nvim_set_hl(0, "ResolveTheirsSection", { bg = "#2a2f3a" })
vim.api.nvim_set_hl(0, "ResolveAncestorSection", { bg = "#3a322a" })
```

Or link to existing highlight groups if you prefer theme-matched colours:

```lua
-- Markers
vim.api.nvim_set_hl(0, "ResolveOursMarker", { link = "DiffAdd" })
vim.api.nvim_set_hl(0, "ResolveTheirsMarker", { link = "DiffChange" })
vim.api.nvim_set_hl(0, "ResolveSeparatorMarker", { link = "NonText" })
vim.api.nvim_set_hl(0, "ResolveAncestorMarker", { link = "DiffText" })

-- Sections
vim.api.nvim_set_hl(0, "ResolveOursSection", { link = "DiffAdd" })
vim.api.nvim_set_hl(0, "ResolveTheirsSection", { link = "DiffChange" })
vim.api.nvim_set_hl(0, "ResolveAncestorSection", { link = "DiffText" })
```

To disable section highlights entirely while keeping marker highlights:

```lua
vim.api.nvim_set_hl(0, "ResolveOursSection", {})
vim.api.nvim_set_hl(0, "ResolveTheirsSection", {})
vim.api.nvim_set_hl(0, "ResolveAncestorSection", {})
```

## Usage

### Default Keymaps

When `default_keymaps` is enabled (keymaps are buffer-local, only active when conflicts exist):

- `]x` - Navigate to next conflict
- `[x` - Navigate to previous conflict
- `<leader>gco` - Choose ours (current changes)
- `<leader>gct` - Choose theirs (incoming changes)
- `<leader>gcb` - Choose both (keep both versions)
- `<leader>gcB` - Choose both reverse (theirs then ours)
- `<leader>gcm` - Choose base/ancestor (diff3 only)
- `<leader>gcn` - Choose none (delete conflict)
- `<leader>gcl` - List all conflicts in quickfix window
- `<leader>gcdo` - Show diff ours (base → ours, diff3 only)
- `<leader>gcdt` - Show diff theirs (base → theirs, diff3 only)
- `<leader>gcdb` - Show diff both (base → ours and base → theirs, diff3 only)
- `<leader>gcdv` - Show diff ours → theirs (direct comparison, works without diff3)
- `<leader>gcdV` - Show diff theirs → ours (reverse comparison, works without diff3)

The `<leader>gc` prefix displays as "Git Conflicts" in which-key, and `<leader>gcd` displays as "Diff".

### Commands

The plugin provides the following commands:

- `:ResolveNext` - Navigate to next conflict
- `:ResolvePrev` - Navigate to previous conflict
- `:ResolveOurs` - Choose ours version
- `:ResolveTheirs` - Choose theirs version
- `:ResolveBoth` - Choose both versions (ours then theirs)
- `:ResolveBothReverse` - Choose both versions (theirs then ours)
- `:ResolveBase` - Choose base/ancestor version (diff3 only)
- `:ResolveNone` - Choose neither version
- `:ResolveList` - List all conflicts in quickfix
- `:ResolveDetect` - Manually detect conflicts
- `:ResolveToggleAutoDetect [on|off]` - Toggle automatic conflict detection on text changes
- `:ResolveDiffOurs` - Show diff of our changes from base (diff3 only)
- `:ResolveDiffTheirs` - Show diff of their changes from base (diff3 only)
- `:ResolveDiffBoth` - Show both diffs in floating window (diff3 only)
- `:ResolveDiffOursTheirs` - Show diff ours → theirs (works without diff3)
- `:ResolveDiffTheirsOurs` - Show diff theirs → ours (works without diff3)

#### Automatic Conflict Detection

By default, the plugin automatically re-detects conflicts when text changes (e.g., after undo). You can toggle this feature:

- `:ResolveToggleAutoDetect` - Toggle current state
- `:ResolveToggleAutoDetect!` - Toggle current state (silent, no notification)
- `:ResolveToggleAutoDetect on` or `:ResolveToggleAutoDetect true` - Enable auto-detection
- `:ResolveToggleAutoDetect! on` - Enable auto-detection (silent)
- `:ResolveToggleAutoDetect off` or `:ResolveToggleAutoDetect false` - Disable auto-detection
- `:ResolveToggleAutoDetect 1` - Enable (any non-zero number enables)
- `:ResolveToggleAutoDetect 0` - Disable

When enabling auto-detection, the plugin immediately scans the current buffer for conflicts.

You can also disable it permanently in your configuration:

```lua
require("resolve").setup({
  auto_detect_enabled = false,
})
```

### Custom Keymaps

If you prefer custom keymaps, disable the default ones and set your own using the `<Plug>` mappings:

```lua
require("resolve").setup({
  default_keymaps = false,
})

-- Example: Set custom keymaps using <Plug> mappings
-- Register groups for which-key (optional)
vim.keymap.set("n", "<leader>gc", "", { desc = "+Git Conflicts" })
vim.keymap.set("n", "<leader>gcd", "", { desc = "+Diff" })

vim.keymap.set("n", "]c", "<Plug>(resolve-next)", { desc = "Next conflict" })
vim.keymap.set("n", "[c", "<Plug>(resolve-prev)", { desc = "Previous conflict" })
vim.keymap.set("n", "<leader>gco", "<Plug>(resolve-ours)", { desc = "Choose ours" })
vim.keymap.set("n", "<leader>gct", "<Plug>(resolve-theirs)", { desc = "Choose theirs" })
vim.keymap.set("n", "<leader>gcb", "<Plug>(resolve-both)", { desc = "Choose both" })
vim.keymap.set("n", "<leader>gcB", "<Plug>(resolve-both-reverse)", { desc = "Choose both reverse" })
vim.keymap.set("n", "<leader>gcm", "<Plug>(resolve-base)", { desc = "Choose base" })
vim.keymap.set("n", "<leader>gcn", "<Plug>(resolve-none)", { desc = "Choose none" })
vim.keymap.set("n", "<leader>gcdo", "<Plug>(resolve-diff-ours)", { desc = "Diff ours" })
vim.keymap.set("n", "<leader>gcdt", "<Plug>(resolve-diff-theirs)", { desc = "Diff theirs" })
vim.keymap.set("n", "<leader>gcdb", "<Plug>(resolve-diff-both)", { desc = "Diff both" })
vim.keymap.set("n", "<leader>gcdv", "<Plug>(resolve-diff-vs)", { desc = "Diff ours → theirs" })
vim.keymap.set("n", "<leader>gcdV", "<Plug>(resolve-diff-vs-reverse)", { desc = "Diff theirs → ours" })
vim.keymap.set("n", "<leader>gcl", "<Plug>(resolve-list)", { desc = "List conflicts" })
```

### Available `<Plug>` Mappings

The following `<Plug>` mappings are always available for custom keybindings:

- `<Plug>(resolve-next)` - Navigate to next conflict
- `<Plug>(resolve-prev)` - Navigate to previous conflict
- `<Plug>(resolve-ours)` - Choose ours version
- `<Plug>(resolve-theirs)` - Choose theirs version
- `<Plug>(resolve-both)` - Choose both versions (ours then theirs)
- `<Plug>(resolve-both-reverse)` - Choose both versions (theirs then ours)
- `<Plug>(resolve-base)` - Choose base version
- `<Plug>(resolve-none)` - Choose neither version
- `<Plug>(resolve-diff-ours)` - Show diff ours (base → ours)
- `<Plug>(resolve-diff-theirs)` - Show diff theirs (base → theirs)
- `<Plug>(resolve-diff-both)` - Show both diffs
- `<Plug>(resolve-diff-vs)` - Show diff ours → theirs
- `<Plug>(resolve-diff-vs-reverse)` - Show diff theirs → ours
- `<Plug>(resolve-list)` - List conflicts in quickfix

**Note:** The default keymaps use `<leader>gc` prefix (git conflicts) to avoid conflicts with LSP-specific keybindings that may be dynamically set under `<leader>c` when language servers attach.

### Buffer-Local Keymaps

When `default_keymaps` is enabled, keymaps are only set in buffers that contain conflicts. This prevents the keymaps from interfering with other plugins or workflows in files without conflicts.

The plugin automatically registers the `<leader>gc` group with which-key (if installed), displaying "Git Conflicts" when you press `<leader>g` in a buffer with conflicts.

### Matchit Integration

The plugin integrates with Vim's matchit to allow jumping between conflict markers using `%`. When a buffer contains conflicts, you can press `%` on any marker (`<<<<<<<`, `|||||||`, `=======`, `>>>>>>>`) to jump to the corresponding marker in the conflict.

### Viewing Diffs

You can view diffs to help understand what changed on each side of the conflict.

**Diff3-style conflicts** (with base/ancestor):
- `<leader>gcdo` (or `:ResolveDiffOurs`) - Show base → ours (what you changed)
- `<leader>gcdt` (or `:ResolveDiffTheirs`) - Show base → theirs (what they changed)
- `<leader>gcdb` (or `:ResolveDiffBoth`) - Show both diffs in one window

**All conflicts** (including non-diff3):
- `<leader>gcdv` (or `:ResolveDiffOursTheirs`) - Show ours → theirs (what changes if you accept theirs)
- `<leader>gcdV` (or `:ResolveDiffTheirsOurs`) - Show theirs → ours (what changes if you accept ours)

The direct comparison views are useful when you want to see the actual differences between the two sides without comparing to the base. They work even when there's no ancestor section. The arrow indicates the diff direction: additions appear as lines being added to the left side to produce the right side.

The diff view uses [delta](https://github.com/dandavison/delta) for beautiful syntax highlighting with intra-line change emphasis. Press `q` or `<Esc>` to close the floating window.

### Hooks and Callbacks

You can run custom code when conflicts are detected or resolved using callbacks:

```lua
require("resolve").setup({
  on_conflict_detected = function(info)
    -- Called when conflicts are found in a buffer
    -- info.bufnr: buffer number
    -- info.conflicts: table of conflict data
    vim.notify(string.format("Found %d conflicts!", #info.conflicts), vim.log.levels.WARN)

    -- Example: Auto-open quickfix list when conflicts detected
    vim.schedule(function()
      require("resolve").list_conflicts()
    end)
  end,

  on_conflicts_resolved = function(info)
    -- Called when all conflicts in a buffer are resolved
    -- info.bufnr: buffer number
    vim.notify("All conflicts resolved!", vim.log.levels.INFO)

    -- Example: Remove custom keymaps you added in on_conflict_detected
    vim.keymap.del("n", "<leader>cc", { buffer = info.bufnr })
  end,
})
```

The `on_conflicts_resolved` hook is particularly useful for cleaning up custom keymaps or other buffer-local setup you added in `on_conflict_detected`.

## How It Works

When you open a file with merge conflicts, resolve.nvim automatically:

1. Detects conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
2. Highlights the conflicting regions
3. Provides commands to navigate and resolve conflicts

### Conflict Structure

Standard 3-way merge:
```
<<<<<<< HEAD (ours)
Your changes
=======
Their changes
>>>>>>> branch-name (theirs)
```

diff3 style:
```
<<<<<<< HEAD (ours)
Your changes
||||||| ancestor
Original content
=======
Their changes
>>>>>>> branch-name (theirs)
```

## License

MIT
