-- TODO
-- set breakat=\|
-- set wrap
-- syntax match BreakPipe /|/ conceal cchar=⏎

local M = {}

-- Minimal FIX 4.2–5.0 common tags; extend as needed
local TAGS = {
	[8] = { name = "BeginString", desc = "FIX version identifier" },
	[9] = { name = "BodyLength", desc = "Length of message body" },
	[35] = { name = "MsgType", desc = "Message type (e.g., D=NewOrderSingle)" },
	[34] = { name = "MsgSeqNum", desc = "Sequence number" },
	[49] = { name = "SenderCompID", desc = "Sender ID" },
	[56] = { name = "TargetCompID", desc = "Target ID" },
	[52] = { name = "SendingTime", desc = "UTC timestamp" },
	[10] = { name = "CheckSum", desc = "Three-digit checksum" },
	[11] = { name = "ClOrdID", desc = "Client order ID" },
	[37] = { name = "OrderID", desc = "Exchange order ID" },
	[17] = { name = "ExecID", desc = "Execution ID" },
	[150] = { name = "ExecType", desc = "Execution type" },
	[39] = { name = "OrdStatus", desc = "Order status" },
	[55] = { name = "Symbol", desc = "Instrument" },
	[54] = { name = "Side", desc = "1=Buy, 2=Sell" },
	[38] = { name = "OrderQty", desc = "Quantity" },
	[40] = { name = "OrdType", desc = "Order type" },
	[44] = { name = "Price", desc = "Price" },
	[59] = { name = "TimeInForce", desc = "Time in force" },
	[60] = { name = "TransactTime", desc = "Transaction time" },
}

local function parse_line(line)
	-- split on SOH (0x01)
	local fields = {}
	local i = 1
	for pair in line:gmatch("(%d+=[^|]+)") do
		local eq = pair:find("=")
		if eq then
			local tag = pair:sub(1, eq - 1)
			local value = pair:sub(eq + 1)
			local tag_start = i - 1
			local tag_end = tag_start + #tag
			local value_start = tag_end + 1
			local value_end = value_start + #value
			table.insert(fields, {
				tag_start = i - 1,
				tag_end = tag_end,
				tag = tonumber(tag),
				value_start = value_start,
				value_end = value_end,
				value = value,
			})
			i = value_end + 1 + 1
		end
	end
	return fields
end

function M.annotate(buf, ns)
	if not vim.api.nvim_buf_is_loaded(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for lineno, line in ipairs(lines) do
		local fields = parse_line(line)
		for _, field in ipairs(fields) do
			if field.tag and TAGS[field.tag] then
				vim.api.nvim_buf_set_extmark(buf, ns, lineno - 1, field.tag_start, {
					end_row = lineno - 1,
					end_col = field.tag_end,
					hl_group = "fixTag",
				})
				vim.api.nvim_buf_set_extmark(buf, ns, lineno - 1, field.tag_end, {
					end_row = lineno - 1,
					end_col = field.value_start,
					hl_group = "fixAssign",
				})
				vim.api.nvim_buf_set_extmark(buf, ns, lineno - 1, field.value_start, {
					end_row = lineno - 1,
					end_col = field.value_end,
					hl_group = "fixValue",
				})
				vim.api.nvim_buf_set_extmark(buf, ns, lineno - 1, field.value_end, {
					end_row = lineno - 1,
					end_col = field.value_end + 1,
					hl_group = "fixSeparator",
				})
				vim.api.nvim_buf_set_extmark(buf, ns, lineno - 1, field.tag_end, {
					virt_text = { { "(" .. TAGS[field.tag].name .. ")", "Comment" } },
					virt_text_pos = "inline",
				})
			end
		end
	end
end

return M
