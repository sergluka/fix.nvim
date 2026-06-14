# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Neovim plugin for viewing FIX protocol messages. Runtime dependencies: `xml2lua`, `mega.cmdparse`, `mega.logging`, optional `snacks.nvim`, plus the [tree-sitter-fix](https://github.com/sergluka/tree-sitter-fix) parser (master branch only).

## Commands

- Run integration tests: `./bin/test-integration` (builds Podman image on first run, then runs the full MiniTest suite — 67 cases inside `tests/integration/`). Single spec: `./bin/test-integration --filter annotate` (resolves to `tests/integration/test_<name>.lua` via `MiniTest.run_file`). Force image rebuild: `./bin/test-integration --rebuild`. Requires Podman >= 5.x.
- Lint: `luacheck .` (config in `.luacheckrc` — Lua 5.1, `vim` global).
- Format: `stylua --check .` (pinned to stylua 2.3.0 — match locally; CI enforces this exact version).
- CI (`.github/workflows/ci.yml`) runs `stylua --check .` + `luacheck` on host and the Podman integration suite on every push/PR.

## Architecture

The plugin decorates FIX-message buffers with extmark-based virtual text; it does not modify the buffer. Data flows in one direction per render: `FileType/BufWinEnter → render.attach; on_lines → render (debounce/warm-up) → cache → document.build_line → annotate.apply → extmarks`.

