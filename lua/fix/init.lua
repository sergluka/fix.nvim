-- TODO: support groups
-- TODO: formatting for sender/receiver
-- TODO: add option for custom tags
-- TODO: line-wise conceal (with custom formatting)
-- TODO: competition?
-- TODO: validation?
-- TODO: docs: Explain issue about 0th line [https://github.com/neovim/neovim/issues/16166]
-- TODO: vimdoc
-- TODO: CI: busted, linter
-- TODO: yank in picker
-- TODO: highlight values based on Type

-- testing:
-- TODO: test with spaces at the start

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
---@field annotate.message? table
---@field annotate.message.enabled? boolean
---@field annotate.message.position? string "above" | "below" | "front"
---@field annotate.message.formatter? fun(message: Message): {line: {text: string, highlight: string}}
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
---@field dictionaries? table<string|integer, string|{path: string, mode?: "auto"|"repository"|"quickfix", version?: string}>

local Cache = require("fix.cache")
local Consts = require("fix.consts")
local Dictionary = require("fix.dictionary")
local Document = require("fix.document")
local MessageFormatter = require("fix.formatters.message")
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
        message = {
            enabled = true,
            position = "above",
            formatter = MessageFormatter.default,
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

---@param opts FixOpts
---@param dictionaries? table
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
end

---@param opts FixOpts
function M.setup(opts)
    local prev_opts = M.opts
    local next_opts = vim.tbl_deep_extend("force", default_settings, opts or {})
    local dictionaries = Dictionary.prepare(next_opts.dictionaries)
    validate_opts(next_opts, dictionaries)

    local is_resetup = prev_opts ~= nil
    M.opts = next_opts
    M.opts_initial = vim.deepcopy(M.opts)
    local dictionaries_changed = Dictionary.apply(dictionaries)

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

---@param scope? "all" | "tag" | "value" | "message"
function M.annotate_toggle(scope)
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].filetype ~= "fix" then
        return
    end

    if scope == "all" or scope == nil then
        local someone_is_enabled = M.opts.annotate.tag.enabled
            or M.opts.annotate.value.enabled
            or M.opts.annotate.message.enabled

        if someone_is_enabled then
            M.opts_initial = vim.deepcopy(M.opts)
            M.opts.annotate.tag.enabled = false
            M.opts.annotate.value.enabled = false
            M.opts.annotate.message.enabled = false
        else
            M.opts.annotate.tag.enabled = M.opts_initial.annotate.tag.enabled
            M.opts.annotate.value.enabled = M.opts_initial.annotate.value.enabled
            M.opts.annotate.message.enabled = M.opts_initial.annotate.message.enabled
        end
    elseif scope == "tag" then
        M.opts.annotate.tag.enabled = not M.opts.annotate.tag.enabled
    elseif scope == "value" then
        M.opts.annotate.value.enabled = not M.opts.annotate.value.enabled
    elseif scope == "message" then
        M.opts.annotate.message.enabled = not M.opts.annotate.message.enabled
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
