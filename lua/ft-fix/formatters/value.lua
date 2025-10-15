local M = {}

--- @param dict Dictionary
--- @param tag FieldDef
--- @param value string
function M.common(dict, tag, value)
	if tag.name == "MsgType" then
		local msg = dict.messages[value]
		if msg then
			return { "(" .. msg.name .. ")", "Comment" }
		end
	end
end

return M
