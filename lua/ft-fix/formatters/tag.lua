M = {}

--- @param tag FieldDef
--- @param value string
--- @return {text: string, highlight: string} | nil
function M.common(tag, value)
	return { "(" .. tag.name .. ")", "Comment" }
end

return M
