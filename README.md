# fix.nvim

fix.nvim is a Neovim plugin for reading [FIX protocol](https://www.fixtrading.org/standards/) logs.
It parses FIX messages with tree-sitter, resolves tags and enum values from
vendored FIX dictionaries, and decorates buffers with virtual text.

## Features

- Syntax highlighting through [tree-sitter-fix](https://github.com/sergluka/tree-sitter-fix)
- Inline tag and enum annotations with configurable formatters
- Message summary titles above, below, or at the front of each FIX message
- SOH (`\x01`) concealment for readable log files
- Multiple FIX dictionary versions, including `FIXT.1.1` via `FIX.5.0SP2`
- Viewport-first rendering with background cache warm-up for large files
- Persistent parse/decode cache across Neovim sessions
- Commands for yanking fields/messages, opening online tag docs, and browsing
  fields with [snacks.nvim](https://github.com/folke/snacks.nvim)

## Screenshots

![FIX tag and value annotations](./media/annotate-wo-title.png)
![FIX message titles and annotations](./media/annotate.png)
![FIX fields picker](./media/picker.png)

## Requirements

- Neovim **0.11+**
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
- [tree-sitter-fix](https://github.com/sergluka/tree-sitter-fix), installed
  with `:TSUpdate fix`
- `xml2lua`
- `mega.cmdparse`
- `mega.logging`
- Optional: `snacks.nvim` for `:FIX picker`
- Development only: Podman >= 5.x for integration tests

> [!TIP]
> On very large files, Neovim's tree-sitter highlighting can freeze the UI when
> jumping into unparsed regions. That is independent of fix.nvim. Disable
> highlighting for those buffers with `:lua vim.treesitter.stop(0)`, or let your
> distribution's big-file protection handle it. fix.nvim annotations continue to
> work because the plugin parses asynchronously and renders the viewport first.

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "sergluka/fix.nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "manoelcampos/xml2lua",
    "ColinKennedy/mega.cmdparse",
    "ColinKennedy/mega.logging",
    "folke/snacks.nvim", -- optional; omit if you do not use :FIX picker
  },
  build = { "rockspec", ":TSUpdate fix" },
  opts = {},
}
```

## Usage

| Command | Lua API | Description |
| --- | --- | --- |
| `:FIX --help` | | Show command help |
| `:FIX annotations [all|tag|value|message]` | `require("fix").annotate_toggle(scope)` | Toggle all annotations or one annotation scope |
| `:FIX picker` | `require("fix.snacks").open()` | Open the fields picker |
| `:FIX browse` | `require("fix").browse_tag_online()` | Open the Onixs documentation page for the tag under the cursor |
| `:FIX dictionary <PATH>` | `require("fix").use_dictionary(path)` | Use a custom FIX dictionary XML file or repository directory |
| `:FIX yank [--reg=<REGISTER>]` | `require("fix").yank(reg)` | Smart yank: current/selected fields for characterwise targets, selected messages for linewise targets |
| `:FIX cache clear` | `require("fix").cache_clear()` | Clear in-memory and on-disk cache entries for the current file, then re-render |

`FIX yank` accepts visual ranges and Vim operator targets. Characterwise
targets yank selected annotated fields; linewise targets yank selected messages.

`FIX dictionary` accepts a QuickFIX-style XML file or a FIX Repository
directory containing `Fields.xml` and `Enums.xml`. The dictionary version is
detected from the XML and replaces the bundled dictionary for that version until
another custom dictionary is registered for the same version or Neovim exits.
Examples:

```vim
:FIX dictionary xml/custom/binance/spot-fix-oe.xml
:FIX dictionary xml/custom/coinbase/order-entry/FIX42-prod-sand.xml
```

## Configuration

```lua
{
  -- Bundled dictionary version used when BeginString (tag 8) is missing or unknown.
  -- Examples: "FIX.4.0", "FIX.4.4", "FIX.5.0SP2", "FIXT.1.1".
  -- "FIXT.1.1" resolves through "FIX.5.0SP2".
  fallback_version = "FIX.4.4",

  -- Filetype detection rules passed to vim.filetype.add().
  ft = {
    extensions = { "fix", "fixlog" },
    pattern = { ".*%.fix.txt" },
  },

  annotate = {
    tag = {
      enabled = true,
      formatter = require("fix.formatters.tag").default,
    },
    value = {
      enabled = true,
      formatter = require("fix.formatters.value").default,
    },
    message = {
      enabled = true,
      position = "above", -- "above" | "below" | "front"
      formatter = require("fix.formatters.message").default,
    },
  },

  cache = {
    persist = {
      enabled = true,
      max_files = 20, -- set false to disable the file-count limit
      max_bytes = 100 * 1024 * 1024, -- set false to disable the total-size limit
      dir = nil, -- defaults to stdpath("cache") .. "/fix.nvim"
    },
  },

  render = {
    debounce_ms = 80,
    lines_per_batch = 500,
    viewport_margin = 50,
  },
}
```

Custom formatters should be pure functions of the provided message or field.
Formatter output is cached by line hash and reused across identical lines and
buffers, so formatters that read `message.lineno`, buffer state, or other
external state can produce stale annotations.

The persistent cache lives at `stdpath("cache")/fix.nvim` unless
`cache.persist.dir` is set. Set `cache.persist.enabled = false` to keep all
cache data in memory only. Cache rotation deletes the oldest `.mpack` files
until both enabled limits, `max_files` and `max_bytes`, are satisfied. When
persistence is enabled, at least one rotation limit must remain enabled.

Rendering is viewport-first. The visible region, plus `viewport_margin` lines
above and below it, is annotated immediately after the edit debounce. The rest
of the buffer warms the parse/decode cache in `lines_per_batch` chunks.
Off-screen extmarks are not kept around; annotations are re-applied as you
scroll, which keeps large buffers responsive.

## Keybindings

No keybindings are set by default. Proposed mappings for `ftplugin/fix.lua` or your
Neovim config:

```lua
local fix = require("fix")

local function map(lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, { buffer = true, desc = "fix: " .. desc })
end

local function smart_yank()
  return fix.operator_yank_register("+")
end

map("<localleader>t", function()
  fix.annotate_toggle("message")
end, "toggle message annotation")

map("<localleader>T", function()
  fix.annotate_toggle("all")
end, "toggle all annotations")

map("<localleader>x", function()
  fix.browse_tag_online()
end, "open online tag docs")

vim.keymap.set("n", "<localleader>y", smart_yank, {
  expr = true,
  buffer = true,
  desc = "fix: yank target",
})
vim.keymap.set("x", "<localleader>y", function()
  fix.yank("+")
end, {
  buffer = true,
  desc = "fix: yank selection",
})
vim.keymap.set(
  "n",
  "<localleader>yy",
  function() return fix.operator_yank_register("+") .. "_" end,
  { expr = true, buffer = true, desc = "fix: yank line" }
)

map("<localleader><localleader>", function()
  require("fix.snacks").open()
end, "open field picker")
```

Use `fix.operator_yank_register()` without an argument to write to Vim's default
unnamed register. Pass `"+"` or another register name to make that mapping use
a specific register by default.

The following navigation mappings require `nvim-treesitter-textobjects`:

```lua
local ok, ts_move = pcall(require, "nvim-treesitter-textobjects.move")
if not ok then
  ts_move = require("nvim-treesitter.textobjects.move")
end

local function ts_map(lhs, method, query, desc)
  vim.keymap.set({ "n", "x", "o" }, lhs, function()
    ts_move[method](query)
  end, { buffer = true, desc = "fix: " .. desc })
end

ts_map("]]", "goto_next_start", "@field", "next field start")
ts_map("[[", "goto_previous_start", "@field", "previous field start")
ts_map("]}", "goto_next_end", "@field", "next field end")
ts_map("[{", "goto_previous_end", "@field", "previous field end")

ts_map("]m", "goto_next_start", "@message", "next message start")
ts_map("[m", "goto_previous_start", "@message", "previous message start")
ts_map("]M", "goto_next_end", "@message", "next message end")
ts_map("[M", "goto_previous_end", "@message", "previous message end")

ts_map("]g", "goto_next_start", "@comment", "next comment start")
ts_map("[g", "goto_previous_start", "@comment", "previous comment start")
ts_map("]G", "goto_next_end", "@comment", "next comment end")
ts_map("[G", "goto_previous_end", "@comment", "previous comment end")
```

With the yank mapping above, `<localleader>y` behaves like a Vim operator:
type a motion after it to choose the FIX data to yank.

Examples:

```vim
" Yank annotated fields from the cursor through the third next field end.
<localleader>y3]]

