---@class Field
---@field index number
---@field tag number
---@field tag_text string
---@field tag_start number
---@field tag_end number
---@field value string
---@field value_text string
---@field value_start number
---@field value_end number
local M = {}

function M.new(o)
	setmetatable(o, { __index = M })
	return o
end

---@return Field
function M.empty()
	return {
		index = nil,
		tag = nil,
		tag_text = nil,
		tag_start = nil,
		tag_end = nil,
		value = nil,
		value_text = nil,
		value_start = nil,
		value_end = nil,
	}
end

-- function M:value_text()
-- return self.value_text ~= nil and self.value_text ~= ""
-- end

return M
