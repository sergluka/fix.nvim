local M = {}

local document = require("fix.document")

local ns = vim.api.nvim_create_namespace("blink_region")

local function field_to_text(opts, field)
	local tag = opts.annotate.tag.formatter(field)
	if tag ~= nil then
		tag = tostring(field.tag) .. tag[1]
	else
		tag = tostring(field.tag)
	end

	local value = opts.annotate.value.formatter(field)
	if value ~= nil then
		value = field.value .. tostring(value[1])
	else
		value = field.value
	end

	return string.format("%s=%s", tag, value)
end

local function blink(buf, start_row, start_col, end_row, end_col)
	local timeout = 150 -- ms

	local id = vim.api.nvim_buf_set_extmark(buf, ns, start_row, start_col, {
		end_row = end_row,
		end_col = end_col,
		hl_group = "IncSearch",
		hl_mode = "combine",
	})

	vim.defer_fn(function()
		pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
	end, timeout)
end

---@param opts FixOpts
---@param regname string
function M.yank_field(opts, regname)
	local buf = vim.api.nvim_get_current_buf()
	local message, field = document.get_field_under_cursor(buf)
	if message == nil or field == nil then
		return
	end

	local text = field_to_text(opts, field)
	vim.fn.setreg(regname, text)

	local lineno = message.lineno
	blink(buf, lineno, field.tag_start, lineno, field.value_end)
end

---@param opts FixOpts
---@param regname string
function M.yank_message(opts, regname)
	local buf = vim.api.nvim_get_current_buf()
	local message, _ = document.get_field_under_cursor(buf)
	if message == nil then
		return
	end

	local fields = message:list_fields()

	local txt_fields = {}
	for _, field in pairs(fields) do
		txt_fields[#txt_fields + 1] = field_to_text(opts, field)
	end
	local text = table.concat(txt_fields, "|")

	vim.fn.setreg(regname, text)

	local lineno = message.lineno
	blink(buf, lineno, fields[1].tag_start, lineno, fields[#fields].value_end)
end

return M
