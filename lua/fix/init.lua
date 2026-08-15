-- TODO: competition?
-- TODO: templates?
-- TODO: highlight values based on Type?

---@alias FixTreeFormatterChunk { [1]: string, [2]: string? }
---@alias FixTreeFormatterResult FixTreeFormatterChunk|FixTreeFormatterChunk[]

---@class FixOpts
---@field ft? table
---@field ft.extensions? string[]
---@field ft.pattern? string[]
---@field annotate? table
---@field annotate.group? table
---@field annotate.group.path? table
---@field annotate.group.path.enabled? boolean
---@field annotate.group.highlight? table
---@field annotate.group.highlight.enabled? boolean
---@field annotate.group.highlight.palette? string[]
---@field annotate.group.highlight.target? "raw"|"annotation"|"both"
---@field annotate.tag? table
---@field annotate.tag.enabled? boolean
---@field annotate.tag.formatter? fun(field: Field): {text: string, highlight: string}
---@field annotate.value? table
---@field annotate.value.enabled? boolean
---@field annotate.value.formatter? fun(field: Field): {text: string, highlight: string}
---@field annotate.title? table
---@field annotate.title.enabled? boolean
---@field annotate.title.position? string "above" | "below" | "front" | "replace" | "replace_front"
---@field annotate.title.route? table
---@field annotate.title.route.enabled? boolean
---@field annotate.title.route.mode? string "direction" | "sender" | "pair"
---@field annotate.title.route.palette? string[]
---@field annotate.title.route.overrides? FixRouteRule[]
---@field annotate.title.route.resolver? fun(route: FixRoute, message: Message): string|nil
---@field annotate.title.formatter? fun(message: Message): table
---@field cache? table
---@field cache.persist? table
---@field cache.persist.enabled? boolean
---@field cache.persist.max_files? number|false
---@field cache.persist.max_bytes? number|false
---@field cache.persist.dir? string
---@field render? table
---@field render.debounce_ms? number
---@field render.lines_per_batch? number
---@field render.viewport_margin? number
---@field lsp? table
---@field lsp.enabled? boolean
---@field lsp.validate? table
---@field lsp.validate.enabled? boolean
---@field lsp.validate.debounce_ms? number
---@field lsp.validate.rules? table<string, boolean|FixRuleSpec>
---@field lsp.hover? table
---@field lsp.hover.enabled? boolean
---@field tree? table
---@field tree.summary? table
---@field tree.summary.formatter? fun(message: Message): FixTreeFormatterResult
---@field tree.field? table
---@field tree.field.formatter? fun(field: Field): FixTreeFormatterResult
---@field tree.group? table
---@field tree.group.formatter? fun(group: FixTreeGroup, field: Field): FixTreeFormatterResult
---@field fallback_version? string
---@field dictionaries? table<string|integer, string|FixDictionarySpec>
---@field formatters? table
---@field formatters.tag? table<string, fun(field: Field): {text: string, highlight: string}>
---@field formatters.value? table<string, fun(field: Field): {text: string, highlight: string}>
---@field formatters.title? table<string, fun(message: Message): table>
---@field overrides? table
---@field overrides.modeline? table
---@field overrides.modeline.enabled? boolean
---@field overrides.modeline.allow_paths? boolean

---@class FixDictionarySpec
---@field path? string
---@field mode? "auto"|"repository"|"quickfix"
---@field version? string
---@field name? string
---@field tags? table<number|string, FixTagDecoder>

local Cache = require("fix.cache")
local Consts = require("fix.consts")
local Dictionary = require("fix.dictionary")
local Document = require("fix.document")
local Overrides = require("fix.overrides")
local Persist = require("fix.persist")
local Render = require("fix.render")
local TagFormatter = require("fix.formatters.tag")
local TitleFormatter = require("fix.formatters.title")
local TreeFieldFormatter = require("fix.formatters.tree.field")
local TreeGroupFormatter = require("fix.formatters.tree.group")
local TreeSummaryFormatter = require("fix.formatters.tree.summary")
local Validate = require("fix.validate")
local ValidateRules = require("fix.validate.rules")
local ValueFormatter = require("fix.formatters.value")
local Yank = require("fix.yank")

local M = {}

local builtin_formatters = {
    tag = TagFormatter.default,
    value = ValueFormatter.default,
    title = TitleFormatter.default,
}

