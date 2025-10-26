# fix.nvim

Plugin for FIX protocol viewing in Neovim.

## Screenshots

![Annotated without title](./docs/demo/annotate-wo-title.png)
![Annotated](./docs/demo/annotate.png)
![Picker](./docs/demo/picker.png)

## Features

- Syntax highlighting for FIX messages
- Tag and values annotation
- Easy navigation between fields
- Support for multiple FIX versions
- SOH \x01 character concealing

## Installation

### With lazy.nvim

```lua
{
  "sergluka/fix.nvim",
dependencies = {
    "manoelcampos/xml2lua",
    "ColinKennedy/mega.cmdparse",
    "ColinKennedy/mega.logging",
    "folke/snacks.nvim", -- optional, in case you want the fields picker
  }
  opts = {
    -- Configuration options here
  }
  build = ":TSUpdate fix",
}
```

## Usage

| Command | Lua API | Description |
|---------|--------------|-------------|
| `:FIX --help` | | Show help |
| `:FIX annotations [all, tag, value, message]` | `require("fix").annotate(scope)` | Toggle annotations |
| `:FIX picker` | `require("fix.snacks").open()` | Show fields picker |
| `:FIX browse` | `require("fix").browse_tag_online()` | Open Onixs tag info page in browser |
| `:FIX yank field [--reg=<REGISTER>]` | `require("fix").yank_field(reg)` | Yanks annotated field under cursor |
| `:FIX yank message [--reg=<REGISTER>]` | `require("fix").yank_message(reg)` | Yanks annotated message under cursor |

## Configuration

```lua
{
  -- Rules for filetype detection. Corresponds to `vim.filetype.add.filetypes`.
  ft = {
    extensions = { "fix", "fixlog" },
    pattern = { ".*%.fix.txt" },
  },
  annotate = {
    -- Tag annotation
    tag = {
      enabled = true,
      formatter = require("fix.formatters.tag").default,
    },
    -- Value annotation
    value = {
      enabled = true,
      formatter = require("fix.formatters.value").default,
    },
    -- Message (title) annotation
    message = {
      enabled = true,
      position = "above", -- "above" | "below"
      formatter = require("fix.formatters.message").default,
    },
  },
}
```

## Keybindings

Plugin does not set any keybindings by default. You can set your own keybindings as follows:

```lua
-- ftplugin/fix.lua

local fix = require("fix")

vim.keymap.set("n", "<localleader>t", function() fix.annotate_toggle("message") end, { desc = "fix: toggle message annotation", buffer = true })
vim.keymap.set("n", "<localleader>T", function() fix.annotate_toggle("all") end, { desc = "fix: toggle all annotation", buffer = true })
vim.keymap.set("n", "<localleader>x", function() fix.browse_tag_online() end, { desc = "fix: open online doc", buffer = true })
vim.keymap.set("n", "<localleader>yf", function() fix.yank_field("+") end, { desc = "fix: yank field", buffer = true })
vim.keymap.set("n", "<localleader>yy", function() fix.yank_message("+") end, { desc = "fix: yank message", buffer = true })
vim.keymap.set("n", "<localleader><localleader>", function() require("fix.snacks").open() end, { desc = "fix: browse tags", buffer = true })

local ts_move = require("nvim-treesitter.textobjects.move")

vim.keymap.set({ "n", "v" }, "]]", function() ts_move.goto_next_start("@field") end, { desc = "fix: next field start", buffer = true })
vim.keymap.set({ "n", "v" }, "[[", function() ts_move.goto_previous_start("@field") end, { desc = "fix: previous field start", buffer = true })
vim.keymap.set({ "n", "v" }, "]}", function() ts_move.goto_next_end("@field") end, { desc = "fix: next field end", buffer = true })
vim.keymap.set({ "n", "v" }, "[{", function() ts_move.goto_previous_end("@field") end, { desc = "fix: previous field end", buffer = true })

vim.keymap.set({ "n", "v" }, "]m", function() ts_move.goto_next_start("@message") end, { desc = "fix: next message start", buffer = true })
vim.keymap.set({ "n", "v" }, "[m", function() ts_move.goto_previous_start("@message") end, { desc = "fix: previous message start", buffer = true })
vim.keymap.set({ "n", "v" }, "]M", function() ts_move.goto_next_end("@message") end, { desc = "fix: next message end", buffer = true })
vim.keymap.set({ "n", "v" }, "[M", function() ts_move.goto_previous_end("@message") end, { desc = "fix: previous message end", buffer = true })

vim.keymap.set({ "n", "v" }, "]g", function() ts_move.goto_next_start("@comment") end, { desc = "fix: next comment start", buffer = true })
vim.keymap.set({ "n", "v" }, "[g", function() ts_move.goto_previous_start("@comment") end, { desc = "fix: previous comment start", buffer = true })
vim.keymap.set({ "n", "v" }, "]G", function() ts_move.goto_next_end("@comment") end, { desc = "fix: next comment end", buffer = true })
vim.keymap.set({ "n", "v" }, "[G", function() ts_move.goto_previous_end("@comment") end, { desc = "fix: previous comment end", buffer = true })
```

## Note

Because of an [NVIM limitation](https://github.com/neovim/neovim/issues/16166), the virtual text above the first line is not displayed, and the first message title will not be visible. This issue can be worked around as follows:

- Adding an empty line at the beginning of the file
- Pressing `C-b` to scroll on top after opening the file
- Using `annotate.message.position = "below"` to display the message title below the message

## Links

- [tree-sitter fix basic parser](https://github.com/sergluka/tree-sitter-fix)
- [FIX repository](https://www.fixtrading.org/standards/fix-repository/)
