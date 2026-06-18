local Annotate = require("fix.annotate")
local Cache = require("fix.cache")
local Document = require("fix.document")
local Persist = require("fix.persist")

local M = {}

local ns_id = vim.api.nvim_create_namespace("fix-protocol")

---@class FixRenderState
---@field rendered { key: string, gen: number, front: boolean }[]  -- index = lnum + 1; sparse
---@field keys table<string, boolean>              -- every cache key seen in this buffer
---@field generation number
---@field line_count number                        -- tracked manually: on_lines runs in a fast context
---@field warm_next number                         -- next 0-based warm-up line
---@field revealed table<number, boolean>          -- cursor rows shown raw in replace_front mode
---@field warm_timer? uv.uv_timer_t
---@field debounce_timer? uv.uv_timer_t
---@field dirty? { first: number, last: number }   -- 0-based, last exclusive
---@field idle boolean

local states = {} ---@type table<number, FixRenderState>

local function opts()
    return require("fix").opts
end

local function close_timer(timer)
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
end

---@param buf number
---@param srow number 0-based inclusive
---@param erow number 0-based exclusive
local function render_lines(buf, srow, erow)
    local state = states[buf]
    if not state then
        return
    end
    local o = opts()
    erow = math.min(erow, vim.api.nvim_buf_line_count(buf))
    for lnum = math.max(srow, 0), erow - 1 do
        local line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ""
        local key = Cache.key(line)
        local slot = state.rendered[lnum + 1]
        local front = state.revealed[lnum] == true
        if not (slot and slot.key == key and slot.gen == state.generation and slot.front == front) then
            local message, _, authoritative = Document.build_line(buf, lnum, line, key)
            local payload = message and Annotate.payload_for(message, key, o) or nil
            Annotate.apply(o, buf, ns_id, lnum, line, payload, front)
            -- A non-authoritative result (tree didn't span the line) must not
            -- mark the slot rendered, or the line would stay bare forever.
            if authoritative then
                state.rendered[lnum + 1] = { key = key, gen = state.generation, front = front }
                state.keys[key] = true
            end
        end
    end
end

---@param buf number
local function sync_revealed_lines(buf)
    local state = states[buf]
    if not state then
        return
    end

    local o = opts()
    local next_revealed = {}
    if o.annotate.message.enabled and o.annotate.message.position == "replace_front" then
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            if vim.api.nvim_win_is_valid(win) then
                local row = vim.api.nvim_win_get_cursor(win)[1] - 1
                next_revealed[row] = true
            end
        end
    end

    local changed = {}
    for lnum in pairs(state.revealed) do
        if not next_revealed[lnum] then
            changed[#changed + 1] = lnum
        end
    end
    for lnum in pairs(next_revealed) do
        if not state.revealed[lnum] then
            changed[#changed + 1] = lnum
        end
    end

    state.revealed = next_revealed
    for _, lnum in ipairs(changed) do
        state.rendered[lnum + 1] = nil
        render_lines(buf, lnum, lnum + 1)
    end
end

---@param buf number
---@return { [1]: number, [2]: number }[] 0-based [first, last-exclusive) ranges
local function viewport_ranges(buf)
    local margin = opts().render.viewport_margin
    local ranges = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        local first = vim.fn.line("w0", win) - 1 - margin
        local last = vim.fn.line("w$", win) + margin
        ranges[#ranges + 1] = { math.max(first, 0), last }
    end
    return ranges
end

function M.refresh_viewport(buf)
    if not states[buf] then
        return
    end
    sync_revealed_lines(buf)
    for _, range in ipairs(viewport_ranges(buf)) do
        render_lines(buf, range[1], range[2])
    end
end

function M.refresh_cursor(buf)
    sync_revealed_lines(buf)
end

local function start_warmup(buf)
    local state = states[buf]
    if not state or state.warm_timer or state.idle then
        return
    end

    local function tick()
        state.warm_timer = nil
        if not vim.api.nvim_buf_is_valid(buf) or states[buf] ~= state then
            return
        end
        local o = opts()
        local line_count = vim.api.nvim_buf_line_count(buf)
        if state.warm_next >= line_count then
            state.idle = true
            Persist.save(buf, state.keys)
            return
        end
        local stop = math.min(state.warm_next + o.render.lines_per_batch, line_count)
        -- Warm-up only fills the semantic cache; extmarks are placed for the
        -- viewport (and re-placed on scroll), never for the whole buffer.
        for lnum = state.warm_next, stop - 1 do
            local _, key = Document.build_line(buf, lnum)
            state.keys[key] = true
        end
        state.warm_next = stop
        state.warm_timer = vim.defer_fn(tick, 10)
    end

    state.warm_timer = vim.defer_fn(tick, 0)
end

-- Pure-Lua bookkeeping; runs in the fast on_lines context — no nvim API here.
---@param state FixRenderState
local function splice(state, first, last_old, last_new)
    local delta = (last_new - first) - (last_old - first)

    -- Order matters: shift surviving slots by delta (in old coordinates) BEFORE
    -- clearing the changed region. Clearing first would nil the insertion-boundary
    -- slot that the shift then reads, losing one valid render per net insertion.
    if delta > 0 then
        for lnum = state.line_count, last_old + 1, -1 do
            state.rendered[lnum + delta] = state.rendered[lnum]
            state.rendered[lnum] = nil
        end
    elseif delta < 0 then
        for lnum = last_old + 1, state.line_count do
            state.rendered[lnum + delta] = state.rendered[lnum]
            state.rendered[lnum] = nil
        end
    end

    -- Clear the changed region in NEW coordinates.
    for lnum = first + 1, last_new do
        state.rendered[lnum] = nil
    end
    -- On a net deletion Neovim moves extmarks from the removed rows to
    -- (first, 0), stacking them on top of the surviving row's own marks.
    -- Invalidate that slot so render_lines will point-clear and re-apply.
    if delta < 0 then
        state.rendered[first + 1] = nil
    end

    if state.dirty and delta ~= 0 and state.dirty.first > last_old then
        state.dirty.first = state.dirty.first + delta
        state.dirty.last = state.dirty.last + delta
    end
    if state.dirty then
        state.dirty.first = math.min(state.dirty.first, first)
        state.dirty.last = math.max(state.dirty.last, last_new)
    else
        state.dirty = { first = first, last = last_new }
    end

    state.line_count = state.line_count + delta
    state.idle = false
    state.warm_next = math.min(state.warm_next, first)
end

local function schedule_debounced_render(buf)
    local state = states[buf]
    if not state then
        return
    end
    close_timer(state.debounce_timer)
    state.debounce_timer = vim.defer_fn(function()
        state.debounce_timer = nil
        if not vim.api.nvim_buf_is_valid(buf) or states[buf] ~= state then
            return
        end
        state.dirty = nil
        -- Edited lines had their rendered slots invalidated by splice: the
        -- visible ones repaint via refresh_viewport here, off-screen ones on the
        -- next scroll. We never render the whole dirty range — on a whole-file
        -- edit (:%s, :sort, full paste) that would be the entire buffer rendered
        -- synchronously, freezing the UI.
        -- Marks of deleted trailing lines migrate to the phantom row at
        -- line_count (past the last line), which per-line clears never reach —
        -- their virt_lines would keep rendering below the buffer forever.
        vim.api.nvim_buf_clear_namespace(buf, ns_id, vim.api.nvim_buf_line_count(buf), -1)
        M.refresh_viewport(buf)
        start_warmup(buf)
    end, opts().render.debounce_ms)
end

---@param buf number
function M.attach(buf)
    if states[buf] then
        M.refresh_viewport(buf)
        return
    end

    -- No parser → no rendering: bail before attaching so on_lines never runs and a
    -- later edit can't reach Document.build_line's loud "No FIX parser" error from
    -- inside a timer callback. The missing-parser case is a graceful no-op end to end.
    local ok, parser = pcall(vim.treesitter.get_parser, buf, "fix")
    if not ok or not parser then
        vim.notify_once(
            "fix.nvim: tree-sitter parser for 'fix' not found — annotations disabled (install tree-sitter-fix)",
            vim.log.levels.WARN
        )
        return
    end

    -- A reload (:e!, git checkout + autoread) DETACHES the watcher rather than
    -- firing on_reload, and extmarks of the old content survive it — including
    -- ones on rows past the new end of buffer, which per-line clears never
    -- reach. Sweep them before rendering the fresh attach.
    vim.api.nvim_buf_clear_namespace(buf, ns_id, vim.api.nvim_buf_line_count(buf), -1)

    local state = {
        rendered = {},
        keys = {},
        generation = 0,
        line_count = vim.api.nvim_buf_line_count(buf),
        warm_next = 0,
        revealed = {},
        idle = false,
    }
    states[buf] = state

    Persist.load_into_cache(buf)

    vim.api.nvim_buf_attach(buf, false, {
        on_lines = function(_, b, _, first, last_old, last_new)
            local st = states[b]
            if not st then
                return true -- detach
            end
            splice(st, first, last_old, last_new)
            vim.schedule(function()
                schedule_debounced_render(b)
            end)
        end,
        on_reload = function(_, b)
            local st = states[b]
            if st then
                st.rendered = {}
                st.keys = {}
                st.dirty = nil
                st.warm_next = 0
                st.revealed = {}
                st.idle = false
                vim.schedule(function()
                    if not vim.api.nvim_buf_is_valid(b) or states[b] ~= st then
                        return
                    end
                    st.line_count = vim.api.nvim_buf_line_count(b)
                    -- Stale annotations from the pre-reload content are worse
                    -- than a blank moment; drop them all now, fresh marks
                    -- stream in once the reparse below completes.
                    vim.api.nvim_buf_clear_namespace(b, ns_id, 0, -1)
                    -- A reload can bypass tree-sitter's change tracking, so
                    -- parse() would keep returning the pre-reload tree —
                    -- rendering from it poisons the content-keyed cache with
                    -- negatives for every row past the old end of file. Force
                    -- a full reparse and only then render.
                    local parser_ok, reload_parser = pcall(vim.treesitter.get_parser, b, "fix")
                    if not parser_ok or not reload_parser then
                        return
                    end
                    pcall(reload_parser.invalidate, reload_parser, true)
                    reload_parser:parse(true, function()
                        vim.schedule(function()
                            if vim.api.nvim_buf_is_valid(b) and states[b] == st then
                                schedule_debounced_render(b)
                            end
                        end)
                    end)
                end)
            end
        end,
        on_detach = function(_, b)
            M.detach(b)
        end,
    })

    -- Async first parse: time-sliced by Neovim, doesn't block the UI even on
    -- huge files. The callback may fire synchronously when already parsed.
    -- Invalidate first: after a detach-style reload (:e!) the cached parser
    -- may still hold the pre-reload tree and would "complete" instantly.
    pcall(parser.invalidate, parser, true)
    parser:parse(true, function()
        vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(buf) or states[buf] ~= state then
                return
            end
            M.refresh_viewport(buf)
            start_warmup(buf)
        end)
    end)
end

--- Re-render everything under a new generation (toggle / option change).
function M.rerender(buf)
    local state = states[buf]
    if not state then
        return
    end
    state.generation = state.generation + 1
    state.idle = false
    state.warm_next = 0
    M.refresh_viewport(buf)
    start_warmup(buf)
end

function M.rerender_all()
    for buf in pairs(states) do
        if vim.api.nvim_buf_is_valid(buf) then
            M.rerender(buf)
        end
    end
end

--- Full reset for :FIX cache clear — wipe extmarks and re-render from scratch.
function M.purge(buf)
    local state = states[buf]
    if not state then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
    state.rendered = {}
    state.keys = {}
    state.generation = state.generation + 1
    state.idle = false
    state.warm_next = 0
    M.refresh_viewport(buf)
    start_warmup(buf)
end

--- True when warm-up finished and no edits are pending. Used by tests.
function M.is_idle(buf)
    local state = states[buf]
    return state ~= nil and state.idle and state.dirty == nil and state.debounce_timer == nil
end

--- Persist this buffer's semantic entries (async unless sync).
function M.flush(buf, sync)
    local state = states[buf]
    if state then
        Persist.save(buf, state.keys, sync)
    end
end

function M.flush_all_sync()
    for buf in pairs(states) do
        M.flush(buf, true)
    end
end

function M.detach(buf)
    local state = states[buf]
    if not state then
        return
    end
    states[buf] = nil
    close_timer(state.warm_timer)
    close_timer(state.debounce_timer)
end

return M
