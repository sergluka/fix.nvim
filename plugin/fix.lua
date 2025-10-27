-- This plugin includes data derived from the FIX Repository
-- © FIX Protocol Limited (FPL). Used under licence.
-- FPL is not responsible for any modifications or errors in this implementation.

if vim.g.loaded_fix then
	return
end
vim.g.loaded_fix = true

local ok, fix = pcall(require, "fix")
if not ok then
	vim.notify("fix.nvim: failed to load core module", vim.log.levels.ERROR)
	return
end

local function register_treesitter()
	local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
	---@diagnostic disable-next-line: inject-field
	parser_config.fix = {
		install_info = {
			url = "https://github.com/sergluka/tree-sitter-fix",
			files = { "src/parser.c" },
		},
	}

	M.ns = vim.api.nvim_create_namespace("fix-protocol")
end

local function register_commands()
	local cmdparse = require("mega.cmdparse")

	local parser = cmdparse.ParameterParser.new({ name = "FIX", help = "FIX protocol" })
	local top_subparser = parser:add_subparsers({ destination = "commands" })

	local toggle = top_subparser:add_parser({ name = "annotations", help = "Toggle annotations" })
	toggle:add_parameter({
		name = "scope",
		required = false,
		choices = { "all", "tag", "value", "message" },
		help = "Type of annotation",
	})
	toggle:set_execute(function(data)
		M.annotate_toggle(data.namespace.scope)
	end)

	local picker = top_subparser:add_parser({ name = "picker", help = "Open fields picker" })
	picker:set_execute(function()
		require("fix.snacks").open()
	end)

	local browse = top_subparser:add_parser({ name = "browse", help = "Open tag info online" })
	browse:set_execute(function()
		require("fix").browse_tag_online()
	end)

	local yank_parser = top_subparser:add_parser({ name = "yank", help = "Yank annotations" })
	yank_parser:add_parameter({
		name = "yank",
		required = false,
		choices = { "field", "message" },
		help = "Type of annotation",
		yank_parser:add_parameter({
			name = "--reg",
			required = false,
			help = "Register",
		}),
	})
	yank_parser:set_execute(function(data)
		local register = data.namespace.reg
		if data.namespace.yank == "field" then
			M.yank_field(register)
		elseif data.namespace.yank == "message" then
			M.yank_message(register)
		end
	end)

	cmdparse.create_user_command(parser)
end

register_treesitter()
register_commands()
