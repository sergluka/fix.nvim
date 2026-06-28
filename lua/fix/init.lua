-- TODO: support groups
-- TODO: competition?
-- TODO: validation?
-- TODO: highlight values based on Type

---@class FixOpts
---@field ft? table
---@field ft.extensions? string[]
---@field ft.pattern? string[]
---@field annotate? table
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
---@field annotate.message? table Deprecated alias for annotate.title.
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
---@field fallback_version? string
---@field dictionaries? table<string|integer, string|FixDictionarySpec>

---@class FixDictionarySpec
---@field path? string
---@field mode? "auto"|"repository"|"quickfix"
---@field version? string
---@field tags? table<number|string, FixTagDecoder>

local Cache = require("fix.cache")
local Consts = require("fix.consts")
local Dictionary = require("fix.dictionary")
local Document = require("fix.document")
local TitleFormatter = require("fix.formatters.title")
local Persist = require("fix.persist")
local Render = require("fix.render")
local TagFormatter = require("fix.formatters.tag")
local ValueFormatter = require("fix.formatters.value")
local Yank = require("fix.yank")

local M = {}

local default_settings = {
    fallback_version = Consts.FixVersion.FIX_4_4,
    dictionaries = {},
    ft = {
        extensions = { "fix", "fixlog" },
        pattern = { ".*%.fix.txt" },
    },
    annotate = {
        tag = {
            enabled = true,
            formatter = TagFormatter.default,
        },
        value = {
            enabled = true,
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
}

---@param opts FixOpts|nil
---@return FixOpts
local function normalize_opts(opts)
    local normalized = vim.deepcopy(opts or {})
    local annotate = normalized.annotate
    -- TODO: remove this later
    if type(annotate) == "table" and annotate.message ~= nil then
        vim.notify_once("fix.nvim: annotate.message is deprecated; use annotate.title", vim.log.levels.WARN)
        if annotate.title == nil then
            annotate.title = annotate.message
        end
        annotate.message = nil
    end
    return normalized
end

---@param opts FixOpts
---@param dictionaries? DictionaryRegistry
local function validate_opts(opts, dictionaries)
    if not Dictionary.has_version(opts.fallback_version, dictionaries) then
        error("fix.nvim: fallback_version has no dictionary: " .. tostring(opts.fallback_version), 2)
    end

    local persist = opts.cache.persist
    local function validate_limit(name, value, integer)
        if value == false then
            return
        end
        local valid_number = type(value) == "number" and value > 0 and value == value and value < math.huge
        if not valid_number or (integer and value % 1 ~= 0) then
            local kind = integer and "positive integer" or "positive number"
            error("fix.nvim: cache.persist." .. name .. " must be false or a " .. kind, 2)
        end
    end

    validate_limit("max_files", persist.max_files, true)
    validate_limit("max_bytes", persist.max_bytes, false)

    if persist.enabled and persist.max_files == false and persist.max_bytes == false then
        error("fix.nvim: cache.persist.max_files and max_bytes cannot both be false when persistence is enabled", 2)
    end

    local route = opts.annotate.title.route
    local title_position = opts.annotate.title.position
    if
        title_position ~= "above"
        and title_position ~= "below"
        and title_position ~= "front"
        and title_position ~= "replace"
        and title_position ~= "replace_front"
    then
        error("fix.nvim: annotate.title.position must be 'above', 'below', 'front', 'replace', or 'replace_front'", 2)
    end
    if route.mode ~= "direction" and route.mode ~= "sender" and route.mode ~= "pair" then
        error("fix.nvim: annotate.title.route.mode must be 'direction', 'sender', or 'pair'", 2)
    end
    if type(route.palette) ~= "table" or #route.palette == 0 then
        error("fix.nvim: annotate.title.route.palette must contain at least one highlight group", 2)
    end
    for _, group in ipairs(route.palette) do
        if type(group) ~= "string" or group == "" then
            error("fix.nvim: annotate.title.route.palette must contain highlight group names", 2)
        end
    end
    if type(route.overrides) ~= "table" then
        error("fix.nvim: annotate.title.route.overrides must be a list", 2)
    end
    for _, rule in ipairs(route.overrides) do
        if type(rule) ~= "table" then
            error("fix.nvim: annotate.title.route.overrides entries must be tables", 2)
        end
        if rule.sender ~= nil and type(rule.sender) ~= "string" then
            error("fix.nvim: annotate.title.route.overrides sender must be a string", 2)
        end
        if rule.target ~= nil and type(rule.target) ~= "string" then
            error("fix.nvim: annotate.title.route.overrides target must be a string", 2)
        end
        if type(rule.highlight) ~= "string" or rule.highlight == "" then
            error("fix.nvim: annotate.title.route.overrides highlight must be a highlight group", 2)
        end
    end
    if route.resolver ~= nil and type(route.resolver) ~= "function" then
        error("fix.nvim: annotate.title.route.resolver must be a function", 2)
    end
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
    return current.fg == highlight_fg(spec) and current.bold == spec.bold
end

---@param current table
---@return boolean
local function is_default_route_highlight(current)
    if vim.tbl_isempty(current) then
        return true
    end
    for _, palette in pairs(route_highlight_palettes) do
        for _, spec in pairs(palette) do
            if same_highlight(current, spec) then
                return true
            end
        end
    end
    return false
end

local function register_highlights()
    local route_highlights = route_highlight_palettes[vim.o.background] or route_highlight_palettes.dark
    for group, spec in pairs(route_highlights) do
        local current = vim.api.nvim_get_hl(0, { name = group, link = false })
        if is_default_route_highlight(current) then
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
            Render.attach(args.buf)
        end,
    })

    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = function(args)
            if vim.bo[args.buf].filetype == "fix" then
                Render.attach(args.buf)
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
    local next_opts = vim.tbl_deep_extend("force", default_settings, normalize_opts(opts))
    local dictionaries = Dictionary.prepare(next_opts.dictionaries)
    validate_opts(next_opts, dictionaries)

    local is_resetup = prev_opts ~= nil
    M.opts = next_opts
    M.opts_initial = vim.deepcopy(M.opts)
    local dictionaries_changed = Dictionary.apply(dictionaries)

    register_highlights()
    register_filetype()
    register_autocmds()

    if is_resetup then
        if
            prev_opts.fallback_version == M.opts.fallback_version
            and vim.deep_equal(prev_opts.dictionaries, M.opts.dictionaries)
            and not dictionaries_changed
        then
            Cache.drop_render()
        else
            Cache.clear()
        end
        Render.rerender_all()
    end
