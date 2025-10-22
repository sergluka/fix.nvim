M = {}

--- @param message Message
function M.single_line(message)
	local fields = message.fields
	local msg_type_name = fields[35].value_text

	local text = string.format(
		"%s: %d: %s=>%s | %s",
		fields[52].value,
		fields[34].value,
		fields[49].value,
		fields[56].value,
		fields[35].value_text
	)

	if fields[43] and fields[43].value == "Y" then
		text = text .. " [POSS DUP]"
	end

	local details = ""
	if msg_type_name == "ExecutionReport" then
		local exec_type = fields[150].value_text
		if exec_type == "Trade" or exec_type == "TradeCorrect" then
			local client_order_id = fields[11] and fields[11].value
			local exec_id = fields[17] and fields[17].value or "MISSING"
			local price = fields[44] and fields[44].value or "MKT"
			local amount = fields[38] and fields[38].value or "???"
			details = string.format("%s %s@%s ClOrdId=%s ExecId=%s", exec_type, amount, price, client_order_id, exec_id)
		else
			details = exec_type
		end
	elseif msg_type_name == "NewOrderSingle" then
		local ord_type = fields[40].value_text
		local time_in_force = fields[59].value_text
		local side = fields[54].value_text
		local amount = fields[38] and fields[38].value or "???"
		local price = fields[44] and fields[44].value or "MKT"
		local symbol = fields[55] and fields[55].value or "???"
		details = string.format("%s %s %s %s@%s %s", symbol, ord_type, side, amount, price, time_in_force)
	elseif msg_type_name == "Logout" then
		details = fields[58] and fields[58].value or ""
	elseif msg_type_name == "ResendRequest" then
		local begin_seq_no = fields[7] and fields[7].value or "MISSING"
		local end_seq_no = fields[16] and fields[16].value or "MISSING"
		details = string.format("%s - %s", begin_seq_no, end_seq_no)
	elseif msg_type_name == "SequenceReset" then
		local is_fill_gap = fields[123] and fields[123].value == "Y"
		local new_seq_num = fields[36] and fields[36].value or "MISSING"
		if is_fill_gap then
			details = string.format("Gap Fill to %s", new_seq_num)
		else
			details = string.format("Reset to %s", new_seq_num)
		end
	end

	return {
		{ { text, "Title" }, { " | " .. details, "Repeat" } },
	}
end

--- @param message Message
function M.double_line(message)
	local fields = message.fields
	local text = string.format(
		"%s: %d: %s=>%s | %s |",
		fields[52].value,
		fields[34].value,
		fields[49].value,
		fields[56].value,
		fields[35].value_text
	)

	local win_width = vim.api.nvim_win_get_width(0)

	return {
		{ { string.rep("-", win_width), "MsgSeparator" } },
		{ { text, "Title" } },
	}
end

return M