- `plugin/fix.lua` — entrypoint loaded by Neovim. Registers the tree-sitter parser config, builds the `:FIX` user command via `mega.cmdparse`, and dispatches subcommands (`annotations`, `picker`, `browse`, `yank`, `cache`) to `require("fix")`.
- `ftplugin/fix.lua` — buffer-local options for `filetype=fix` (conceallevel, iskeyword excluding `|` and `=`, `# %s` commentstring).
- `lua/fix/init.lua` — `setup()` deep-merges user opts over `default_settings`, registers filetype patterns/extensions, and wires an autocmd group `fix-decorate` that calls `Render.attach` on `FileType`/`BufWinEnter` and `Render.refresh_viewport` on scroll/resize. Also holds `opts_initial` so toggling "all off → all on" restores the user's per-scope enabled flags. Re-running `setup()` drops the render cache and re-renders all open buffers. Exposes `cache_clear()` for `:FIX cache clear`. New options blocks: `cache.persist` and `render`.
- `lua/fix/document.lua` — tree-sitter traversal. `build_line(buf, lnum)` is the primary incremental path: parses the single line, checks the two-layer cache, and calls `decode()` only on cache misses. `iter_messages` is a thin whole-buffer wrapper over `build_line` kept as public API; the snacks picker streams via `build_line` directly and yank goes through `get_field_under_cursor`. Detects the dictionary version from tag 8 (BeginString). Duplicate tags within a message are keyed as `tag:index` in a side-slot (groups are not yet first-class — see TODO in `init.lua`).
- `lua/fix/dictionary.lua` — `Dictionary.load(version)` parses `xml/<version>/Base/{Fields,Enums}.xml` via `xml2lua` and caches per-version dictionaries in `M._cache`. `FIXT.1.1` transparently resolves to `FIX.5.0SP2`. Messages are looked up via tag-35 enum (`dict:message(value)`).
- `lua/fix/annotate.lua` — writes extmarks into namespace `fix-protocol`: inline virt_text after the tag, inline virt_text after the value, and message titles as `virt_lines` (`above`/`below`) or inline virt_text at column 0 (`front`). `build_payload` assembles a `FixRenderPayload` for a message (all kinds, enabled flags not applied). `payload_for` wraps it with the render cache. `apply` does a point-clear on the message line then sets only the extmarks whose kind is currently enabled — so toggling annotation scopes never invalidates cached payloads. Titles with `position="below"` anchor on the message line via `virt_lines_above=false`.
- `lua/fix/cache.lua` — two-layer in-memory cache, both layers keyed by the same line-content hash (`M.key(line_text)`, shared across buffers): a semantic layer and a render-payload layer. `drop_render()` evicts only the render layer, used on re-setup.
- `lua/fix/render.lua` — viewport-first non-blocking scheduler. `attach(buf)` hooks `nvim_buf_attach` (`on_lines`) with an 80 ms debounce. The visible viewport (± `viewport_margin`) is annotated immediately and re-applied on scroll (`refresh_viewport`); background warm-up only fills the parse/decode cache in `lines_per_batch`-sized batches and never places off-screen extmarks, so the placed-mark count is always bounded by what's been viewed. `flush`/`flush_all_sync` drain pending writes on `BufUnload`/`VimLeavePre`.
- `lua/fix/persist.lua` — mpack-based disk cache under `stdpath("cache")/fix.nvim`. Keyed by absolute path + dict fingerprint; stale entries are invalidated automatically. LRU eviction at `max_files=20`. Writes are atomic (tmp file + rename). Exposed to users via `:FIX cache clear` → `M.delete(buf)`.
- `lua/fix/field.lua` / `lua/fix/message.lua` — plain data classes reconstructed from cached semantic tables.
- `lua/fix/formatters/{tag,value,message}.lua` — default formatters returning `{text, highlight}` (fields) or `{line = {text, highlight}}` (message title). User-supplied formatters must match these shapes; they're invoked from `annotate.lua`.
- `lua/fix/snacks.lua` — optional picker UI (requires `snacks.nvim`).
- `lua/fix/yank.lua` — smart yank helpers used by `:FIX yank [--reg=<r>]` and the operatorfunc API.
- `lua/fix/consts.lua` — `FixVersion` enum used as the canonical internal version key (tree-sitter BeginString strings are mapped to it in `document.lua`).
- `queries/fix/{highlights,textobjects}.scm` — tree-sitter queries shipped with the plugin.
- `xml/FIX.*` — vendored FIX Repository data (© FIX Protocol Limited, used under licence — see `plugin/fix.lua` header and `THIRD_PARTY_LICENSES.txt`). Do not regenerate by hand.
- `samples/` — `.fix` files for manual testing in Neovim.
- `tests/integration/` — MiniTest specs (`test_dictionary`, `test_annotate`, `test_commands`, `test_lifecycle`, `test_edge_cases`, `test_cache`, `test_persist`, `test_picker`) — 67 cases total — driven by `tests/integration/run.lua`. Bootstrap via `tests/integration/minimal_init.lua`; shared helpers in `tests/integration/helpers.lua` (key patterns: `wait_annotated` polls `require("fix.render").is_idle()`, and `load_fixture` asserts extmarks afterwards); fixtures under `tests/integration/fixtures/`. The whole suite runs inside the Podman image built from `Containerfile`.
- `Containerfile` — multi-stage Podman image: builder compiles `tree-sitter-fix` and clones Lua deps at hardcoded SHAs; runtime carries Neovim 0.12.0 + `fix.so` + `/opt/deps/*`. SHAs are string literals (no `ARG`).
- `bin/test-integration` — wrapper that builds the image on demand and runs the suite; supports `--rebuild` and `--filter <pattern>`.

## Conventions

- Lua 5.1, 4-space indentation (configured in `stylua.toml`). Keep `---@class` / `---@field` annotations in sync with `FixOpts` in `init.lua` when adding options.
- New options must be added to `default_settings` in `init.lua` AND to the `FixOpts` annotation; downstream code reads them through the merged `M.opts`.
- When adding a FIX version: drop `Fields.xml`/`Enums.xml` under `xml/FIX.<ver>/Base/`, add it to `Consts.FixVersion` and to the `versions` maps in both `document.lua` and `init.lua`'s `browse_tag_online`, and extend the version list in `tests/integration/test_dictionary.lua`.
- Tests should load dictionaries via `Subject.load(...)` rather than stubbing XML.
