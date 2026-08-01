local Field = require("fix.field")
local Route = require("fix.route")

--- @class Message
--- @field version string
--- @field lineno number
--- @field _fields { [number]: Field }
--- @field private _decode_field? fun(field: Field)
--- @field private _decoded_fields table<Field, boolean>
local M = {}

---@param version string
---@param lineno number
---@param fields table<number|string, Field>
---@param decode_field? fun(field: Field)
function M.new(version, lineno, fields, decode_field)
    local self = {
        version = version,
        lineno = lineno,
        _fields = fields,
        _decode_field = decode_field,
        _decoded_fields = {},
    }
    setmetatable(self, { __index = M })
    return self
end

---@param self Message
---@param field Field
local function decode_once(self, field)
    if self._decode_field and not self._decoded_fields[field] then
        self._decode_field(field)
        self._decoded_fields[field] = true
    end
end

---@param tag number
---@return Field
function M:field(tag)
    local field = self._fields[tag]
    if field == nil then
        return Field.empty()
    end

    decode_once(self, field)
    return field
end

--- @return { [number]: Field }
function M:fields()
    if self._decode_field then
        for _, field in pairs(self._fields) do
            decode_once(self, field)
        end
    end
    return self._fields
end

--- @return FixRoute
function M:route()
    return Route.get(self)
end

--- @return string
function M:route_key()
    return Route.key(self:route(), "direction")
end

--- @return string
function M:route_highlight()
    return Route.highlight(self)
end

--- @return Field[]
function M:list_fields()
    local fields = {} ---@type Field[]
    for _, field in pairs(self:fields()) do
        table.insert(fields, field)
    end
    table.sort(fields, function(lhs, rhs)
        return lhs.index < rhs.index
    end)
    return fields
end

return M
