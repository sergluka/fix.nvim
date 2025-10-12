-- TODO
-- set breakat=\|
-- set wrap
-- syntax match BreakPipe /|/ conceal cchar=⏎

local M = {}

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
local function iter_messages(buf, on_message)
	local parser = vim.treesitter.get_parser(buf, "fix")
	if not parser then
		error("No FIX parser for buffer " .. buf)
	end

	local tree = parser:parse()[1]
	local root = tree:root()

	for message_node in root:iter_children() do
		if message_node:type() == "message" then
			local lineno, _, _ = message_node:start()
			local fields = {}
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
					local field = {
						lineno = lineno,
						tag_start = tag_start,
						tag_end = tag_end,
						tag = tag,
						value_start = value_start,
						value_end = value_end,
						value = value,
					}
					fields[tag] = field
				end
			end
			on_message(fields)
		end
	end
end

local function annotate_field(buf, ns, dict, field)
	local tag = dict.fields[field.tag]
	if tag then
		vim.api.nvim_buf_set_extmark(buf, ns, field.lineno, field.tag_end, {
			-- TODO: add to config
			virt_text = { { "(" .. tag.name .. ")", "Comment" } },
			virt_text_pos = "inline",
		})

		if tag.tag == 35 then -- MsgType
			local msg = dict.messages[field.value]
			if msg then
				-- TODO: add to config
				vim.api.nvim_buf_set_extmark(buf, ns, field.lineno, field.value_end, {
					virt_text = { { "(" .. msg.name .. ")", "Type" } },
					virt_text_pos = "inline",
				})
			end
		end
	end
end

-- TODO: docs: Explain issue about 0th line [https://github.com/neovim/neovim/issues/16166]
local function annotate_message(buf, ns, dict, fields)
	local text = string.format(
		"%d: %s=>%s | %s |",
		fields[34].value,
		fields[49].value,
		fields[56].value,
		dict.messages[fields[35].value].name
	)
	vim.api.nvim_buf_set_extmark(buf, ns, fields[1].lineno, 0, {
		virt_lines = {
			{ { text, "Title" } },
		},
		virt_lines_above = true,
	})
end

function M.annotate(opts, bufnr, ns)
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local dict = nil
	iter_messages(bufnr, function(fields)
		local field = fields[8]
		if field then
			local version = field.value
			dict = require("ft-fix.dictionary").load(version)
		end
		if dict then
			annotate_message(bufnr, ns, dict, fields)
			for _, field in pairs(fields) do
				annotate_field(bufnr, ns, dict, field)
			end
		end
	end)
end

return M
