-- TODO: config: tag/value virtual text output format
-- TODO: support custom dictionaries
-- TODO: commands to toggle annotations
-- TODO: line-wise conceal (with custom formatting)
-- TODO: add popup with tag description (and link to onixs) / https://www.onixs.biz/fix-dictionary/4.4/tagNum_1.html
-- TODO: persistent cache
-- TODO: "materialize" annotation
-- TODO: completition?
-- TODO: validation?

---@class FixOpts
---@field annotate table
---@field annotate.field table
---@field annotate.field.enabled boolean
---@field annotate.field.tag.formatter fun(tag: FieldDef, value: string): {text: string, highlight: string}
---@field annotate.field.value.formatter fun(dict: Dictionary, tag: FieldDef, value: string): {text: string, highlight: string} -- FIXME
---@field annotate.message table
---@field annotate.message.enabled boolean
---@field annotate.message.position string "above" | "below"
---@field annotate.message.formatter fun(tag: FieldDef, value: string): {line: {text: string, highlight: string}}

local M = {}

function M.init()
	local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
	---@diagnostic disable-next-line: inject-field
	parser_config.fix = {
		install_info = {
			-- url = "https://github.com/sergluka/tree-sitter-fix",
			url = "~/dev/projects/nvim/tree-sitter-fix",
			files = { "src/parser.c" },
		},
	}
end

---@param opts FixOpts
function M.setup(opts)
	-- TODO: test
	-- TODO: document
	M.opts = vim.tbl_deep_extend("force", {
		---@diagnostic disable: unused-local
		annotate = {
			field = {
				enabled = true,
				tag = {
					formatter = require("ft-fix.formatters.tag").common,
				},
				value = {
					formatter = require("ft-fix.formatters.value").common,
				},
			},
			message = {
				enabled = true,
				position = "above",
				formatter = require("ft-fix.formatters.message").single_line,
			},
		},
	}, opts or {})

	if not M.opts.annotate then
		return
	end

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
