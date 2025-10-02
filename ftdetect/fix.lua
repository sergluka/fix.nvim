vim.filetype.add({
	extension = {
		fix = "fix",
		fixlog = "fix",
	},
	pattern = {
		[".*"] = {
			function(path, bufnr)
				local content = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
				print("content", content)
				if vim.regex([[^8=FIX]]):match_str(content) ~= nil then
					return "fix"
				end
			end,
			{ priority = -math.huge },
		},
	},
})
