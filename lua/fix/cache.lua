---@class FixSemantic
---@field version FixVersion
---@field fields Field[]   -- ordered by index; duplicates are adjacent entries

---@class FixRenderMark
---@field col number
---@field virt_text table              -- {text, highlight} as returned by a formatter
---@field kind "tag"|"value"

---@class FixRenderPayload
---@field title? table                 -- virt_lines payload from the message formatter
---@field marks FixRenderMark[]

local M = {}

-- Hard cap on unique entries; on overflow the whole cache is dropped — a
-- recompute of the viewport is cheaper than LRU bookkeeping here. The cap
-- covers the semantic layer only; the render layer is assumed to use a subset
-- of the same keys.
local MAX_ENTRIES = 50000

M._semantic = {} ---@type table<string, FixSemantic|false>
M._render = {} ---@type table<string, FixRenderPayload>
M._count = 0

---@param line_text string
---@return string
function M.key(line_text)
    return vim.fn.sha256(line_text):sub(1, 32)
end

--- false means "known non-message line", nil means "not computed yet".
---@param key string
---@return FixSemantic|false|nil
function M.get_semantic(key)
    return M._semantic[key]
end

---@param key string
---@param semantic FixSemantic|false
function M.put_semantic(key, semantic)
    if M._semantic[key] == nil then
        if M._count >= MAX_ENTRIES then
            M.clear()
        end
        M._count = M._count + 1
    end
    M._semantic[key] = semantic
end

---@param key string
---@return FixRenderPayload|nil
function M.get_render(key)
    return M._render[key]
end

---@param key string
---@param payload FixRenderPayload
function M.put_render(key, payload)
    M._render[key] = payload
end

--- Drop formatter output only (kept separate so option changes don't lose
--- the expensive semantic layer).
function M.drop_render()
    M._render = {}
end

function M.clear()
    M._semantic = {}
    M._render = {}
    M._count = 0
end

--- Subset of the semantic layer for persistence; negative entries are skipped.
---@param keys table<string, boolean>
---@return table<string, FixSemantic>
function M.collect(keys)
    local out = {}
    for key in pairs(keys) do
        local semantic = M._semantic[key]
        if semantic then
            out[key] = semantic
        end
    end
    return out
end

--- Bulk-load persisted entries.
---@param entries table<string, FixSemantic>
function M.merge(entries)
    for key, semantic in pairs(entries) do
        if type(semantic) == "table" then
            M.put_semantic(key, semantic)
        end
    end
end

return M
