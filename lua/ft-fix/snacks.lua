local document = require("ft-fix.document")

local snacks = require("snacks")

local M = {}

function M.open()
	local items = {}
	document.iter_messages(0, function(message)
		local file = vim.api.nvim_buf_get_name(0)

		for idx, field in pairs(message.fields) do
			local text =
				string.format("%s:%s:%s:%s", field.tag, field.tag_text or "", field.value, field.value_text or "")
			table.insert(items, {
				index = idx,
				text = text,
				message = message,
				field = field,
				lineno = message.lineno,
				file = file,
				pos = { message.lineno + 1, field.tag_start },
				end_pos = { message.lineno + 1, field.value_end },
			})
		end
	end)

	snacks.picker({
		title = "FIX tags",
		layout = {
			preset = "default",
			preview = nil,
		},
		items = items,

		format = function(item, _)
			local field = item.field
			local message = item.message
			local msg_type = message.fields[35]
			local sender = message.fields[49].value
			local seq_no = message.fields[34].value

			local ret = {}
			ret[#ret + 1] = { string.format("%s %s => %s ", seq_no, sender, msg_type.value_text), "Comment" }

			if field.tag_text then
				ret[#ret + 1] = { string.format("%s(%d)", field.tag_text, field.tag), "Type" }
			else
				ret[#ret + 1] = { tostring(field.tag), "Type" }
			end

			ret[#ret + 1] = { "=", "Operator" }

			if field.value_text then
				ret[#ret + 1] = { string.format("%s(%s)", field.value_text, field.value), "Label" }
			else
				ret[#ret + 1] = { field.value, "Label" }
			end

			return ret
		end,

		confirm = function(picker, item)
			picker:close()
			if item then
				local field = item.field ---@type Field
				vim.api.nvim_win_set_cursor(0, { item.lineno + 1, field.tag_start })
			end
		end,
	})
end

return M
