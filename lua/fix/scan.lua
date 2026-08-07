--- Viewport-first, non-blocking buffer walking. The annotation renderer and
--- the neo-tree source both consume a buffer this way; this module owns the
--- mechanism (viewport ranges, a covered-line set, a batched background
--- walker) so each of them only supplies what to do with a batch of lines.

local M = {}

-- Delay between background batches; keeps the walk off the UI thread's back.
local BATCH_DELAY_MS = 10

local function opts()
    return require("fix").opts
end

--- Stop and dispose a libuv timer; nil-safe. Shared by every Scan consumer.
---@param timer uv.uv_timer_t|nil
function M.close_timer(timer)
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
end

---@param buf number
---@return { [1]: number, [2]: number }[] 0-based [first, last-exclusive) ranges
function M.viewport_ranges(buf)
    local margin = opts().render.viewport_margin
    local ranges = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        local first = vim.fn.line("w0", win) - 1 - margin
        local last = vim.fn.line("w$", win) + margin
        ranges[#ranges + 1] = { math.max(first, 0), last }
    end
    return ranges
end

--- Merge [first, last) into a sorted, disjoint range set.
---@param ranges { [1]: number, [2]: number }[]
---@param first number 0-based inclusive
---@param last number 0-based exclusive
---@return { [1]: number, [2]: number }[]
function M.cover(ranges, first, last)
    if first >= last then
        return ranges
    end

    local merged = {}
    local inserted = false
    for _, range in ipairs(ranges) do
        if range[2] < first then
            merged[#merged + 1] = range
        elseif last < range[1] then
            if not inserted then
                merged[#merged + 1] = { first, last }
                inserted = true
            end
            merged[#merged + 1] = range
        else
            first = math.min(first, range[1])
            last = math.max(last, range[2])
        end
    end
    if not inserted then
        merged[#merged + 1] = { first, last }
    end
    return merged
end

--- The parts of [first, last) that `ranges` does not cover yet.
---@param ranges { [1]: number, [2]: number }[]
---@param first number 0-based inclusive
---@param last number 0-based exclusive
---@return { [1]: number, [2]: number }[]
function M.pending(ranges, first, last)
    local result = {}
    local cursor = first
    for _, range in ipairs(ranges) do
        if range[2] > cursor then
            if range[1] >= last then
                break
            end
            if range[1] > cursor then
                result[#result + 1] = { cursor, math.min(range[1], last) }
            end
            cursor = math.max(cursor, range[2])
            if cursor >= last then
                break
            end
        end
    end
    if cursor < last then
        result[#result + 1] = { cursor, last }
    end
    return result
end

--- Skip past the covered lines a cursor is sitting on.
---@param ranges { [1]: number, [2]: number }[]
---@param cursor number
---@return number
function M.advance(ranges, cursor)
    for _, range in ipairs(ranges) do
        if cursor < range[1] then
            break
        elseif cursor < range[2] then
            cursor = range[2]
        end
    end
    return cursor
end

---@class FixScanWalk
---@field next number  Next 0-based line to visit; `rewind` is the fast-context-safe way to move it.
---@field done boolean True once the walk reached the end of the buffer.
local Walk = {}
Walk.__index = Walk

---@class FixScanWalkOpts
---@field buf number
---@field alive fun(): boolean The walk stops for good once this returns false.
---@field line_count fun(): number
---@field on_batch fun(first: number, last: number): boolean? Return false to retry the batch.
---@field on_complete? fun()
---@field advance? fun(cursor: number): number

--- Background walker over a buffer, one `render.lines_per_batch` batch per tick.
--- Starts idle: call `resume`.
---@param o FixScanWalkOpts
---@return FixScanWalk
function M.walk(o)
    return setmetatable({ next = 0, done = false, _opts = o }, Walk)
end

function Walk:_tick()
    self._timer = nil
    local o = self._opts
    if not vim.api.nvim_buf_is_valid(o.buf) or not o.alive() then
        return
    end

    if o.advance then
        self.next = o.advance(self.next)
    end
    local line_count = o.line_count()
    if self.next >= line_count then
        self.done = true
        if o.on_complete then
            o.on_complete()
        end
        return
    end

    local stop = math.min(self.next + opts().render.lines_per_batch, line_count)
    if o.on_batch(self.next, stop) ~= false then
        self.next = stop
    end
    self._timer = vim.defer_fn(function()
        self:_tick()
    end, BATCH_DELAY_MS)
end

--- Start ticking; a no-op while a tick is pending or the walk has finished.
function Walk:resume()
    if self._timer or self.done then
        return
    end
    self._timer = vim.defer_fn(function()
        self:_tick()
    end, 0)
end

--- Re-visit from `lnum` on. Pure Lua, so it is safe from `on_lines`; the walk
--- only picks the work up again on the next `resume`.
---@param lnum number
function Walk:rewind(lnum)
    self.next = math.min(self.next, lnum)
    self.done = false
end

function Walk:cancel()
    M.close_timer(self._timer)
    self._timer = nil
end

return M