" Yank annotated messages covered by the current line and the line below.
<localleader>yj

" Yank annotated fields in the current visual selection.
v...<localleader>y
```

Operator targets such as `]]` must be available in operator-pending mode (`"o"`).
The `ts_map()` helper above uses `{ "n", "x", "o" }` for that reason.

## Limitations

Due to a [Neovim limitation](https://github.com/neovim/neovim/issues/16166),
virtual lines above the first buffer line are not displayed. If the first
message title is hidden, use one of these workarounds:

- Add an empty line at the beginning of the file.
- Press `<C-b>` after opening the file.
- Set `annotate.message.position = "below"` or `"front"`.

## Development

Integration tests run inside a Podman container. The image includes Neovim, the
`tree-sitter-fix` parser, and all Lua dependencies at pinned commit SHAs, so
tests do not need network access at runtime.

```sh
# Build the image on first run and execute the full suite.
./bin/test-integration

# Force a fresh image rebuild after pin updates in Containerfile.
./bin/test-integration --rebuild

# Run one spec file: tests/integration/test_<name>.lua.
./bin/test-integration --filter annotate

# Open a fixture in the test image.
podman run --rm -it --entrypoint nvim \
  -v "$PWD:/plugin:Z" \
  localhost/fix-nvim-test:latest \
  -u tests/integration/minimal_init.lua tests/integration/fixtures/4.4.fix
```

CI runs the same image via `.github/workflows/ci.yml`. Host-side linting still runs with `stylua` and `luacheck`.

## Links

- [tree-sitter-fix parser](https://github.com/sergluka/tree-sitter-fix)
- [FIX Repository](https://www.fixtrading.org/standards/fix-repository/)
