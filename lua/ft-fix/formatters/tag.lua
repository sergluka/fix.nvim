Dictionary = {}

--- @param tag FieldDef
--- @param value string
--- @return {text: string, highlight: string} | nil
---@diagnostic disable-next-line: unused-local
function Dictionary.common(tag, value)
	return { "(" .. tag.name .. ")", "Comment" }
end

return Dictionary
