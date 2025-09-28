local M = {}

function M.init()
	vim.filetype.add({
		filename = {
			[".fix"] = "fix",
			[".fixlog"] = "fix",
			[".fix.txt"] = "fix",
		},
		pattern = {
			[".*"] = function(path, bufnr)
				local line = vim.api.nvim_buf_get_lines(bufnr, 0, 0, false)[1] or ""
				if line:match("^8-FIX") then
					return "fix"
				end
				return nil
			end,
		},
	})
end

function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", {
		-- decorate_on_read = true,
	}, opts or {})

	vim.api.nvim_set_hl(0, "fixTag", { link = "Tag" })
	vim.api.nvim_set_hl(0, "fixValue", { link = "Normal" })
	vim.api.nvim_set_hl(0, "fixAssign", { link = "Operator" })
	vim.api.nvim_set_hl(0, "fixSeparator", { link = "MsgSeparator" })

	local ns = vim.api.nvim_create_namespace("ft-fix")

	vim.api.nvim_create_autocmd({ "BufReadPost", "TextChanged", "TextChangedI" }, {
		group = vim.api.nvim_create_augroup("fix-decorate", { clear = true }),
		callback = function(ev)
			if vim.bo[ev.buf].filetype ~= "fix" then
				return
			end
			require("ft-fix.main").annotate(ev.buf, ns)
		end,
	})
end

return M
