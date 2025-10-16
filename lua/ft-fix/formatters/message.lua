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
		local exec_type = dict:enum(150, fields[150].value)
		details = exec_type.name
	elseif msg_type_name == "NewOrderSingle" then
		local ord_type = dict:enum(40, fields[40].value)
		local time_in_force = dict:enum(59, fields[59].value)
		local side = dict:enum(54, fields[54].value)
		local amount = fields[38] and fields[38].value or "???"
		local price = fields[44] and fields[44].value or "MKT"
		local symbol = fields[55] and fields[55].value or "???"
		details =
			string.format("%s %s %s %s@%s %s", symbol, ord_type.name, side.name, amount, price, time_in_force.name)
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
