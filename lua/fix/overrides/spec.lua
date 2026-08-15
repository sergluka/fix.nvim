--- The whitelist of overridable FixOpts keys, plus indexes and layer order
--- derived from it. Pure data: no dependency on the rest of `fix.overrides`.

local M = {}

---@class FixOverrideSpecEntry
---@field path string             dotted key; modeline key and vim.b/vim.g nested-table path
---@field var string              flat var name for vim.b/vim.g/editorconfig
---@field kind "boolean"|"enum"|"dictionary"|"formatter"
---@field category "annotate"|"lsp"|"dictionary"
---@field content? boolean        true when the key feeds the cache namespace suffix
---@field values? string[]        enum kind only
---@field namespace? "tag"|"value"|"title"  formatter kind only
---@field target? string          formatter kind only: the FixOpts path the resolved fn is placed at
---@field parts string[]          precomputed path split, for nested lookups and overlay writes
---@field target_parts? string[]  precomputed target split, formatter kind only

---@type FixOverrideSpecEntry[]
M.SPEC = {
    { path = "annotate.tag.enabled", var = "fix_annotate_tag_enabled", kind = "boolean", category = "annotate" },
    { path = "annotate.value.enabled", var = "fix_annotate_value_enabled", kind = "boolean", category = "annotate" },
    { path = "annotate.title.enabled", var = "fix_annotate_title_enabled", kind = "boolean", category = "annotate" },
    {
        path = "annotate.title.position",
        var = "fix_annotate_title_position",
        kind = "enum",
        values = { "above", "below", "front", "replace", "replace_front" },
        category = "annotate",
    },
    {
        path = "annotate.group.path.enabled",
        var = "fix_annotate_group_path_enabled",
        kind = "boolean",
        category = "annotate",
        content = true,
    },
    {
        path = "annotate.group.highlight.enabled",
        var = "fix_annotate_group_highlight_enabled",
        kind = "boolean",
        category = "annotate",
    },
    { path = "lsp.enabled", var = "fix_lsp_enabled", kind = "boolean", category = "lsp" },
    { path = "lsp.validate.enabled", var = "fix_lsp_validate_enabled", kind = "boolean", category = "lsp" },
    { path = "lsp.hover.enabled", var = "fix_lsp_hover_enabled", kind = "boolean", category = "lsp" },
    {
        path = "dictionary",
        var = "fix_dictionary",
        kind = "dictionary",
        category = "dictionary",
        content = true,
    },
    {
        path = "formatter.tag",
        var = "fix_formatter_tag",
        kind = "formatter",
        namespace = "tag",
        target = "annotate.tag.formatter",
        category = "annotate",
        content = true,
    },
    {
        path = "formatter.value",
        var = "fix_formatter_value",
        kind = "formatter",
        namespace = "value",
        target = "annotate.value.formatter",
        category = "annotate",
        content = true,
    },
    {
        path = "formatter.title",
        var = "fix_formatter_title",
        kind = "formatter",
        namespace = "title",
        target = "annotate.title.formatter",
        category = "annotate",
        content = true,
    },
}

M.SPEC_BY_PATH = {}
M.SPEC_BY_VAR = {}
for _, entry in ipairs(M.SPEC) do
    entry.parts = vim.split(entry.path, ".", { plain = true })
    if entry.target then
        entry.target_parts = vim.split(entry.target, ".", { plain = true })
    end
    M.SPEC_BY_PATH[entry.path] = entry
    M.SPEC_BY_VAR[entry.var] = entry
end

--- Flat var names in SPEC order — the source of truth for editorconfig
--- registration in `plugin/fix.lua`, so the two cannot drift.
---@type string[]
M.EDITORCONFIG_PROPERTIES = {}
for _, entry in ipairs(M.SPEC) do
    M.EDITORCONFIG_PROPERTIES[#M.EDITORCONFIG_PROPERTIES + 1] = entry.var
end

M.LAYER_ORDER = { "modeline", "vim.b", "editorconfig", "vim.g" }
M.LAYER_ORDER_NO_MODELINE = { "vim.b", "editorconfig", "vim.g" }

return M
