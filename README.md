# fix.nvim: FIX Protocol viewer for Neovim

fix.nvim is a Neovim plugin for viewing, highlighting, annotating, navigating,
and exploring [Financial Information eXchange (FIX)](https://www.fixtrading.org/standards/)
protocol messages.

## Features

- Syntax highlighting through [tree-sitter-fix](https://github.com/sergluka/tree-sitter-fix)
- Inline tag and enum annotations with configurable formatters
- Message summary titles above, below, at the front of, or replacing each FIX message
- SOH (`\x01`) concealment for readable log files
- Multiple FIX dictionary versions, including `FIXT.1.1` via `FIX.5.0SP2`
- Viewport-first rendering with background cache warm-up for large files
- Persistent parse/decode cache across Neovim sessions
- Commands for yanking fields/messages, opening online tag docs, and browsing
  fields with [snacks.nvim](https://github.com/folke/snacks.nvim)

## Limitations

Before using this plugin, consider the following known Neovim limitations:

- On long FIX lines an annotation can be split mid-word across two screen rows, and cursor motions (`w`, `e`, …) may then appear to land inside a label. This is a Neovim bug, not specific to this plugin — see [neovim/neovim#35341](https://github.com/neovim/neovim/issues/35341). Workaround: use `:setlocal nowrap` in FIX buffers and scroll horizontally, or disable field annotations entirely (`annotate.{tag,value}.enabled = false`).
- Virtual lines above the first buffer line are not displayed ([neovim/neovim#16166](https://github.com/neovim/neovim/issues/16166)). Workaround: avoid `annotate.title.position = "above"`.
- On very large files, Neovim's tree-sitter highlighting can freeze the UI when jumping into unparsed regions. Disable highlighting for those buffers with `:lua vim.treesitter.stop(0)`, or let your distribution's big-file protection handle it.

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
| `:FIX annotations [all|tag|value|title|message|group]` | `require("fix").annotate_toggle(scope)` | Toggle all annotations or one annotation scope (`message` is a legacy alias for `title`) |
| `:FIX picker` | `require("fix.snacks").open()` | Open the fields picker |
| `:FIX browse` | `require("fix").browse_tag_online()` | Open the Onixs documentation page for the tag under the cursor |
| `:FIX dictionary <PATH>` | `require("fix").use_dictionary(path)` | Use a custom FIX dictionary XML file or repository directory |
| `:FIX yank [--reg=<REGISTER>]` | `require("fix").yank(reg)` | Smart yank: current/selected fields for characterwise targets, selected messages for linewise targets |
| `:FIX cache clear` | `require("fix").cache_clear()` | Clear in-memory and on-disk cache entries for the current file, then re-render |

`FIX yank` accepts visual ranges and Vim operator targets. Characterwise
targets yank selected annotated fields; linewise targets yank selected messages.

Custom dictionaries can be configured in `setup()` or registered at runtime
with `FIX dictionary`. Selection is based on tag `8` (`BeginString`): a custom
dictionary keyed by that version wins, otherwise the bundled dictionary is used.

`FIX dictionary` accepts a QuickFIX-style XML file or a FIX Repository
directory containing `Fields.xml` and `Enums.xml`. Repository dictionaries can
also include `Messages.xml`, `MsgContents.xml`, and `Components.xml` to enable
repeating group paths. The dictionary version is detected from the XML and
replaces the active dictionary for that version until another custom dictionary
is registered for the same version, `setup()` is run again, or Neovim exits.
Examples:

```vim
:FIX dictionary xml/custom/binance/spot-fix-oe.xml
:FIX dictionary xml/custom/coinbase/order-entry/FIX42-prod-sand.xml
```

## Configuration

Pass this table as `opts` for your plugin manager, or pass the same fields to
`require("fix").setup({ ... })`. You only need to set the parts you want to
change; omitted fields fall back to the defaults below.

```lua
{
  -- Bundled dictionary version used when BeginString (tag 8) is missing or unknown.
  -- Examples: "FIX.4.0", "FIX.4.4", "FIX.5.0SP2", "FIXT.1.1".
  -- "FIXT.1.1" resolves through "FIX.5.0SP2".
  fallback_version = "FIX.4.4",

  -- Custom dictionaries keyed by BeginString/FIX version.
  -- Each version can have one active custom dictionary.
  -- `tags` can be used with or without `path` to add Lua decoders.
  dictionaries = {
    ["FIX.4.4"] = {
      path = "xml/custom/binance/spot-fix-oe.xml",
      mode = "quickfix", -- "auto" | "quickfix" | "repository"
      ---@type table<integer, FixTagDecoder>
      tags = {
        [25035] = function(field, _ctx)
          return {
            tag_text = "MessageHandling",
            value_text = ({ ["1"] = "UNORDERED", ["2"] = "SEQUENTIAL" })[field.value],
          }
        end,
      },
    },
    ["FIX.4.2"] = "xml/custom/coinbase/order-entry/FIX42-prod-sand.xml",
  },

  -- Filetype detection rules passed to vim.filetype.add().
  ft = {
    extensions = { "fix", "fixlog" },
    pattern = { ".*%.fix.txt" },
  },

  annotate = {
    tag = {
      enabled = true,
      formatter = function(field)
        return require("fix.formatters.tag").default(field)
      end,
    },
    value = {
      enabled = true,
      formatter = function(field)
        return require("fix.formatters.value").default(field)
      end,
    },
    title = {
      enabled = true,
      position = "above", -- "above" | "below" | "front" | "replace" | "replace_front"
      route = {
        enabled = true,
        mode = "direction", -- "direction" | "sender" | "pair"
        palette = {
          "FixRoute1",
          "FixRoute2",
          "FixRoute3",
          "FixRoute4",
          "FixRoute5",
          "FixRoute6",
          "FixRoute7",
          "FixRoute8",
        },
        overrides = {
          -- { sender = "CLIENT1", target = "*", highlight = "FixClientSend" },
        },
        resolver = nil, -- function(route, message) return "HighlightGroup" end
      },
      formatter = function(message)
        return require("fix.formatters.title").default(message)
      end,
    },
    group = {
      path = {
        enabled = true, -- Show group paths in field labels.
      },
      highlight = {
        enabled = true, -- Highlight grouped fields.
        target = "both", -- "raw", "annotation", or "both"
        -- Alternate colors by depth and entry.
        palette = {
          "FixGroupDepth1A",
          "FixGroupDepth1B",
          "FixGroupDepth2A",
          "FixGroupDepth2B",
          "FixGroupDepth3A",
          "FixGroupDepth3B",
        },
      },
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

### Dictionaries

`fallback_version` is the bundled dictionary used when a message has no tag `8`
(`BeginString`) or when its version is unknown. It must point to either a
bundled dictionary or a version configured in `dictionaries`. `FIXT.1.1`
resolves through `FIX.5.0SP2` unless you register a custom `FIXT.1.1`
dictionary.

`dictionaries` lets you replace or extend dictionaries per FIX version. Use an
explicit version key when you know the `BeginString` value, especially when two
custom files would otherwise infer the same version. Entries may also be a list
of paths or `{ path, mode }` tables when each file infers a different version.

`mode = "auto"` detects the dictionary layout from the path. Use `"quickfix"`
for one QuickFIX-style XML file, or `"repository"` for a FIX Repository
directory containing `Fields.xml` and `Enums.xml`.

Custom tag decoders run after XML dictionary lookup. They receive the parsed
`field` and `ctx = { version, fields, dictionary }`. Return `tag_text` and/or
`value_text` to replace the XML-derived annotation text; return `nil` for either
key to keep the existing value. A pathless entry such as
`dictionaries["FIX.4.4"] = { tags = ... }` overlays the bundled dictionary for
that version. The `FixTagDecoder` alias is available for LuaLS annotations.

### Filetype Detection

`ft.extensions` and `ft.pattern` are passed to `vim.filetype.add()`. Add entries
here when your FIX logs use project-specific extensions or names. Buffers with
`filetype=fix` are attached automatically.

### Annotations

Group paths, group highlights, tag annotations, value annotations, and titles
can each be enabled or disabled independently. `:FIX annotations all` toggles
every scope, and `:FIX annotations group|tag|value|title` toggles one scope.

Omit a `formatter` field to use the built-in formatter. The wrapped
`require(...)` form above is safe for plugin-manager `opts` tables because the
module is loaded only when the formatter runs.

Tag and value formatters receive a parsed field and return one virtual-text
chunk, such as `{ "(Symbol)", "Comment" }`. Title formatters receive a parsed
message and return virtual lines, such as `{ { { "title", "Highlight" } } }`.
Custom formatters should be pure functions of the provided message or field:
formatter output is cached by line hash and reused across identical lines and
buffers, so formatters that read `message.lineno`, buffer state, or other
external state can produce stale annotations.

Title formatters receive the parsed message and can reuse route styling without
depending on the default `sender=>target` title text:

```lua
formatter = function(message)
  local route = message:route()
  return { { { route.sender .. " to " .. route.target, message:route_highlight() } } }
end
```

Route override rules match structured FIX tag values from `49` and `56`, not
the rendered title string. Use `*` as a wildcard for either side. The route
`mode` controls how automatic colors are shared: `"direction"` groups messages
by direction, `"sender"` groups by sender, and `"pair"` groups each
sender/target pair separately.

#### Repeating Groups

Repeating-group annotations show where each field belongs in the message
structure. For example, the second `MDEntryPx` field in `NoMDEntries` is
annotated as `NoMDEntries/2/MDEntryPx`. Nested groups extend the same path with
each parent group and entry number.

`annotate.group.path.enabled` controls these paths. When disabled, fields keep
their normal names, such as `MDEntryPx`. `annotate.group.highlight.enabled`
controls the alternating group colors. The `target` setting chooses whether
those colors apply to the raw `tag=value` text, its inline annotations, or
`"both"`. Nested groups use successive palette entries based on their depth and
entry number; replace `palette` with your own Neovim highlight group names to
customize the colors.

`:FIX annotations group` toggles group paths and colors together without
disabling tag, value, or title annotations. Group annotations require group
structure in the active dictionary: QuickFIX XML uses `<group>` elements, while
FIX Repository directories use `Messages.xml`, `MsgContents.xml`, and
`Components.xml`. Bundled dictionaries already include this information.

`annotate.group.visual` is a deprecated alias for `annotate.group.highlight`.
Using it emits a warning, and `highlight` wins if both are set.

`annotate.title.position` controls where the message title is shown:

- `"above"` and `"below"` render a virtual line around the FIX message.
- `"front"` inserts the title before the raw FIX text.
- `"replace"` conceals each FIX message line and overlays the title.
- `"replace_front"` keeps inactive lines replaced, but shows the active line as
  raw FIX with the title in front.

`"replace"` and `"replace_front"` use Neovim conceal, so FIX buffers set
`conceallevel=2`. `annotate.message` is kept as a deprecated alias for
`annotate.title`; using it emits a warning, and `annotate.title` wins if both
are set.

### Highlight Groups

fix.nvim defines the following highlight groups. Defaults follow
`vim.o.background`; existing user definitions are preserved.

| Group | Dark background | Light background | Used for |
| --- | --- | --- | --- |
| `FixRoute1` | `#4da3ff` | `#005fcb` | Route palette slot 1 |
| `FixRoute2` | `#3ecf5f` | `#007a33` | Route palette slot 2 |
| `FixRoute3` | `#ffb02e` | `#8a5200` | Route palette slot 3 |
| `FixRoute4` | `#c678ff` | `#7a2ebf` | Route palette slot 4 |
| `FixRoute5` | `#00c8d7` | `#007c89` | Route palette slot 5 |
| `FixRoute6` | `#ff5f7a` | `#b00030` | Route palette slot 6 |
| `FixRoute7` | `#f0f3ff` | `#334155` | Route palette slot 7 |
| `FixRoute8` | `#ff7a18` | `#a13f00` | Route palette slot 8 |
| `FixGroupDepth1A` | `#243447` | `#e7f0ff` | Group palette slot 1 |
| `FixGroupDepth1B` | `#243b2f` | `#e6f5ea` | Group palette slot 2 |
| `FixGroupDepth2A` | `#3a2d1f` | `#fff0d8` | Group palette slot 3 |
| `FixGroupDepth2B` | `#332943` | `#f0e8ff` | Group palette slot 4 |
| `FixGroupDepth3A` | `#20383c` | `#e2f6f8` | Group palette slot 5 |
| `FixGroupDepth3B` | `#422630` | `#ffe7ee` | Group palette slot 6 |

Route groups use bold foreground colors; repeating-group groups use background
colors. Group colors advance by depth and entry, then wrap through the palette.

The plugin also reuses standard Neovim groups: `Comment` for default tag and
value annotations, `Operator` in the picker, and `IncSearch` for yank feedback.
FIX syntax highlighting uses the standard tree-sitter captures `@comment`,
`@property`, `@operator`, `@normal`, `@constant`, `@number`,
`@punctuation.delimiter`, and `@none`.

### Cache

The persistent cache stores parsed and decoded messages so repeated sessions can
open large logs faster. It lives at `stdpath("cache")/fix.nvim` unless
`cache.persist.dir` is set.

Set `cache.persist.enabled = false` to keep all cache data in memory only.
`max_files` limits the number of cache files, and `max_bytes` limits their total
size. Set either limit to `false` to disable that specific limit. When
persistence is enabled, at least one rotation limit must remain enabled.

### Rendering

Rendering is viewport-first. The visible region, plus `viewport_margin` lines
above and below it, is annotated immediately after the edit debounce. The rest
of the buffer warms the parse/decode cache in `lines_per_batch` chunks.
Off-screen extmarks are not kept around; annotations are re-applied as you
scroll, which keeps large buffers responsive.

`render.debounce_ms` waits briefly after edits before rendering, which avoids
doing repeated work while a file is still changing. `render.lines_per_batch`
controls the background cache warm-up chunk size. Higher values can warm the
cache faster but may make very large files feel less responsive.

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
  fix.annotate_toggle("title")
end, "toggle title annotation")

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
