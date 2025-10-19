---@class Field
---@field tag number
---@field tag_start number
---@field tag_end number
---@field value string
---@field value_start number
---@field value_end number

--- @class Message
--- @field version FixVersion
--- @field lineno number
--- @field fields { [number]: Field }

local dictionary = require("ft-fix.dictionary")
local document = require("ft-fix.document")

local M = {}

---@param opts FixOpts
---@param buf number
---@param ns number
---@param dict Dictionary
---@param lineno number
---@param field Field
local function annotate_field(opts, buf, ns, dict, lineno, field)
	local tag = dict:field(field.tag)
	if tag then
		if opts.annotate.tag.enabled then
			local tag_text = opts.annotate.tag.formatter(tag, field.value)
			if tag_text then
				vim.api.nvim_buf_set_extmark(buf, ns, lineno, field.tag_end, {
					virt_text = { tag_text },
					virt_text_pos = "inline",
				})
			end
		end

		if opts.annotate.value.enabled then
			local value_text = opts.annotate.value.formatter(dict, tag, field.value)
			if value_text then
				vim.api.nvim_buf_set_extmark(buf, ns, lineno, field.value_end, {
					virt_text = { value_text },
					virt_text_pos = "inline",
				})
			end
		end
	end
end

---@param opts FixOpts
---@param buf number
---@param ns number
---@param dict Dictionary
---@param message Message
local function annotate_message(opts, buf, ns, dict, message)
	local line_shift = 0
	if opts.annotate.message.position == "above" then
		line_shift = 0
	else
		line_shift = 1
	end

	vim.api.nvim_buf_set_extmark(buf, ns, message.lineno + line_shift, 0, {
		virt_lines = opts.annotate.message.formatter(dict, message),
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
	document.iter_messages(bufnr, function(message)
		local begin_string = message.fields[8]
		if begin_string then
			local version = begin_string.value
			dict = dictionary.load(version)
		end
		if dict then
			if opts.annotate.message.enabled then
				local ok, result = pcall(annotate_message, opts, bufnr, ns, dict, message)
				if not ok then
					vim.notify_once("failed to annotate message: " .. result, vim.log.levels.ERROR)
				end
			end
			if opts.annotate.tag.enabled or opts.annotate.value.enabled then
				for _, field in pairs(message.fields) do
					annotate_field(opts, bufnr, ns, dict, message.lineno, field)
				end
			end
		end
	end)
end

return M
