local M = {}

function M.init()
	local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
	---@diagnostic disable-next-line: inject-field
	parser_config.fix = {
		install_info = {
			url = "https://github.com/sergluka/tree-sitter-fix",
			files = { "src/parser.c" },
		},
		filetype = "fix",
	}

	-- (Optional) explicit ft->lang hook; harmless if your ft is already 'fix'
	vim.treesitter.language.register("fix", "fix")
end

function M.setup(opts)
	-- M.opts = vim.tbl_deep_extend("force", {
	-- 	annotate = true,
	-- }, opts or {})
end

M.init()

return M
