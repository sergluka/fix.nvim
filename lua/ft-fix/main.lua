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

---@class FixMessage
---@field lineno number
---@field tag_start number
---@field tag_end number
---@field tag number
---@field value_start number
---@field value_end number
---@field value string

---@param buf number
---@param on_message fun(FixMessage)
local function iter_fields(buf, on_message)
	local parser = vim.treesitter.get_parser(buf, "fix")
	if not parser then
		error("No FIX parser for buffer " .. buf)
	end

	local tree = parser:parse()[1]
	local root = tree:root()

	for message_node in root:iter_children() do
		if message_node:type() == "message" then
			local row, col, byte = message_node:start()
			local lineno, _, _ = message_node:start()
			for field_node in message_node:iter_children() do
				if field_node:type() == "field" then
					local tag_start, tag_end, tag, value_start, value_end, value

					for child in field_node:iter_children() do
						local child_type = child:type()
						local text = vim.treesitter.get_node_text(child, buf)

						if child_type == "tag" then
							tag = tonumber(text)
							_, tag_start = child:start()
							_, tag_end = child:end_()
						elseif child_type == "value" then
							value = text
							_, value_start = child:start()
							_, value_end = child:end_()
						end
					end
					local message = {
						lineno = lineno,
						tag_start = tag_start,
						tag_end = tag_end,
						tag = tag,
						value_start = value_start,
						value_end = value_end,
						value = value,
					}
					on_message(message)
				end
			end
		end
	end
end

local function annotate_field(buf, ns, field)
	-- print("field.tag", field.tag)
	if TAGS[field.tag] then
		vim.api.nvim_buf_set_extmark(buf, ns, field.lineno, field.tag_end, {
			virt_text = { { "(" .. TAGS[field.tag].name .. ")", "Comment" } },
			virt_text_pos = "inline",
		})
	end
end

function M.annotate(opts, bufnr, ns)
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	iter_fields(bufnr, function(field)
		annotate_field(bufnr, ns, field)
	end)
end

return M
