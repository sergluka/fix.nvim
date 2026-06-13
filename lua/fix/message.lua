local Field = require("fix.field")

--- @class Message
--- @field version FixVersion
--- @field lineno number
--- @field _fields { [number]: Field }
local M = {}

function M.new(version, lineno, fields)
    local self = {
        version = version,
        lineno = lineno,
        _fields = fields,
    }
    setmetatable(self, { __index = M })
    return self
end

---@param tag number
---@return Field
function M:field(tag)
    local field = self._fields[tag]
    if field == nil then
        return Field.empty()
    end

    return field
end

--- @return { [number]: Field }
function M:fields()
    return self._fields
end

--- @return Field[]
function M:list_fields()
    local fields = {} ---@type Field[]
    for _, field in pairs(self._fields) do
        table.insert(fields, field)
    end
    table.sort(fields, function(lhs, rhs)
        return lhs.index < rhs.index
    end)
    return fields
end

return M
