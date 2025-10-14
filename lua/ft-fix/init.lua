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
---@field annotate.field.value.formatter fun(msg: MessageDef): {text: string, highlight: string} -- FIXME
---@field annotate.message table
---@field annotate.message.enabled boolean
---@field annotate.message.position string "above" | "below"
---@field annotate.message.formatter fun(tag: FieldDef, value: string): {text: string, highlight: string}

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
					formatter = function(tag, value)
						return { "(" .. tag.name .. ")", "Comment" }
					end,
				},
				value = {
					formatter = function(msg)
						return { "(" .. msg.name .. ")", "Type" }
					end,
				},
			},
			message = {
				enabled = true,
				position = "above",
				formatter = function(dict, fields)
					local text = string.format(
						"%s: %d: %s=>%s | %s |",
						fields[52].data.value,
						fields[34].data.value,
						fields[49].data.value,
						fields[56].data.value,
						dict.messages[fields[35].data.value].name
					)
					local win_width = vim.api.nvim_win_get_width(0)

					-- TODO: docs: sample:
					-- { { string.rep("-", win_width), "MsgSeparator" } },

					return {
						{ { text, "Title" } },
					}
				end,
				-- highlight = "Title",
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
