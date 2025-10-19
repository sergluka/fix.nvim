-- TODO: docs: Explain issue about 0th line [https://github.com/neovim/neovim/issues/16166]

local dictionary = require("ft-fix.dictionary")
local ts_utils = require("nvim-treesitter.ts_utils")

---@class Field
---@field tag number
---@field tag_start number
---@field tag_end number
---@field value string
---@field value_start number
---@field value_end number

--- @class Message
--- @field version FixVersion
--- @field lineno number
--- @field fields { [number]: Field }

local M = {}

local versions = {
	["FIX.2.7"] = FixVersion.FIX_2_7,
	["FIX.3.0"] = FixVersion.FIX_3_0,
	["FIX.4.0"] = FixVersion.FIX_4_0,
	["FIX.4.1"] = FixVersion.FIX_4_1,
	["FIX.4.2"] = FixVersion.FIX_4_2,
	["FIX.4.3"] = FixVersion.FIX_4_3,
	["FIX.4.4"] = FixVersion.FIX_4_4,
	["FIX.5.0"] = FixVersion.FIX_5_0,
}

---@param buf number
---@param field_node TSNode
---@return Field
local function node_to_field(buf, field_node)
	local tag_node = nil
	local equals_node = nil
	local value_node = nil

	for child in field_node:iter_children() do
		local child_type = child:type()
		if child_type == "tag" then
			tag_node = child
		elseif child_type == "equals" then
			equals_node = child
		elseif child_type == "value" then
			value_node = child
		end
	end

	if not tag_node or not equals_node or not value_node then
		error("unexpected field structure")
	end

	local _, tag_start_col, _, tag_end_col = tag_node:range()
	local _, value_start_col, _, value_end_col = value_node:range()

	local tag_text = vim.treesitter.get_node_text(tag_node, buf)
	local value_text = vim.treesitter.get_node_text(value_node, buf)

	return {
		tag_start = tag_start_col,
		tag_end = tag_end_col,
		value_start = value_start_col,
		value_end = value_end_col,
		tag = tonumber(tag_text),
		value = value_text,
	}
end

---@param fields {[number]: Field}
---@return FixVersion
local function get_version(fields)
	local begin_string = fields[8]
	if not begin_string then
		error("Missing BeginString (tag 8)")
	end

	local version = versions[begin_string.value]
	if not version then
		error("Unknown FIX version: " .. begin_string.value)
	end

	return version
end

---@param buf number
---@param message_node TSNode
---@return Message
local function node_to_message(buf, message_node)
	local lineno, _, _, _ = message_node:range()
	local fields = {}
	for field_node in message_node:iter_children() do
		if field_node:type() == "field" then
			local field = node_to_field(buf, field_node)
			fields[field.tag] = field
		end
	end

	local version
	local ok, result = pcall(get_version, fields)
	if ok then
		version = result
	else
		vim.notify_once("Cannot get FIX version, fallback to FIX.4.0. " .. result, vim.log.levels.WARN)
		version = FixVersion.FIX_4_0
	end

	return {
		version = version,
		lineno = lineno,
		fields = fields,
	}
end

---@param buf number
---@param on_message fun(message: Message)
local function iter_messages(buf, on_message)
	local parser = vim.treesitter.get_parser(buf, "fix")
	if not parser then
		error("No FIX parser for buffer " .. buf)
	end

	local tree = parser:parse()[1]
	local root = tree:root()

	for message_node in root:iter_children() do
		if message_node:type() == "message" then
			local message = node_to_message(buf, message_node)
			on_message(message)
		end
	end
end

---@param opts FixOpts
---@param buf number
---@param ns number
---@param dict Dictionary
---@param lineno number
---@param field Field
local function annotate_field(opts, buf, ns, dict, lineno, field)
	local tag = dict:field(field.tag)
	if tag then
		if opts.annotate.tag.enabled then
			local tag_text = opts.annotate.tag.formatter(tag, field.value)
			if tag_text then
				vim.api.nvim_buf_set_extmark(buf, ns, lineno, field.tag_end, {
					virt_text = { tag_text },
					virt_text_pos = "inline",
				})
			end
		end

		if opts.annotate.value.enabled then
			local value_text = opts.annotate.value.formatter(dict, tag, field.value)
			if value_text then
				vim.api.nvim_buf_set_extmark(buf, ns, lineno, field.value_end, {
					virt_text = { value_text },
					virt_text_pos = "inline",
				})
			end
		end
	end
end

---@param opts FixOpts
---@param buf number
---@param ns number
---@param dict Dictionary
---@param message Message
local function annotate_message(opts, buf, ns, dict, message)
	local line_shift = 0
	if opts.annotate.message.position == "above" then
		line_shift = 0
	else
		line_shift = 1
	end

	vim.api.nvim_buf_set_extmark(buf, ns, message.lineno + line_shift, 0, {
		virt_lines = opts.annotate.message.formatter(dict, message),
		virt_lines_above = true,
	})
end

---@param opts FixOpts
---@param bufnr number
---@param ns number
function M.annotate(opts, bufnr, ns)
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local dict = nil
	iter_messages(bufnr, function(message)
		local begin_string = message.fields[8]
		if begin_string then
			local version = begin_string.value
			dict = dictionary.load(version)
		end
		if dict then
			if opts.annotate.message.enabled then
				local ok, result = pcall(annotate_message, opts, bufnr, ns, dict, message)
				if not ok then
					vim.notify_once("failed to annotate message: " .. result, vim.log.levels.ERROR)
				end
			end
			if opts.annotate.tag.enabled or opts.annotate.value.enabled then
				for _, field in pairs(message.fields) do
					annotate_field(opts, bufnr, ns, dict, message.lineno, field)
				end
			end
		end
	end)
end

---@param buf number
---@return Message|nil, Field|nil
function M.get_field_under_cursor(buf)
	local node = ts_utils.get_node_at_cursor()
	if node == nil then
		return nil, nil
	end
	local node_type = node:type()
	if node_type == "tag" or node_type == "value" or node_type == "equals" then
		local field_node = node:parent()
		if field_node == nil or field_node:type() ~= "field" then
			error("unexpected document structure")
		end
		local field = node_to_field(buf, field_node)

		local message_node = field_node:parent()
		if message_node == nil or message_node:type() ~= "message" then
			error("unexpected document structure")
		end
		local message = node_to_message(buf, message_node)

		return message, field
	else
		return nil, nil
	end
end

return M