local function refresh_tree()
    local tree = package.loaded["fix.neo_tree"]
    if type(tree) == "table" and type(tree.refresh) == "function" then
        tree.refresh()
    end
end

--- Reacts to an overrides diff. Lives here, not in `fix.overrides`, so that
--- module never requires the renderer or validator at load time.
---@param buf number
---@param diff FixOverrideRefreshResult
local function handle_override_change(buf, diff)
    if diff.suffix then
        Render.reset_keys(buf) -- before the rerender, or dead namespace keys get persisted
    end
    if diff.suffix or diff.annotate then
        Render.rerender(buf)
    end
    if diff.annotate then
        -- annotate.title.* changes what the diagnostic virtual_text resolver
        -- would decide; nothing else re-renders it without a fresh publish.
        Validate.refresh_virtual_text()
    end
    if diff.dictionary then
        refresh_tree()
    end
    if diff.lsp then
        Validate.sync(buf)
    end
end

Overrides.on_change(handle_override_change)

local default_settings = {
    fallback_version = Consts.FixVersion.FIX_4_4,
    dictionaries = {},
    formatters = {
        tag = {},
        value = {},
        title = {},
    },
    ft = {
        extensions = { "fix", "fixlog" },
        pattern = { ".*%.fix.txt" },
    },
    annotate = {
        group = {
            path = {
                enabled = true,
            },
            highlight = {
                enabled = true,
                target = "both",
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
        tag = {
            enabled = false,
            formatter = TagFormatter.default,
        },
        value = {
            enabled = false,
            formatter = ValueFormatter.default,
        },
        title = {
            enabled = true,
            position = "above",
            route = {
                enabled = true,
                mode = "direction",
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
                overrides = {},
                resolver = nil,
            },
            formatter = TitleFormatter.default,
        },
    },
    cache = {
        persist = {
            enabled = true,
            max_files = 20,
            max_bytes = 100 * 1024 * 1024,
            dir = nil, -- defaults to stdpath("cache") .. "/fix.nvim" at runtime
        },
    },
    render = {
        debounce_ms = 80,
        lines_per_batch = 500,
        viewport_margin = 50,
    },
    lsp = {
        enabled = true,
        validate = {
            enabled = true,
            debounce_ms = 200,
            rules = {
                begin_string = { enabled = true },
                body_length = { enabled = true },
                checksum = { enabled = true },
            },
        },
        hover = {
            enabled = true,
        },
    },
    tree = {
        summary = {
            formatter = TreeSummaryFormatter.default,
        },
        field = {
            formatter = TreeFieldFormatter.default,
        },
        group = {
            formatter = TreeGroupFormatter.default,
        },
    },
    overrides = {
        modeline = {
            enabled = true,
            -- Off by default: a path here is chosen by whoever wrote the log.
            -- See resolve_dictionary_value in overrides/resolve.lua for the risks.
            allow_paths = false,
        },
    },
}

---@param opts FixOpts
---@param dictionaries? DictionaryRegistries
local function validate_opts(opts, dictionaries)
    if not Dictionary.has_version(opts.fallback_version, dictionaries and dictionaries.by_version) then
        error("fix.nvim: fallback_version has no dictionary: " .. tostring(opts.fallback_version), 2)
    end

    local persist = opts.cache.persist
    local function limit_validator(integer)
        return function(value)
            if value == false then
                return true
            end
            local valid_number = type(value) == "number" and value > 0 and value == value and value < math.huge
            return valid_number and not (integer and value % 1 ~= 0)
        end
    end

    vim.validate("cache.persist.max_files", persist.max_files, limit_validator(true), "false or a positive integer")
    vim.validate("cache.persist.max_bytes", persist.max_bytes, limit_validator(false), "false or a positive number")

    if persist.enabled and persist.max_files == false and persist.max_bytes == false then
        error("fix.nvim: cache.persist.max_files and max_bytes cannot both be false when persistence is enabled", 2)
    end

    for _, name in ipairs({ "summary", "field", "group" }) do
        vim.validate("tree." .. name .. ".formatter", opts.tree[name].formatter, "function")
    end

    vim.validate("overrides.modeline.enabled", opts.overrides.modeline.enabled, "boolean")
    vim.validate("overrides.modeline.allow_paths", opts.overrides.modeline.allow_paths, "boolean")

    for _, namespace in ipairs({ "tag", "value", "title" }) do
        local group = opts.formatters[namespace]
        vim.validate("formatters." .. namespace, group, "table")
        for name, formatter in pairs(group) do
            if name == "default" then
                error("fix.nvim: formatters." .. namespace .. ".default is reserved for the built-in formatter", 2)
            end
            vim.validate("formatters." .. namespace .. "." .. tostring(name), formatter, "function")
        end
    end

    local lsp = opts.lsp
    vim.validate("lsp.enabled", lsp.enabled, "boolean")
    vim.validate("lsp.validate", lsp.validate, "table")
    local validate = lsp.validate
    vim.validate("lsp.validate.enabled", validate.enabled, "boolean")
    vim.validate("lsp.hover", lsp.hover, "table")
    vim.validate("lsp.hover.enabled", lsp.hover.enabled, "boolean")
    vim.validate("lsp.validate.debounce_ms", validate.debounce_ms, function(v)
        return type(v) == "number" and v >= 0 and v == v and v < math.huge
    end, "non-negative finite number")
    vim.validate("lsp.validate.rules", validate.rules, "table")
    for id, entry in pairs(validate.rules) do
        if type(id) ~= "string" then
            error("fix.nvim: lsp.validate.rules must be keyed by rule id", 2)
        end
        local problem = ValidateRules.problem(id, entry)
        if problem then
            error("fix.nvim: " .. problem, 2)
        end
    end

    local function one_of(values)
        local check = function(v)
            return vim.tbl_contains(values, v)
        end
        return check, "'" .. table.concat(values, "'|'") .. "'"
    end
    local function non_empty_string(v)
        return type(v) == "string" and v ~= ""
    end
    local function validate_palette(name, palette)
        vim.validate(name, palette, function(v)
            return type(v) == "table" and #v > 0
        end, "non-empty list of highlight groups")
        for i, group in ipairs(palette) do
            vim.validate(("%s[%d]"):format(name, i), group, non_empty_string, "highlight group name")
        end
    end

    local route = opts.annotate.title.route
    local group_highlight = opts.annotate.group.highlight
    vim.validate(
        "annotate.title.position",
        opts.annotate.title.position,
        one_of({ "above", "below", "front", "replace", "replace_front" })
    )
    vim.validate("annotate.title.route.mode", route.mode, one_of({ "direction", "sender", "pair" }))
    validate_palette("annotate.title.route.palette", route.palette)
    vim.validate("annotate.title.route.overrides", route.overrides, "table")
    for i, rule in ipairs(route.overrides) do
        local prefix = ("annotate.title.route.overrides[%d]"):format(i)
        vim.validate(prefix, rule, "table")
        vim.validate(prefix .. ".sender", rule.sender, "string", true)
        vim.validate(prefix .. ".target", rule.target, "string", true)
        vim.validate(prefix .. ".highlight", rule.highlight, non_empty_string, "highlight group name")
    end
    vim.validate("annotate.title.route.resolver", route.resolver, "function", true)
    validate_palette("annotate.group.highlight.palette", group_highlight.palette)
    vim.validate("annotate.group.highlight.target", group_highlight.target, one_of({ "raw", "annotation", "both" }))
end

local route_highlight_palettes = {
    dark = {
        FixRoute1 = { fg = "#4da3ff", bold = true },
        FixRoute2 = { fg = "#3ecf5f", bold = true },
        FixRoute3 = { fg = "#ffb02e", bold = true },
        FixRoute4 = { fg = "#c678ff", bold = true },
        FixRoute5 = { fg = "#00c8d7", bold = true },
        FixRoute6 = { fg = "#ff5f7a", bold = true },
        FixRoute7 = { fg = "#f0f3ff", bold = true },
        FixRoute8 = { fg = "#ff7a18", bold = true },
    },
    light = {
        FixRoute1 = { fg = "#005fcb", bold = true },
        FixRoute2 = { fg = "#007a33", bold = true },
        FixRoute3 = { fg = "#8a5200", bold = true },
        FixRoute4 = { fg = "#7a2ebf", bold = true },
        FixRoute5 = { fg = "#007c89", bold = true },
        FixRoute6 = { fg = "#b00030", bold = true },
        FixRoute7 = { fg = "#334155", bold = true },
        FixRoute8 = { fg = "#a13f00", bold = true },
    },
}

local group_highlight_palettes = {
    dark = {
        FixGroupDepth1A = { bg = "#243447" },
        FixGroupDepth1B = { bg = "#243b2f" },
        FixGroupDepth2A = { bg = "#3a2d1f" },
        FixGroupDepth2B = { bg = "#332943" },
        FixGroupDepth3A = { bg = "#20383c" },
        FixGroupDepth3B = { bg = "#422630" },
    },
    light = {
        FixGroupDepth1A = { bg = "#e7f0ff" },
        FixGroupDepth1B = { bg = "#e6f5ea" },
        FixGroupDepth2A = { bg = "#fff0d8" },
        FixGroupDepth2B = { bg = "#f0e8ff" },
        FixGroupDepth3A = { bg = "#e2f6f8" },
        FixGroupDepth3B = { bg = "#ffe7ee" },
    },
}

local tree_highlight_links = {
    FixTreeIcon = "Special",
    FixTreeName = "Identifier",
    FixTreeValue = "String",
    FixTreeMeta = "Comment",
    FixTreeOperator = "Operator",
    FixTreeGroup = "Type",
}

---@param spec table
---@return number|nil
local function highlight_fg(spec)
    local fg = spec.fg
    if type(fg) ~= "string" or fg:sub(1, 1) ~= "#" then
        return nil
    end
    return tonumber(fg:sub(2), 16)
end

---@param current table
---@param spec table
---@return boolean
local function same_highlight(current, spec)
    return current.fg == highlight_fg(spec)
        and current.bg == highlight_fg({ fg = spec.bg })
        and current.bold == spec.bold
end

---@param current table
---@return boolean
local function is_default_highlight(current, palettes)
    if vim.tbl_isempty(current) then
        return true
    end
    for _, palette in pairs(palettes) do
        for _, spec in pairs(palette) do
            if same_highlight(current, spec) then
                return true
            end
        end
    end
    return false
end

local function register_highlights()
    for group, link in pairs(tree_highlight_links) do
        vim.api.nvim_set_hl(0, group, { default = true, link = link })
    end

    local route_highlights = route_highlight_palettes[vim.o.background] or route_highlight_palettes.dark
    for group, spec in pairs(route_highlights) do
        local current = vim.api.nvim_get_hl(0, { name = group, link = false })
        if is_default_highlight(current, route_highlight_palettes) then
            vim.api.nvim_set_hl(0, group, spec)
        end
    end

    local group_highlights = group_highlight_palettes[vim.o.background] or group_highlight_palettes.dark
    for group, spec in pairs(group_highlights) do
        local current = vim.api.nvim_get_hl(0, { name = group, link = false })
        if is_default_highlight(current, group_highlight_palettes) then
            vim.api.nvim_set_hl(0, group, spec)
        end
    end
end

local function register_filetype()
    local patterns = {}
    for _, pattern in ipairs(M.opts.ft.pattern) do
        patterns[pattern] = "fix"
    end
    local extensions = {}
    for _, ext in ipairs(M.opts.ft.extensions) do
        extensions[ext] = "fix"
    end
    vim.filetype.add({
        extension = extensions,
        pattern = patterns,
    })
end

local function register_autocmds()
    local group = vim.api.nvim_create_augroup("fix-decorate", { clear = true })

    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "fix",
        callback = function(args)
            -- Must run first: Render.attach loads the persist cache, and the
            -- persist gate is inert until this buffer's override state exists.
            Overrides.attach(args.buf)
            Render.attach(args.buf)
            Validate.attach(args.buf)
        end,
    })

    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = function(args)
            if vim.bo[args.buf].filetype == "fix" then
                Overrides.attach(args.buf)
                Render.attach(args.buf)
                Validate.attach(args.buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
        group = group,
        callback = function(args)
            if vim.bo[args.buf].filetype == "fix" then
                Render.refresh_viewport(args.buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinEnter" }, {
        group = group,
        callback = function(args)
            if vim.bo[args.buf].filetype == "fix" then
                Render.refresh_cursor(args.buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd("BufUnload", {
        group = group,
        callback = function(args)
            if vim.bo[args.buf].filetype == "fix" then
                Render.flush(args.buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            Render.flush_all_sync()
        end,
    })

    vim.api.nvim_create_autocmd("ColorScheme", {
        group = group,
        callback = register_highlights,
    })

    vim.api.nvim_create_autocmd("OptionSet", {
        group = group,
        pattern = "background",
        callback = register_highlights,
    })
end

---@param opts FixOpts
function M.setup(opts)
    local prev_opts = M.opts
    local next_opts = vim.tbl_deep_extend("force", default_settings, vim.deepcopy(opts or {}))
    local dictionaries = Dictionary.prepare(next_opts.dictionaries)
    validate_opts(next_opts, dictionaries)

    local is_resetup = prev_opts ~= nil
    M.opts = next_opts
    M.opts_initial = vim.deepcopy(M.opts)
    local dictionaries_changed = Dictionary.apply(dictionaries)
    ValidateRules.reset(M.opts.lsp.validate.rules)

    register_highlights()
    register_filetype()
    register_autocmds()

    if is_resetup then
        -- Must run before anything below reads Overrides.effective(buf).
        Overrides.refresh_all()
        Validate.reattach_all()
        local dictionaries_invalidated = false
        if
            prev_opts.fallback_version == M.opts.fallback_version
            and vim.deep_equal(prev_opts.dictionaries, M.opts.dictionaries)
            and not dictionaries_changed
        then
            Cache.drop_render()
        else
            Cache.clear()
            dictionaries_invalidated = true
        end
        Render.rerender_all()
        if dictionaries_invalidated then
            refresh_tree()
        end
    end
end

---@param scope? "all" | "tag" | "value" | "title" | "message" | "group"
function M.annotate_toggle(scope)
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].filetype ~= "fix" then
        return
    end

    if scope == "all" or scope == nil then
        local someone_is_enabled = M.opts.annotate.tag.enabled
            or M.opts.annotate.value.enabled
            or M.opts.annotate.title.enabled
            or M.opts.annotate.group.path.enabled
            or M.opts.annotate.group.highlight.enabled

        if someone_is_enabled then
            M.opts_initial = vim.deepcopy(M.opts)
            M.opts.annotate.tag.enabled = false
            M.opts.annotate.value.enabled = false
            M.opts.annotate.title.enabled = false
            M.opts.annotate.group.path.enabled = false
            M.opts.annotate.group.highlight.enabled = false
        else
            M.opts.annotate.tag.enabled = M.opts_initial.annotate.tag.enabled
            M.opts.annotate.value.enabled = M.opts_initial.annotate.value.enabled
            M.opts.annotate.title.enabled = M.opts_initial.annotate.title.enabled
            M.opts.annotate.group.path.enabled = M.opts_initial.annotate.group.path.enabled
            M.opts.annotate.group.highlight.enabled = M.opts_initial.annotate.group.highlight.enabled
        end
    elseif scope == "tag" then
        M.opts.annotate.tag.enabled = not M.opts.annotate.tag.enabled
    elseif scope == "value" then
        M.opts.annotate.value.enabled = not M.opts.annotate.value.enabled
    elseif scope == "title" or scope == "message" then
        M.opts.annotate.title.enabled = not M.opts.annotate.title.enabled
    elseif scope == "group" then
        local group = M.opts.annotate.group
        if group.path.enabled or group.highlight.enabled then
            group.path.enabled = false
            group.highlight.enabled = false
        else
            group.path.enabled = M.opts_initial.annotate.group.path.enabled
            group.highlight.enabled = M.opts_initial.annotate.group.highlight.enabled
        end
        Cache.drop_render()
    end

    Render.rerender(buf)
end

--- Turn the whole LSP subsystem (diagnostics, fixes, hover) on or off.
function M.lsp_toggle()
    local enabled = not M.opts.lsp.enabled
    M.opts.lsp.enabled = enabled
    Validate.sync_all()
    vim.notify("fix.nvim: LSP features " .. (enabled and "enabled" or "disabled"), vim.log.levels.INFO)
end

local online_versions = {
    [Consts.FixVersion.FIX_2_7] = "2.7",
    [Consts.FixVersion.FIX_3_0] = "3.0",
    [Consts.FixVersion.FIX_4_0] = "4.0",
    [Consts.FixVersion.FIX_4_1] = "4.1",
    [Consts.FixVersion.FIX_4_2] = "4.2",
    [Consts.FixVersion.FIX_4_3] = "4.3",
    [Consts.FixVersion.FIX_4_4] = "4.4",
    [Consts.FixVersion.FIX_5_0] = "5.0",
    ["FIX.5.0"] = "5.0",
    ["FIX.5.0SP1"] = "5.0",
    ["FIX.5.0SP2"] = "5.0",
}

-- TODO: support custom URLs
---@param version string
---@param tag number
---@return string|nil url nil for an unknown version
function M.tag_url(version, tag)
    local online_version = online_versions[version]
    if not online_version or type(tag) ~= "number" then
        return nil
    end
    return string.format("https://www.onixs.biz/fix-dictionary/%s/tagNum_%d.html", online_version, tag)
end

---@param version string
---@param tag number
---@return boolean opened
function M.open_tag_online(version, tag)
    local url = M.tag_url(version, tag)
    if not url then
        return false
    end
    vim.ui.open(url)
    return true
end

function M.browse_tag_online()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].filetype ~= "fix" then
        return
    end
    local message, field = Document.get_field_under_cursor(buf)
    if message == nil or field == nil then
        return
    end
    M.open_tag_online(message.version, field.tag)
end

--- Drop all cached annotation data for the current file and re-render.
function M.cache_clear()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].filetype ~= "fix" then
        return
    end
    Persist.delete(buf)
    Cache.clear()
    Render.purge(buf)
    refresh_tree()
end

---@param value any
---@param kind "boolean"|"enum"|"dictionary"|"formatter"
---@return string
local function describe_override_value(value, kind)
    if kind == "dictionary" then
        return value.name or value.source.version
    end
    if kind == "formatter" then
        return value.name
    end
    return tostring(value)
end

--- `:FIX overrides show`: winning value and layer per key, plus parse
--- warnings. A diagnostic for "why is this buffer different", not an API.
function M.overrides_show()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].filetype ~= "fix" then
        vim.notify("fix.nvim: not a FIX buffer", vim.log.levels.WARN)
        return
    end

    local info = Overrides.describe(buf)
    if vim.tbl_isempty(info.overrides) and vim.tbl_isempty(info.warnings) then
        vim.notify("fix.nvim: no overrides in effect for this buffer", vim.log.levels.INFO)
        return
    end

    local paths = vim.tbl_keys(info.overrides)
    table.sort(paths)
    local lines = { string.format("fix.nvim overrides (buffer %d):", buf) }
    for _, path in ipairs(paths) do
        local entry = info.overrides[path]
        lines[#lines + 1] =
            string.format("  %s = %s  [%s]", path, describe_override_value(entry.value, entry.kind), entry.layer)
    end
    for _, warning in ipairs(info.warnings) do
        lines[#lines + 1] = "  warning: " .. warning.text
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- `:FIX overrides refresh`: the documented way to apply a `:let b:fix_* =
--- ...` mid-session (mutating `vim.b` isn't observable) or to pick up a
--- dictionary XML edited on disk.
function M.overrides_refresh()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].filetype ~= "fix" then
        vim.notify("fix.nvim: not a FIX buffer", vim.log.levels.WARN)
        return
    end
    Overrides.refresh(buf)
    vim.notify("fix.nvim: overrides refreshed", vim.log.levels.INFO)
end

--- `default` resolves to the built-in formatter; an unknown name returns nil.
---@param namespace "tag"|"value"|"title"
---@param name string
---@return function|nil
function M.resolve_formatter(namespace, name)
    if name == "default" then
        return builtin_formatters[namespace]
    end
    local group = M.opts.formatters[namespace]
    return group and group[name]
end

---@param path string
function M.use_dictionary(path)
    local source = Dictionary.register(path)
    Cache.clear()
    Render.rerender_all()
    refresh_tree()
    vim.notify(
        string.format("fix.nvim: using custom FIX dictionary %s from %s", source.version, source.path),
        vim.log.levels.INFO
    )
    return source
end

---@param regname string?
---@param selection? FixYankSelection
function M.yank(regname, selection)
    Yank.yank(Overrides.effective(vim.api.nvim_get_current_buf()), regname, selection)
end

---@param motion_type string
function M.operator_yank(motion_type)
    Yank.operator_yank(Overrides.effective(vim.api.nvim_get_current_buf()), motion_type)
end

---@param regname string?
---@return string
function M.operator_yank_register(regname)
    vim.b.fix_yank_operator_register = regname or ""
    vim.go.operatorfunc = "v:lua.require'fix'.operator_yank"
    return "g@"
end

return M
