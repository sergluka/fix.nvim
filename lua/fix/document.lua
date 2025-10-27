local ts_utils = require("nvim-treesitter.ts_utils")
local dictionary = require("fix.dictionary")
local consts = require("fix.consts")

local M = {}

local versions = {
	["FIX.2.7"] = consts.FixVersion.FIX_2_7,
	["FIX.3.0"] = consts.FixVersion.FIX_3_0,
	["FIX.4.0"] = consts.FixVersion.FIX_4_0,
	["FIX.4.1"] = consts.FixVersion.FIX_4_1,
	["FIX.4.2"] = consts.FixVersion.FIX_4_2,
	["FIX.4.3"] = consts.FixVersion.FIX_4_3,
	["FIX.4.4"] = consts.FixVersion.FIX_4_4,
	["FIXT.1.1"] = consts.FixVersion.FIX_5_0,
}

---@param fields {[number]: Field}
---@return FixVersion?
local function get_version(fields)
	local begin_string = fields[8]
	if not begin_string then
		print("Missing BeginString (tag 8)")
		return nil
	end

	local version = versions[begin_string.value]
	if not version then
		print("Unknown BeginString (tag 8): " .. begin_string.value)
		return nil
	end

	return version
end

---@param buf number
---@param field_node TSNode
---@param index number
---@return Field
local function node_to_field(buf, field_node, index)
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

	return require("fix.field").new({
		index = index,
		tag_start = tag_start_col,
		tag_end = tag_end_col,
		value_start = value_start_col,
		value_end = value_end_col,
		tag = tonumber(tag_text),
		value = value_text,
	})
end

--- @param fields {[string]: Field}
--- @param field Field
local function insert_field(fields, field)
	local key = field.tag

	for index = 1, 100 do
		if fields[key] == nil then
			fields[key] = field
			return
		end
		---@diagnostic disable-next-line: cast-local-type
		key = field.tag .. ":" .. index
	end
	vim.notify_once("Too many duplicate tags, something is wrong", vim.log.levels.WARN)
end

---@param buf number
---@param message_node TSNode
---@return Message
local function node_to_message(buf, message_node)
	local lineno, _, _, _ = message_node:range()
	local fields = {}
	local index = 1
	for field_node in message_node:iter_children() do
		if field_node:type() == "field" then
			local field = node_to_field(buf, field_node, index)
			insert_field(fields, field)
			index = index + 1
		end
	end

	local version = get_version(fields)
	if not version then
		vim.notify_once("Cannot get FIX version, fallback to FIX.4.0", vim.log.levels.WARN)
		version = consts.FixVersion.FIX_4_0
	end

	return require("fix.message").new(version, lineno, fields)
end

---@param message Message
local function decode(message)
	local dict = dictionary.load(message.version)
	if dict then
		for _, field in pairs(message:fields()) do
			local field_def = dict:field(field.tag)
			if field_def then
				field.tag_text = field_def.name
			end
			local enum_def = dict:enum(field.tag, field.value)
			if enum_def then
				field.value_text = enum_def.name
			end
		end
	end
end

---@param buf number
---@param on_message fun(message: Message)
function M.iter_messages(buf, on_message)
	local parser = vim.treesitter.get_parser(buf, "fix")
	if not parser then
		error("No FIX parser for buffer " .. buf)
	end

	local tree = parser:parse()[1]
	local root = tree:root()

	for message_node in root:iter_children() do
		if message_node:type() == "message" then
			local message = node_to_message(buf, message_node)
			decode(message)
			on_message(message)
		end
	end
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

		local message_node = field_node:parent()
		if message_node == nil or message_node:type() ~= "message" then
			error("unexpected document structure")
		end
		local message = node_to_message(buf, message_node)
		decode(message)

		for _, field in pairs(message:fields()) do
			local _, tag_start_col = field_node:range()
			if field.tag_start == tag_start_col then
				return message, field
			end
		end
		error("field not found in message")
	else
		return nil, nil
	end
end

return M
