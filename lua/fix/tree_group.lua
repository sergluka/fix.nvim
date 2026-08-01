---@class FixTreeGroup
---@field key string
---@field depth number
---@field index number
---@field name string
---@field field Field Repeating-group count field, such as NoMDEntries (268).
local M = {}

---@param o FixTreeGroup
---@return FixTreeGroup
function M.new(o)
    setmetatable(o, { __index = M })
    return o
end

return M
