-- This plugin includes data derived from the FIX Repository
-- © FIX Protocol Limited (FPL). Used under licence.
-- FPL is not responsible for any modifications or errors in this implementation.

-- TODO: support groups
-- TODO: formatting for sender/receiver
-- TODO: support custom dictionaries
-- TODO: add option for custom tags
-- TODO: lazy dict loading
-- TODO: line-wise conceal (with custom formatting)
-- TODO: competition?
-- TODO: validation?
-- TODO: docs: Explain issue about 0th line [https://github.com/neovim/neovim/issues/16166]
-- TODO: vimdoc
-- TODO: CI: busted, linter
-- TODO: handle v mode for yank
-- TODO: yank in picker
-- TODO: highlight values based on Type

---@class FixOpts
---@field ft table
---@field ft.extensions string[]
---@field ft.pattern string[]
---@field annotate table
---@field annotate.field table
---@field annotate.field.tag.enabled boolean
---@field annotate.field.tag.formatter fun(field: Field): {text: string, highlight: string}
---@field annotate.field.value.enabled boolean
---@field annotate.field.value.formatter fun(field: Field): {text: string, highlight: string}
---@field annotate.message table
---@field annotate.message.enabled boolean
---@field annotate.message.position string "above" | "below"
---@field annotate.message.formatter fun(message: Message): {line: {text: string, highlight: string}}

---@enum FixVersion
FixVersion = {
	FIX_2_7 = "FIX.2.7",
	FIX_3_0 = "FIX.3.0",
	FIX_4_0 = "FIX.4.0",
	FIX_4_1 = "FIX.4.1",
	FIX_4_2 = "FIX.4.2",
	FIX_4_3 = "FIX.4.3",
	FIX_4_4 = "FIX.4.4",
	FIX_5_0 = "FIXT.1.1",
}

local document = require("fix.document")
local annotate = require("fix.annotate")
local yank = require("fix.yank")
local utils = require("fix.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("fix-protocol")

-- TODO: test
-- TODO: document
local default_settings = {
	ft = {
		extensions = { "fix", "fixlog" },
		pattern = { ".*%.fix.txt" },
	},
	annotate = {
		tag = {
			enabled = true,
			formatter = require("fix.formatters.tag").default,
		},
		value = {
			enabled = true,
			formatter = require("fix.formatters.value").default,
		},
		message = {
			enabled = true,
			position = "above",
			formatter = require("fix.formatters.message").default,
		},
	},
}

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
				annotate.annotate(M.opts, args.buf, ns)
			end
		end,
	})

	vim.api.nvim_create_autocmd("FileType", {
		pattern = "fix",
		callback = function(args)
			annotate.annotate(M.opts, args.buf, M.ns)
		end,
	})
end

---@param opts FixOpts
function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", default_settings, opts or {})
	M.opts_initial = vim.deepcopy(M.opts)

	register_filetype()
	register_autocmds()
end

---@param scope? "all" | "tag" | "value" | "message"
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

	annotate.annotate(M.opts, buf, M.ns)
end

function M.browse_tag_online()
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].filetype ~= "fix" then
		return
	end
	local message, field = document.get_field_under_cursor(buf)
	if message == nil or field == nil then
		return
	end

	local versions = {
		[FixVersion.FIX_2_7] = "2.7",
		[FixVersion.FIX_3_0] = "3.0",
		[FixVersion.FIX_4_0] = "4.0",
		[FixVersion.FIX_4_1] = "4.1",
		[FixVersion.FIX_4_2] = "4.2",
		[FixVersion.FIX_4_3] = "4.3",
		[FixVersion.FIX_4_4] = "4.4",
		[FixVersion.FIX_5_0] = "5.0",
	}

	utils.open_url(
		string.format("https://www.onixs.biz/fix-dictionary/%s/tagNum_%d.html", versions[message.version], field.tag)
	)
end

---@param regname string?
function M.yank_field(regname)
	yank.yank_field(M.opts, regname)
end

---@param regname string?
function M.yank_message(regname)
	yank.yank_message(M.opts, regname)
end

return M
