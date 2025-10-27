local M = {}

--- @param field Field
--- @return {text: string, highlight: string} | nil
---@diagnostic disable-next-line: unused-local
function M.default(field)
	local tag = field.tag_text
	if tag then
		return { "(" .. tag .. ")", "Comment" }
	end
end

return M
