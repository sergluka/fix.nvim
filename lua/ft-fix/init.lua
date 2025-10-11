local M = {}

function M.init()
	local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
	---@diagnostic disable-next-line: inject-field
	parser_config.fix = {
		install_info = {
			url = "https://github.com/sergluka/tree-sitter-fix",
			files = { "src/parser.c" },
		},
	}
end

function M.setup(opts)
	-- M.opts = vim.tbl_deep_extend("force", {
	-- 	annotate = true,
	-- }, opts or {})

	local ns = vim.api.nvim_create_namespace("ft-fix")

	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter", "BufAdd", "TextChanged", "TextChangedI" }, {
		group = vim.api.nvim_create_augroup("fix-decorate", { clear = true }),
		callback = function(ev)
			-- TODO: add to settings, limit for filetype
			if vim.bo[ev.buf].filetype == "fix" then
				require("ft-fix.main").annotate(M.opts, ev.buf, ns)
			end
		end,
	})
end

M.init()

return M
