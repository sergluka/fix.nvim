M = {}

--- @param dict Dictionary
--- @param fields Fields
function M.single_line(dict, fields)
	local text = string.format(
		"%s: %d: %s=>%s | %s |",
		fields[52].data.value,
		fields[34].data.value,
		fields[49].data.value,
		fields[56].data.value,
		dict.messages[fields[35].data.value].name
	)

	return {
		{ { text, "Title" } },
	}
end

--- @param dict Dictionary
--- @param fields Fields
function M.double_line(dict, fields)
	local text = string.format(
		"%s: %d: %s=>%s | %s |",
		fields[52].data.value,
		fields[34].data.value,
		fields[49].data.value,
		fields[56].data.value,
		dict.messages[fields[35].data.value].name
	)

	local win_width = vim.api.nvim_win_get_width(0)

	return {
		{ { string.rep("-", win_width), "MsgSeparator" } },
		{ { text, "Title" } },
	}
end
return M
