--- Per-buffer overrides of a whitelisted subset of FixOpts.
--- See `:h fix.nvim-overrides` for layer precedence and naming grammar.
---
--- Two inversions worth knowing: `M.on_change` lets fix/init.lua react to a
--- diff, so this module never requires the renderer or validator; and
--- `plugin/fix.lua`, not this file, registers the editorconfig properties.

local Dictionary = require("fix.dictionary")
local Resolve = require("fix.overrides.resolve")
local Scan = require("fix.scan")
local Spec = require("fix.overrides.spec")
local Suffix = require("fix.overrides.suffix")

local M = {}

M.EDITORCONFIG_PROPERTIES = Spec.EDITORCONFIG_PROPERTIES
M.validate_editorconfig = Resolve.validate_editorconfig

local MODELINE_LINES = 5
local MODELINE_PATTERN = "^%s*#%s*fix:%s*(.*)$"
local MODELINE_RESCAN_MS = 200

local function fix()
    return require("fix")
end

---@class FixOverrideState
---@field attached boolean
---@field listener_registered boolean         nvim_buf_attach listener is live; survives detach
---@field resolved table<string, FixOverrideResolved>
---@field warnings table[]
---@field affects_opts boolean               any resolved key outside "dictionary" (effective() must overlay)
---@field cache_suffix string|nil
---@field persist_excluded boolean
---@field modeline_pairs table<string, string>
---@field modeline_timer? uv.uv_timer_t
---@field dictionary_fingerprint_key? string
---@field dictionary_fingerprint? string

local states = {} ---@type table<number, FixOverrideState>

local editorconfig_refresh_pending = {} ---@type table<number, boolean>

--- Set once by fix/init.lua; keeps this module free of a load-time require
--- on the renderer and validator.
---@type fun(buf: number, diff: FixOverrideRefreshResult)?
local change_handler

---@return FixOverrideState
local function new_state()
    return {
        attached = false,
        listener_registered = false,
        resolved = {},
        warnings = {},
        affects_opts = false,
        cache_suffix = nil,
        persist_excluded = false,
        modeline_pairs = {},
    }
end

-- Modeline -------------------------------------------------------------

---@param payload string
---@return table<string, string>
local function parse_modeline_pairs(payload)
    local map = {}
    for chunk in vim.gsplit(payload, ",", { plain = true }) do
        local key, value = chunk:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
        if key and key ~= "" then
            map[key] = value
        end
    end
    return map
end

--- The first `# fix:` line wins even when its payload has no `=` at all:
--- it contributes no pairs but still ends the scan.
---@param buf number
---@return table<string, string>
local function scan_modeline(buf)
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, MODELINE_LINES, false)
    if not ok then
        return {}
    end
    for _, line in ipairs(lines) do
        local payload = line:match(MODELINE_PATTERN)
        if payload then
            return parse_modeline_pairs(payload)
        end
    end
    return {}
end

-- Refresh --------------------------------------------------------------

---@param buf number
---@param state FixOverrideState
---@return FixOverrideRefreshResult
local function do_refresh(buf, state)
    local modeline_enabled = fix().opts.overrides.modeline.enabled
    local layers = Spec.LAYER_ORDER_NO_MODELINE
    if modeline_enabled then
        state.modeline_pairs = scan_modeline(buf)
        layers = Spec.LAYER_ORDER
    else
        state.modeline_pairs = {}
    end

    local warnings = {}
    if modeline_enabled then
        for key, value in pairs(state.modeline_pairs) do
            if not Spec.SPEC_BY_PATH[key] then
                Resolve.record_warning(warnings, buf, "modeline", key, value, "unknown key")
            end
        end
    end

    local resolved = {}
    local affects_opts = false
    for _, entry in ipairs(Spec.SPEC) do
        local result = Resolve.resolve_entry(entry, buf, state, warnings, layers)
        if result then
            resolved[entry.path] = result
            if entry.kind ~= "dictionary" then
                affects_opts = true
            end
        end
    end

    local dict_entry = resolved["dictionary"]
    local dict_fp = dict_entry and Dictionary.source_fingerprint(dict_entry.value.source) or nil

    Suffix.check_dictionary_instance(state, dict_entry, dict_fp)

    local suffix, persist_excluded = Suffix.compute_cache_suffix(resolved, dict_fp)

    local diff = Suffix.compute_diff(state.resolved, resolved)
    if suffix ~= state.cache_suffix then
        diff.suffix = true
        diff.changed = true
    end

    state.resolved = resolved
    state.warnings = warnings
    state.affects_opts = affects_opts
    state.cache_suffix = suffix
    state.persist_excluded = persist_excluded

    if change_handler and diff.changed then
        change_handler(buf, diff)
    end

    return diff
