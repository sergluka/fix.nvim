local M = {}

--- @param dict Dictionary
--- @param tag FieldDef
--- @param value string
function M.common(dict, tag, value)
	local enum = dict:enum(tag.tag, value)
	if enum then
		return { "(" .. enum.name .. ")", "Comment" }
	end
end

return M
