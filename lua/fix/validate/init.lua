--- Asynchronous validation of FIX buffers.
---
--- The engine owns the per-buffer state: a `Scan` walk that visits the buffer
--- in the background, the diagnostics it produced per line, and the fixes each
--- of them carries. `fix.validate.lsp` is only the delivery surface — it
--- publishes what is stored here and answers code actions from it.

local Document = require("fix.document")
local Lsp = require("fix.validate.lsp")
local Overrides = require("fix.overrides")
local Rules = require("fix.validate.rules")
local Scan = require("fix.scan")

local M = {}

-- Diagnostics are replaced whole-buffer, so mid-walk publishing is throttled
-- rather than done per batch.
local PUBLISH_THROTTLE_MS = 150

---@class FixDiagnostic
---@field col number
---@field end_col number
---@field message string
---@field severity number
---@field code string
---@field source string
---@field fixes? FixFix[]

---@class FixValidateState
---@field entries table<number, FixDiagnostic[]>  index = lnum + 1; sparse
---@field line_count number                       tracked manually: on_lines is a fast context
---@field walk FixScanWalk
---@field debounce_timer? uv.uv_timer_t
---@field publish_timer? uv.uv_timer_t
---@field dirty boolean
---@field touched_first? number  0-based span of lines whose diagnostics changed
---@field touched_last? number   since the last publish
---@field validating boolean     mirrors validating(buf) as of the last sync; edge-detects a mid-session flip

local states = {} ---@type table<number, FixValidateState>

---@param buf number
local function opts(buf)
    return Overrides.effective(buf).lsp
end

--- Whether the diagnostics side runs; hover only needs the attach itself.
---@param buf number
---@return boolean
local function validating(buf)
    return opts(buf).validate.enabled
end