end

--- Every refresh path converges on `do_refresh`, so one handler covers
--- modeline edits, reload rescans, `refresh_all` and `:FIX overrides refresh`.
---@param fn fun(buf: number, diff: FixOverrideRefreshResult)
function M.on_change(fn)
    change_handler = fn
end

--- Recompute every layer and diff against the previous resolution.
--- A buffer that was never attached returns an all-false diff.
---@param buf number
---@return FixOverrideRefreshResult
function M.refresh(buf)
    local state = states[buf]
    if not state then
        return { changed = false, annotate = false, lsp = false, dictionary = false, suffix = false }
    end
    return do_refresh(buf, state)
end

--- Nvim assigns `vim.b[buf].editorconfig` — the table the editorconfig layer
--- reads — only after every property callback for the file has run, so
--- refreshing from inside one would see the previous, stale table.
--- `vim.schedule` defers past that pass; the pending flag collapses all of
--- the file's callbacks into a single refresh.
---@param buf number
function M.schedule_editorconfig_refresh(buf)
    if editorconfig_refresh_pending[buf] then
        return
    end
    editorconfig_refresh_pending[buf] = true
    vim.schedule(function()
        editorconfig_refresh_pending[buf] = nil
        if vim.api.nvim_buf_is_valid(buf) then
            M.refresh(buf)
        end
    end)
end

local function schedule_modeline_rescan(buf)
    local state = states[buf]
    if not state then
        return
    end
    Scan.close_timer(state.modeline_timer)
    state.modeline_timer = vim.defer_fn(function()
        state.modeline_timer = nil
        if not vim.api.nvim_buf_is_valid(buf) or states[buf] ~= state or not state.attached then
            return
        end
        local new_pairs = scan_modeline(buf)
        if not vim.deep_equal(new_pairs, state.modeline_pairs) then
            M.refresh(buf)
        end
    end, MODELINE_RESCAN_MS)
end

--- Keyed on `attached` rather than on state's existence: an editorconfig
--- callback can create state before attach, and an early return would then
--- skip the modeline scan and the buf_attach.
---@param buf number
function M.attach(buf)
    local state = states[buf]
    if state and state.attached then
        return
    end
    if not state then
        state = new_state()
        states[buf] = state
    end
    state.attached = true

    do_refresh(buf, state)

    -- Nvim drops a listener only when on_lines returns true or the buffer is
    -- wiped, and `detach` does neither on purpose — so a detach/attach cycle
    -- with no edit in between must not register a second one.
    if not state.listener_registered then
        state.listener_registered = true
        vim.api.nvim_buf_attach(buf, false, {
            on_lines = function(_, b, _, first)
                local current = states[b]
                if not current then
                    return true -- state is gone for good; drop the listener too
                end
                if not current.attached then
                    return -- dormant: keep the listener, do no work
                end
                if first < MODELINE_LINES then
                    vim.schedule(function()
                        local st = states[b]
                        if st and st.attached and fix().opts.overrides.modeline.enabled then
                            schedule_modeline_rescan(b)
                        end
                    end)
                end
            end,
            on_reload = function(_, b)
                vim.schedule(function()
                    local st = states[b]
                    if st and st.attached then
                        M.refresh(b)
                    end
                end)
            end,
            on_detach = function(_, b)
                local st = states[b]
                if st then
                    st.listener_registered = false
                end
                M.detach(b)
            end,
        })
    end

    -- Catches FileType/editorconfig work landing after this synchronous scan.
    vim.schedule(function()
        local st = states[buf]
        if vim.api.nvim_buf_is_valid(buf) and st == state and st.attached then
            M.refresh(buf)
        end
    end)
