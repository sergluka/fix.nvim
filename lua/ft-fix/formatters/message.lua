Dictionary = {}

--- @param dict Dictionary
--- @param fields Fields
function Dictionary.single_line(dict, fields)
	local msg_type = fields[35].value
	local msg_type_name = dict:message(msg_type).name

	local text = string.format(
		"%s: %d: %s=>%s | %s | ",
		fields[52].value,
		fields[34].value,
		fields[49].value,
		fields[56].value,
		msg_type_name
	)

	local details = ""
	if msg_type_name == "ExecutionReport" then
		local exec_type = dict:enum_by_value(150, fields[150].value)
		details = "ExecType=" .. exec_type.name
	end

	return {
		{ { text, "Title" }, { details, "Repeat" } },
	}
end

--- @param dict Dictionary
--- @param fields Fields
function Dictionary.double_line(dict, fields)
	local text = string.format(
		"%s: %d: %s=>%s | %s |",
		fields[52].value,
		fields[34].value,
		fields[49].value,
		fields[56].value,
		dict:message(fields[35].value).name
	)

	local win_width = vim.api.nvim_win_get_width(0)

	return {
		{ { string.rep("-", win_width), "MsgSeparator" } },
		{ { text, "Title" } },
	}
end

return Dictionary