---@param raw FixRuleDiagnostic
---@param rule FixRule
---@param line string
---@return FixDiagnostic|nil
local function normalize(raw, rule, line)
    if type(raw) ~= "table" or type(raw.message) ~= "string" or type(raw.col) ~= "number" then
        vim.notify_once(
            string.format("fix.nvim: validation rule '%s' returned a malformed diagnostic", rule.id),
            vim.log.levels.ERROR
        )
        return nil
    end
    local col = math.max(math.min(raw.col, #line), 0)
    local end_col = math.max(math.min(tonumber(raw.end_col) or col, #line), col)
    return {
        col = col,
        end_col = end_col,
        message = raw.message,
        severity = raw.severity or rule.severity,
        code = raw.code or rule.id,
        source = "fix",
        fixes = type(raw.fixes) == "table" and raw.fixes or nil,
    }
end

---@param buf number
---@param lnum number 0-based
---@param line string
---@param message Message
---@return FixDiagnostic[]|nil diagnostics, FixRuleCtx ctx
local function run_rules(buf, lnum, line, message)
    local ctx = {
        buf = buf,
        lnum = lnum,
        line = line,
        message = message,
        scratch = {},
        opts = opts(buf).validate,
    }

    local diagnostics
    local tier
    for _, rule in ipairs(Rules.active("message")) do
        -- Rules arrive lowest tier first. Once a tier has objected, the ones
        -- below it have nothing to add: a line that is not a FIX message at all
        -- has no BodyLength worth complaining about.
        if diagnostics and rule.tier ~= tier then
            break
        end
        tier = rule.tier

        local ok, produced = pcall(rule.check, ctx)
        if not ok then
            vim.notify_once(
                string.format("fix.nvim: validation rule '%s' failed: %s", rule.id, produced),
                vim.log.levels.ERROR
            )
        elseif type(produced) == "table" then
            for _, raw in ipairs(produced) do
                local diagnostic = normalize(raw, rule, line)
                if diagnostic then
                    diagnostics = diagnostics or {}
                    diagnostics[#diagnostics + 1] = diagnostic
                end
            end
        end
    end
    return diagnostics, ctx
end

---@param buf number
---@param lnum number 0-based
---@param line? string  passed by the walk, which fetches whole batches at once
---@return FixDiagnostic[]|nil diagnostics, FixRuleCtx|nil ctx, boolean authoritative
local function validate_line(buf, lnum, line)
    line = line or vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1]
    if line == nil then
        return nil, nil, true
    end
    local message, _, authoritative = Document.build_line(buf, lnum, line)
    if not authoritative then
        return nil, nil, false
    end
    if not message then
        return nil, nil, true
    end
    local diagnostics, ctx = run_rules(buf, lnum, line, message)
    return diagnostics, ctx, true
end

--- Repaint the viewport when message titles carry diagnostics: the renderer
--- walks the buffer independently and will have painted these lines before the
--- validator ever reached them. With a span, the repaint is skipped while the
--- change is entirely off-screen — a background walk would otherwise re-hash
--- the viewport on every publish tick.
---@param buf number
---@param first? number 0-based inclusive; nil repaints unconditionally
---@param last? number 0-based inclusive
local function refresh_titles(buf, first, last)
    local render = package.loaded["fix.render"]
    if not (render and render.diagnostics_in_title(buf)) then
        return
    end
    if first then
        for _, range in ipairs(Scan.viewport_ranges(buf)) do
            if first < range[2] and last >= range[1] then
                render.refresh_viewport(buf)
                return
            end
        end
        return
    end
    render.refresh_viewport(buf)
end

--- Record that a line's diagnostics changed, for the next publish's repaint.
---@param state FixValidateState
---@param lnum number 0-based
---@param diagnostics FixDiagnostic[]|nil
local function store_line(state, lnum, diagnostics)
    local slot = lnum + 1
    if state.entries[slot] ~= nil or diagnostics ~= nil then
        if not state.touched_first or lnum < state.touched_first then
            state.touched_first = lnum
        end
        if not state.touched_last or lnum > state.touched_last then
            state.touched_last = lnum
        end
    end
    state.entries[slot] = diagnostics
end

--- The virtual text `vim.diagnostic` renders itself, narrowed to the lines the
--- title did not take over. Only our own namespace is touched, so other servers
--- and the global config are unaffected.
---@param namespace number
---@param bufnr number
---@return vim.diagnostic.Opts.VirtualText|false
local function current_line_virtual_text(namespace, bufnr)
    local configured = vim.diagnostic.config().virtual_text
    if type(configured) == "function" then
        configured = configured(namespace, bufnr)
    end
    if not configured then
        return false
    end
    -- Narrow rather than replace: whatever prefix, format or severity filter is
    -- configured stays, and a later change to it still comes through.
    local narrowed = type(configured) == "table" and vim.deepcopy(configured) or {}
    narrowed.current_line = true
    return narrowed
end

--- One client, one namespace, many buffers with different effective title
--- positions — so the namespace's (global) `virtual_text` is a resolver
--- deciding per buffer at render time, not a value frozen by the last caller.
---@param namespace number
---@param bufnr number
---@return vim.diagnostic.Opts.VirtualText|false
local function resolve_virtual_text(namespace, bufnr)
    local render = package.loaded["fix.render"]
    local position = render and render.diagnostics_in_title(bufnr)
    if position == "replace" then
        return false
    elseif position == "replace_front" then
        return current_line_virtual_text(namespace, bufnr)
    end
    local configured = vim.diagnostic.config().virtual_text
    if type(configured) == "function" then
        return configured(namespace, bufnr)
    end
    return configured
end

--- Where the title carries the diagnostics, the stock virtual text would draw
--- them a second time — inline, over the very title they were drawn into. Turn
--- it off, but only for our own namespace. `replace_front` reveals the cursor
--- line, and there the raw message is visible and the stock rendering works, so
--- keep it for that one line.
local function configure_virtual_text()
    local ns = Lsp.namespace()
    if not ns then
        return
    end

    -- Assigning through the namespace table is the only way to drop a key
    -- again if this ever needs to change; vim.diagnostic.config() can only
    -- add or overwrite. The empty config call re-renders what is on screen.
    vim.diagnostic.get_namespace(ns).opts.virtual_text = resolve_virtual_text
    vim.diagnostic.config({}, ns)
end

--- Re-consult `resolve_virtual_text` now, for every buffer showing our
--- diagnostics. A presentation-only override like `annotate.title.position`
--- changes what it decides without a publish, and nothing else re-renders.
M.refresh_virtual_text = configure_virtual_text

---@param buf number
local function publish_now(buf)
    local state = states[buf]
    if not state then
        return
    end
    Scan.close_timer(state.publish_timer)
    state.publish_timer = nil
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    -- Publish order is irrelevant: `vim.diagnostic` sorts on display.
    local diagnostics = {}
    for index, entries in pairs(state.entries) do
        for _, entry in ipairs(entries) do
            diagnostics[#diagnostics + 1] = Lsp.to_lsp_diagnostic(index - 1, entry)
        end
    end
    Lsp.publish(buf, diagnostics)

    local first, last = state.touched_first, state.touched_last
    state.touched_first, state.touched_last = nil, nil
    if first then
        refresh_titles(buf, first, last)
    end
end

---@param buf number
local function publish_soon(buf)
    local state = states[buf]
    if not state or state.publish_timer then
        return
    end
    state.publish_timer = vim.defer_fn(function()
        local current = states[buf]
        if current then
            current.publish_timer = nil
            publish_now(buf)
        end
    end, PUBLISH_THROTTLE_MS)
end

---@param buf number
---@param state FixValidateState
---@return FixScanWalk
local function validate_walk(buf, state)
    return Scan.walk({
        buf = buf,
        alive = function()
            return states[buf] == state
        end,
        line_count = function()
            return vim.api.nvim_buf_line_count(buf)
        end,
        on_batch = function(first, last)
            local lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
            for lnum = first, last - 1 do
                local diagnostics, _, authoritative = validate_line(buf, lnum, lines[lnum - first + 1])
                if not authoritative then
                    return false
                end
                store_line(state, lnum, diagnostics)
            end
            publish_soon(buf)
        end,
        on_complete = function()
            publish_now(buf)
        end,
    })
end

-- Pure-Lua bookkeeping; runs in the fast on_lines context — no nvim API here.
---@param state FixValidateState
local function splice(state, first, last_old, last_new)
    local delta = (last_new - first) - (last_old - first)
    local entries = state.entries

    -- `entries` is sparse (only lines with diagnostics), so shift the slots
    -- that exist instead of sweeping every line number per keystroke.
    if delta ~= 0 then
        local moved = {}
        for index in pairs(entries) do
            if index > last_old then
                moved[#moved + 1] = index
            end
        end
        local values = {}
        for _, index in ipairs(moved) do
            values[index] = entries[index]
            entries[index] = nil
        end
        for _, index in ipairs(moved) do
            entries[index + delta] = values[index]
        end
    end

    for lnum = first + 1, last_new do
        entries[lnum] = nil
    end

    state.line_count = state.line_count + delta
    state.dirty = true
    state.walk:rewind(first)
end

---@param buf number
local function schedule_debounced(buf)
    local state = states[buf]
    if not state then
        return
    end
    Scan.close_timer(state.debounce_timer)
    state.debounce_timer = vim.defer_fn(function()
        if states[buf] ~= state then
            return
        end
        state.debounce_timer = nil
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        state.dirty = false
        -- Publish what splice already invalidated; the walk fills the rest in.
        publish_soon(buf)
        if validating(buf) then
            state.walk:resume()
        end
    end, opts(buf).validate.debounce_ms)
end

---@param buf number
function M.attach(buf)
    if states[buf] or not opts(buf).enabled then
        return
    end

    -- Without a parser there is nothing to validate; render.attach already
    -- warns about the missing parser, so stay quiet here.
    local ok, parser = pcall(vim.treesitter.get_parser, buf, "fix")
    if not ok or not parser then
        return
    end

    local state = {
        entries = {},
        line_count = vim.api.nvim_buf_line_count(buf),
        dirty = false,
        validating = validating(buf),
    }
    state.walk = validate_walk(buf, state)
    states[buf] = state

    Lsp.ensure_client(buf)
    configure_virtual_text()

    vim.api.nvim_buf_attach(buf, false, {
        on_lines = function(_, b, _, first, last_old, last_new)
            local current = states[b]
            if not current then
                return true -- detach
            end
            splice(current, first, last_old, last_new)
            vim.schedule(function()
                schedule_debounced(b)
            end)
        end,
        on_reload = function(_, b)
            local current = states[b]
            if not current then
                return
            end
            current.entries = {}
            current.dirty = true
            current.walk:rewind(0)
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(b) or states[b] ~= current then
                    return
                end
                current.line_count = vim.api.nvim_buf_line_count(b)
                Lsp.publish(b, {})
                schedule_debounced(b)
            end)
        end,
        on_detach = function(_, b)
            M.detach(b)
        end,
    })

    -- Wait for the first parse: `build_line` would otherwise parse the whole
    -- buffer synchronously on the walk's first batch.
    parser:parse(true, function()
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(buf) and states[buf] == state and validating(buf) then
                state.walk:resume()
            end
        end)
    end)
end

---@param buf number
function M.detach(buf)
    local state = states[buf]
    if not state then
        return
    end
    states[buf] = nil
    state.walk:cancel()
    Scan.close_timer(state.debounce_timer)
    Scan.close_timer(state.publish_timer)
    Lsp.clear(buf)
    -- Titles that embedded these diagnostics have to drop them again.
    refresh_titles(buf)
end

--- Re-run every rule over a buffer; used when the rule set changes.
---@param buf number
function M.revalidate(buf)
    local state = states[buf]
    if not state then
        return
    end
    state.entries = {}
    state.walk:rewind(0)
    if validating(buf) then
        state.walk:resume()
    end
end

local function detach_all()
    for _, buf in ipairs(vim.tbl_keys(states)) do
        M.detach(buf)
    end
end

--- Attach or detach one buffer by its own effective `lsp.enabled`, never the
--- global flag alone — a modeline can enable the LSP where setup() disables
--- it. Also reconciles a mid-session `lsp.validate.enabled` flip, which never
--- goes through attach/detach, so nothing else clears stale diagnostics or
--- restarts the walk.
---@param buf number
function M.sync(buf)
    if not opts(buf).enabled then
        M.detach(buf)
        return
    end

    local state = states[buf]
    if not state then
        M.attach(buf)
        return
    end

    local should_validate = validating(buf)
    if should_validate == state.validating then
        return
    end
    state.validating = should_validate

    if should_validate then
        M.revalidate(buf)
    else
        state.walk:cancel() -- a walk mid-tick would otherwise repopulate entries right after
        state.entries = {}
        state.touched_first, state.touched_last = nil, nil
        Lsp.publish(buf, {})
        refresh_titles(buf)
    end
end

--- `M.sync` over every FIX buffer; the global flag itself is owned by
--- fix/init.lua.
function M.sync_all()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "fix" then
            M.sync(buf)
        end
    end
end

--- Drop every buffer's state and start over — for option changes at re-setup.
function M.reattach_all()
    detach_all()
    M.sync_all()
end

--- Add or replace a rule at runtime, then revalidate every attached buffer.
---@param rule FixRule
---@return FixRule
function M.register(rule)
    local registered = Rules.register(rule)
    for buf in pairs(states) do
        M.revalidate(buf)
    end
    return registered
end

--- True once the background walk finished and no edits are pending. Used by tests.
---@param buf number
---@return boolean
function M.is_idle(buf)
    local state = states[buf]
    if not state then
        return not opts(buf).enabled
    end
    -- With validation off the walk never runs; the attach alone is idle.
    return (state.walk.done or not validating(buf))
        and not state.dirty
        and state.debounce_timer == nil
        and state.publish_timer == nil
end

--- Revalidate one line and refresh its stored diagnostics.
---@param buf number
---@param lnum number 0-based
---@return FixDiagnostic[]|nil diagnostics, FixRuleCtx|nil ctx
function M.refresh_line(buf, lnum)
    if not validating(buf) then
        return nil, nil
    end
    local diagnostics, ctx, authoritative = validate_line(buf, lnum)
    local state = states[buf]
    if state and authoritative then
        store_line(state, lnum, diagnostics)
    end
    return diagnostics, ctx
end

--- A line's stored diagnostics. The table is replaced on every revalidation, so
--- callers may use its identity to detect a change.
---@param buf number
---@param lnum number 0-based
---@return FixDiagnostic[]|nil
function M.diagnostics_for(buf, lnum)
    local state = states[buf]
    return state and state.entries[lnum + 1] or nil
end

--- Lines that currently hold diagnostics, ascending, optionally within a range.
---@param buf number
---@param first? number 0-based inclusive
---@param last? number 0-based inclusive
---@return number[]
function M.lines_with_diagnostics(buf, first, last)
    local state = states[buf]
    if not state then
        return {}
    end
    local lnums = {}
    for index in pairs(state.entries) do
        local lnum = index - 1
        if (not first or lnum >= first) and (not last or lnum <= last) then
            lnums[#lnums + 1] = lnum
        end
    end
    table.sort(lnums)
    return lnums
end

--- Resolve a fix's edits, tolerating the lazy form and user-supplied garbage.
---@param fix FixFix
---@param ctx? FixRuleCtx
---@return FixEdit[]|nil
function M.fix_edits(fix, ctx)
    if type(fix) ~= "table" then
        return nil
    end
    local edits = fix.edits
    if type(edits) == "function" then
        local ok, produced = pcall(edits, ctx)
        if not ok then
            vim.notify_once("fix.nvim: could not build a fix: " .. tostring(produced), vim.log.levels.ERROR)
            return nil
        end
        edits = produced
    end
    if type(edits) ~= "table" or #edits == 0 then
        return nil
    end
    for _, edit in ipairs(edits) do
        if
            type(edit) ~= "table"
            or type(edit.new_text) ~= "string"
            or type(edit.col) ~= "number"
            or type(edit.end_col) ~= "number"
        then
            return nil
        end
    end
    return edits
end

--- Map a document URI back to an attached buffer. Unnamed buffers all share the
--- same URI, so the current one wins when it matches.
---@param uri string|nil
---@return number|nil
function M.buf_from_uri(uri)
    if type(uri) ~= "string" then
        return nil
    end
    local current = vim.api.nvim_get_current_buf()
    if states[current] and vim.uri_from_bufnr(current) == uri then
        return current
    end
    for buf in pairs(states) do
        if vim.api.nvim_buf_is_valid(buf) and vim.uri_from_bufnr(buf) == uri then
            return buf
        end
    end
    return nil
end

return M
