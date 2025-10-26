local document = require("fix.document")

local M = {}

---@param opts FixOpts
---@param buf number
---@param ns number
---@param lineno number
---@param field Field
function M.annotate_field(opts, buf, ns, lineno, field)
	if field.tag_text and opts.annotate.tag.enabled then
		local tag_text = opts.annotate.tag.formatter(field)
		if tag_text then
			vim.api.nvim_buf_set_extmark(buf, ns, lineno, field.tag_end, {
				virt_text = { tag_text },
				virt_text_pos = "inline",
			})
		end
	end

	if field.value_text and opts.annotate.value.enabled then
		local value_text = opts.annotate.value.formatter(field)
		if value_text then
			vim.api.nvim_buf_set_extmark(buf, ns, lineno, field.value_end, {
				virt_text = { value_text },
				virt_text_pos = "inline",
			})
		end
	end
end

---@param opts FixOpts
---@param buf number
---@param ns number
---@param message Message
function M.annotate_message(opts, buf, ns, message)
	local line_shift = 0
	if opts.annotate.message.position == "above" then
		line_shift = 0
	else
		line_shift = 1
	end

	vim.api.nvim_buf_set_extmark(buf, ns, message.lineno + line_shift, 0, {
		virt_lines = opts.annotate.message.formatter(message),
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

	document.iter_messages(bufnr, function(message)
		if opts.annotate.message.enabled then
			local ok, result = pcall(M.annotate_message, opts, bufnr, ns, message)
			if not ok then
				vim.notify_once("failed to annotate message: " .. result, vim.log.levels.ERROR)
			end
		end
		if opts.annotate.tag.enabled or opts.annotate.value.enabled then
			for _, field in pairs(message:fields()) do
				M.annotate_field(opts, bufnr, ns, message.lineno, field)
			end
		end
		-- end
	end)
end

return M
