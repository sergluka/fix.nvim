-- TODO: support groups
-- TODO: formatting for sender/receiver
-- TODO: support custom dictionaries
-- TODO: add option for custom tags
-- TODO: lazy dict loading
-- TODO: line-wise conceal (with custom formatting)
-- TODO: "materialize" annotation
-- TODO: completition?
-- TODO: validation?
-- TODO: documentation
-- TODO: vimdoc
-- TODO: add command to browse tag info
-- TODO: docs: Explain issue about 0th line [https://github.com/neovim/neovim/issues/16166]
-- TODO: docs: add link to original FIX xmls

local main = require("ft-fix.main")
local utils = require("ft-fix.utils")

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
---@field annotate.message.formatter fun(dict: Dictionary, message: Message): {line: {text: string, highlight: string}}

local M = {}

-- TODO: test
-- TODO: document
local DEFAULT_OPTS = {
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
}

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

	M.ns = vim.api.nvim_create_namespace("ft-fix")
end

--- @param opts FixOpts
local function register_filetype()
	local patterns = {}
	for _, pattern in ipairs(M.opts.ft.pattern) do
		patterns[pattern] = "fix"
	end
	local extentions = {}
	for _, ext in ipairs(M.opts.ft.extensions) do
		extentions[ext] = "fix"
	end
	vim.filetype.add({
		extension = extentions,
		pattern = patterns,
	})
end

local function register_autocmds()
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter", "BufAdd", "TextChanged", "TextChangedI" }, {
		group = vim.api.nvim_create_augroup("fix-decorate", { clear = true }),
		callback = function(args)
			if vim.bo[args.buf].filetype == "fix" then
				require("ft-fix.main").annotate(M.opts, args.buf, M.ns)
			end
		end,
	})

	vim.api.nvim_create_autocmd("FileType", {
		pattern = "fix",
		callback = function(args)
			require("ft-fix.main").annotate(M.opts, args.buf, M.ns)
		end,
	})
end

local function register_commands()
	local cmdparse = require("mega.cmdparse")

	local parser = cmdparse.ParameterParser.new({ name = "FIX", help = "FIX protocol" })
	local toggle_subparser = parser:add_subparsers({ destination = "commands" })

	local toggle = toggle_subparser:add_parser({ name = "annotations", help = "Toggle annotations" })
	toggle:add_parameter({
		name = "scope",
		required = false,
		choices = { "all", "tag", "value", "message" },
		help = "Type of annotation",
	})

	parser:set_execute(function(data)
		M.annotate_toggle(data.namespace.scope)
	end)

	cmdparse.create_user_command(parser)
end

---@param opts FixOpts
function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", DEFAULT_OPTS, opts or {})
	M.opts_initial = vim.deepcopy(M.opts)

	register_filetype()
	register_commands()
	register_autocmds()
end

---@param opts FixOpts
---@param scope "all | tag" | "value" | "message" | nil
function M.annotate_toggle(scope)
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].filetype ~= "fix" then
		return
	end

	if scope == "all" or scope == nil then
		local someone_is_enabled = M.opts.annotate.tag.enabled
			or M.opts.annotate.value.enabled
			or M.opts.annotate.message.enabled

		if someone_is_enabled then
			M.opts_initial = vim.deepcopy(M.opts)
			M.opts.annotate.tag.enabled = false
			M.opts.annotate.value.enabled = false
			M.opts.annotate.message.enabled = false
		else
			M.opts.annotate.tag.enabled = M.opts_initial.annotate.tag.enabled
			M.opts.annotate.value.enabled = M.opts_initial.annotate.value.enabled
			M.opts.annotate.message.enabled = M.opts_initial.annotate.message.enabled
		end
	elseif scope == "tag" then
		M.opts.annotate.tag.enabled = not M.opts.annotate.tag.enabled
	elseif scope == "value" then
		M.opts.annotate.value.enabled = not M.opts.annotate.value.enabled
	elseif scope == "message" then
		M.opts.annotate.message.enabled = not M.opts.annotate.message.enabled
	end

	main.annotate(M.opts, buf, M.ns)
end

function M.open_online_tag_info()
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].filetype ~= "fix" then
		return
	end
	local message, field = main.get_field_under_cursor(buf)
	if message == nil or field == nil then
		return
	end

	utils.open_url(string.format("https://www.onixs.biz/fix-dictionary/%s/tagNum_%d.html", message.version, field.tag))
end

init()

return M
