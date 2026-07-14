---@class Field
---@field index? number          -- 1-based order within the message
---@field tag? number
---@field value? string
---@field tag_text? string       -- decoded field name
---@field value_text? string     -- decoded enum name
---@field group_path_text? string -- decoded group path plus field name
---@field group_instances? table[] -- containing group instances, outermost first
---@field tag_start? number      -- byte cols within the line
---@field tag_end? number
---@field value_start? number
---@field value_end? number
local M = {}

---@param o Field
---@return Field
function M.new(o)
    setmetatable(o, { __index = M })
    return o
end

---@param field Field
---@return Field
function M.copy(field)
    local copy = {}
    for key, value in pairs(field) do
        copy[key] = value
    end
    return M.new(copy)
end

---@return Field
function M.empty()
    return M.new({})
end

return M