end

--- Re-resolves every attached buffer; used after `setup()` re-runs.
function M.refresh_all()
    for buf, state in pairs(states) do
        if state.attached and vim.api.nvim_buf_is_valid(buf) then
            M.refresh(buf)
        end
    end
end

--- Pauses modeline watching but keeps the resolved state and leaves the
--- listener dormant: a reload can detach the buffer watcher without
--- `on_reload` firing, and a still-valid `filetype=fix` buffer must not lose
--- its overrides for that.
---@param buf number
function M.detach(buf)
    local state = states[buf]
    if not state then
        return
    end
    state.attached = false
    Scan.close_timer(state.modeline_timer)
    state.modeline_timer = nil
end

--- The merged view. Without overrides this is `require("fix").opts` itself,
--- so the common case costs nothing. Never cached: `annotate_toggle` mutates
--- the global opts in place and a stored overlay would go stale.
---@param buf number
---@return FixOpts
function M.effective(buf)
    local opts = fix().opts
    local state = states[buf]
    if not state or not state.affects_opts then
        return opts
    end

    local overlay = {}
    for k, v in pairs(opts) do
        overlay[k] = v
    end

    local clones = {}
    local function set_path(parts, value)
        local node = overlay
        local src = opts
        for i = 1, #parts - 1 do
            local key = parts[i]
            local original = src[key]
            local clone = clones[original]
            if not clone then
                clone = {}
                for k, v in pairs(original) do
                    clone[k] = v
                end
                clones[original] = clone
            end
            node[key] = clone
            node = clone
            src = original
        end
        node[parts[#parts]] = value
    end

    for _, entry in ipairs(Spec.SPEC) do
        local resolved = state.resolved[entry.path]
        if resolved then
            if entry.kind == "formatter" then
                set_path(entry.target_parts, resolved.value.fn)
            elseif entry.kind ~= "dictionary" then
                set_path(entry.parts, resolved.value)
            end
        end
    end

    return overlay
end

--- nil without a content override, else 32 hex chars matching `Cache.key`'s width.
---@param buf number
---@return string|nil
function M.cache_suffix(buf)
    local state = states[buf]
    return state and state.cache_suffix or nil
end

--- Dictionary overrides carrying Lua tag decoders have process-local
--- identity, so their entries must never touch the on-disk cache.
---@param buf number
---@return boolean
function M.persist_excluded(buf)
    local state = states[buf]
    return state ~= nil and state.persist_excluded == true
end

---@param buf number
---@return DictionarySource|nil
function M.dictionary_source(buf)
    local state = states[buf]
    local entry = state and state.resolved["dictionary"]
    return entry and entry.value.source or nil
end

--- The buffer's override wins when its version matches the message's,
--- alias-aware both ways (a FIXT.1.1 message against a FIX.5.0SP2 override);
--- otherwise normal version-keyed resolution.
---@param buf number
---@param version string
---@return Dictionary?
function M.dictionary_for(buf, version)
    local source = M.dictionary_source(buf)
    if source and Dictionary.resolve_version(version) == Dictionary.resolve_version(source.version) then
        return Dictionary.load_from(source)
    end
    return Dictionary.load(version)
end

--- Data only; `:FIX overrides show` formats it.
---@param buf number
---@return { overrides: table<string, FixOverrideResolved>, warnings: table[] }
function M.describe(buf)
    local state = states[buf]
    if not state then
        return { overrides = {}, warnings = {} }
    end
    local overrides = {}
    for _, entry in ipairs(Spec.SPEC) do
        local resolved = state.resolved[entry.path]
        if resolved then
            overrides[entry.path] = { value = resolved.value, layer = resolved.layer, kind = entry.kind }
        end
    end
    return { overrides = overrides, warnings = state.warnings }
end

return M
