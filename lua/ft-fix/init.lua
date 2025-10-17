-- TODO: support custom dictionaries
-- TODO: line-wise conceal (with custom formatting)
-- TODO: add popup with tag description (and link to onixs) / https://www.onixs.biz/fix-dictionary/4.4/tagNum_1.html
-- TODO: persistent cache
-- TODO: "materialize" annotation
-- TODO: completition?
-- TODO: validation?
-- TODO: vimdoc

---@class FixOpts
---@field ft table
---@field ft.extensions string[]
---@field ft.pattern string[]
---@field annotate table
---@field annotate.field table
---@field annotate.field.tag.enabled boolean
---@field annotate.field.tag.formatter fun(tag: FieldDef, value: string): {text: string, highlight: string}
---@field annotate.field.value.enabled boolean
---@field annotate.field.value.formatter fun(dict: Dictionary, tag: FieldDef, value: string): {text: string, highlight: string}
---@field annotate.message table
---@field annotate.message.enabled boolean
---@field annotate.message.position string "above" | "below"
---@field annotate.message.formatter fun(tag: FieldDef, value: string): {line: {text: string, highlight: string}}

local M = {}

local ns = vim.api.nvim_create_namespace("ft-fix")

local function init()
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

--- @param opts FixOpts
local function register_filetype(opts)
	local patterns = {}
	for _, pattern in ipairs(opts.ft.pattern) do
		patterns[pattern] = "fix"
	end
	local extentions = {}
	for _, ext in ipairs(opts.ft.extensions) do
		extentions[ext] = "fix"
	end
	vim.filetype.add({
		extension = extentions,
		pattern = patterns,
	})
end

local function register_autocmds(opts, ns)
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter", "BufAdd", "TextChanged", "TextChangedI" }, {
		group = vim.api.nvim_create_augroup("fix-decorate", { clear = true }),
		callback = function(args)
			if vim.bo[args.buf].filetype == "fix" then
				require("ft-fix.main").annotate(M.opts, args.buf, ns)
			end
		end,
	})

	vim.api.nvim_create_autocmd("FileType", {
		pattern = "fix",
		callback = function(args)
			require("ft-fix.main").annotate(M.opts, args.buf, ns)
		end,
	})
end

local function register_commands(opts)
	local cmdparse = require("mega.cmdparse")

	local parser = cmdparse.ParameterParser.new({ name = "FIX", help = "FIX protocol" })
	local toggle_subparser = parser:add_subparsers({ destination = "commands" })

	local toggle = toggle_subparser:add_parser({ name = "toggle", help = "Toggle annotations" })
	toggle:add_parameter({ name = "scope", choices = { "tag", "value", "message" }, help = "Type of annotation" })

	parser:set_execute(function(data)
		M.annotate_toggle(data.namespace.scope)
	end)

	cmdparse.create_user_command(parser)
end

---@param opts FixOpts
function M.setup(opts)
	-- TODO: test
	-- TODO: document
	M.opts = vim.tbl_deep_extend("force", {
		---@diagnostic disable: unused-local
		ft = {
			extensions = { "fix", "fixlog" },
			pattern = { ".*%.fix.txt" },
		},
		annotate = {
			tag = {
				enabled = true,
				formatter = require("ft-fix.formatters.tag").common,
			},
			value = {
				enabled = true,
				formatter = require("ft-fix.formatters.value").common,
			},
			message = {
				enabled = true,
				position = "above",
				formatter = require("ft-fix.formatters.message").single_line,
			},
		},
	}, opts or {})

	register_filetype(M.opts)
	register_commands(M.opts)
	register_autocmds(M.opts, ns)
end

---@param scope "tag" | "value" | "message"
function M.annotate_toggle(scope)
	if scope == "tag" then
		M.opts.annotate.tag.enabled = not M.opts.annotate.tag.enabled
	elseif scope == "value" then
		M.opts.annotate.value.enabled = not M.opts.annotate.value.enabled
	elseif scope == "message" then
		M.opts.annotate.message.enabled = not M.opts.annotate.message.enabled
	end

	local buf = vim.api.nvim_get_current_buf()
	require("ft-fix.main").annotate(M.opts, buf, ns)
end

init()

return M