end

---@param scope? "all" | "tag" | "value" | "title" | "message"
function M.annotate_toggle(scope)
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].filetype ~= "fix" then
        return
    end

    if scope == "all" or scope == nil then
        local someone_is_enabled = M.opts.annotate.tag.enabled
            or M.opts.annotate.value.enabled
            or M.opts.annotate.title.enabled

        if someone_is_enabled then
            M.opts_initial = vim.deepcopy(M.opts)
            M.opts.annotate.tag.enabled = false
            M.opts.annotate.value.enabled = false
            M.opts.annotate.title.enabled = false
        else
            M.opts.annotate.tag.enabled = M.opts_initial.annotate.tag.enabled
            M.opts.annotate.value.enabled = M.opts_initial.annotate.value.enabled
            M.opts.annotate.title.enabled = M.opts_initial.annotate.title.enabled
        end
    elseif scope == "tag" then
        M.opts.annotate.tag.enabled = not M.opts.annotate.tag.enabled
    elseif scope == "value" then
        M.opts.annotate.value.enabled = not M.opts.annotate.value.enabled
    elseif scope == "title" or scope == "message" then
        M.opts.annotate.title.enabled = not M.opts.annotate.title.enabled
    end

    Render.rerender(buf)
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

    local versions = {
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
    vim.ui.open(
        string.format("https://www.onixs.biz/fix-dictionary/%s/tagNum_%d.html", versions[message.version], field.tag)
    )
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
end

---@param path string
function M.use_dictionary(path)
    local source = Dictionary.register(path)
    Cache.clear()
    Render.rerender_all()
    vim.notify(
        string.format("fix.nvim: using custom FIX dictionary %s from %s", source.version, source.path),
        vim.log.levels.INFO
    )
    return source
end

---@param regname string?
---@param selection? FixYankSelection
function M.yank(regname, selection)
    Yank.yank(M.opts, regname, selection)
end

---@param motion_type string
function M.operator_yank(motion_type)
    Yank.operator_yank(M.opts, motion_type)
end

---@param regname string?
---@return string
function M.operator_yank_register(regname)
    vim.b.fix_yank_operator_register = regname or ""
    vim.go.operatorfunc = "v:lua.require'fix'.operator_yank"
    return "g@"
end

return M
