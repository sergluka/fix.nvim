-- TODO
-- set breakat=\|
-- set wrap
-- syntax match BreakPipe /|/ conceal cchar=⏎

---@class Field
---@field lineno number
---@field tag_start number
---@field tag_end number
---@field value_start number
---@field value_end number
---@field tag number
---@field value string

---@alias Fields { [number]: Field }

local M = {}

---@param buf number
---@param on_message fun(lineno: number, message: Fields)
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

					-- TODO: check for duplicates (handle groups)
					assert(tag ~= nil, "tag is nil")
					assert(value ~= nil, "value is nil")
					fields[tag] = {
						lineno = lineno,
						tag_start = tag_start,
						tag_end = tag_end,
						value_start = value_start,
						value_end = value_end,
						tag = tag,
						value = value,
					}
				end
			end
			on_message(lineno, fields)
		end
	end
end

---@param opts FixOpts
---@param buf number
---@param ns number
---@param dict Dictionary
---@param field Field
local function annotate_field(opts, buf, ns, dict, field)
	local tag = dict:field(field.tag)
	if tag then
		local tag_text = opts.annotate.field.tag.formatter(tag, field.value)
		if tag_text then
			vim.api.nvim_buf_set_extmark(buf, ns, field.lineno, field.tag_end, {
				virt_text = { tag_text },
				virt_text_pos = "inline",
			})
		end

		local value_text = opts.annotate.field.value.formatter(dict, tag, field.value)
		if value_text then
			vim.api.nvim_buf_set_extmark(buf, ns, field.lineno, field.value_end, {
				virt_text = { value_text },
				virt_text_pos = "inline",
			})
		end
	end
end

-- TODO: docs: Explain issue about 0th line [https://github.com/neovim/neovim/issues/16166]

---@param opts FixOpts
---@param buf number
---@param ns number
---@param dict Dictionary
---@param lineno number
---@param fields Fields
local function annotate_message(opts, buf, ns, dict, lineno, fields)
	local line_shift = 0
	if opts.annotate.message.position == "above" then
		line_shift = 0
	else
		line_shift = 1
	end

	vim.api.nvim_buf_set_extmark(buf, ns, lineno + line_shift, 0, {
		virt_lines = opts.annotate.message.formatter(dict, fields),
		virt_lines_above = true,
	})
end

---@param opts FixOpts
---@param bufnr number
---@param ns number
function M.annotate(opts, bufnr, ns)
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local dict = nil
	iter_messages(bufnr, function(lineno, fields)
		local begin_string = fields[8]
		if begin_string then
			local version = begin_string.value
			dict = require("ft-fix.dictionary").load(version)
		end
		if dict then
			if opts.annotate.message.enabled then
				annotate_message(opts, bufnr, ns, dict, lineno, fields)
			end
			if opts.annotate.field.enabled then
				for _, field in pairs(fields) do
					annotate_field(opts, bufnr, ns, dict, field)
				end
			end
		end
	end)
end

return M
