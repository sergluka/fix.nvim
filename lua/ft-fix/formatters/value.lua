local M = {}

--- @param field Field
function M.common(field)
	local value = field.value_text
	if value then
		return { "(" .. value .. ")", "Comment" }
	end
end

return M
