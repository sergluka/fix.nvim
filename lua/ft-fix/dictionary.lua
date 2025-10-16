local xml2lua = require("xml2lua")

---@class M
---@field _cache table<string, Dictionary>

---@alias FixMessageType integer -- XXX: check
---@alias FieldsDef  { [number]: FieldDef }

---@class MessageDef
---@field type FixMessageType
---@field name string
---@field category string
---@field description string

---@class FieldDef
---@field tag number
---@field name string
---@field type string
---@field description string

---@class EnumDef
---@field name string
---@field description string

---@enum FixVersion
FIX_VERSION = {
	FIX_4_0 = "FIX.4.0",
	FIX_4_1 = "FIX.4.1",
	FIX_4_2 = "FIX.4.2",
	FIX_4_3 = "FIX.4.3",
	FIX_4_4 = "FIX.4.4",
	FIXT_1_1 = "FIXT.1.1",
}

---@class Dictionary
---@field private _fields   table<integer, FieldDef>
---@field private _enums    table<string, EnumDef>
Dictionary = {}

function Dictionary.new(fields, enums)
	local self = {
		_fields = fields or {},
		_enums = enums or {},
	}
	setmetatable(self, { __index = Dictionary }) -- __index is set here
	return self
end

--@param tag integer
function Dictionary:field(tag)
	print("Looking up field for tag:", tag)
	return self._fields[tag]
end

--@param tag integer
--@param value string
function Dictionary:enum(tag, value)
	return self._enums[tag .. ":" .. value]
end

--@param value string
function Dictionary:message(value)
	return self:enum(35, value)
end

local function parse(dir, file)
	local xml = xml2lua.loadFile(dir .. file)

	local handler = require("xmlhandler.tree"):new()
	local parser = xml2lua.parser(handler)
	parser:parse(xml)

	return handler.root
end

local M = {}

---@param version FixVersion
---@return Dictionary
function M.load(version)
	M._cache = M._cache or {}
	if M._cache[version] then
		return M._cache[version]
	end

	print("Loading FIX dictionary for version " .. version)
	local module_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
	local base_path = module_dir .. "../../docs/xml/" .. version .. "/Base/"
	local fields = M.load_fields(base_path, "Fields.xml")
	-- local messages = M.load_messages(base_path, "Messages.xml")
	local enums = M.load_enums(base_path, "Enums.xml")
	local dict = Dictionary.new(fields, enums)
	M._cache[version] = dict

	return dict
end

---@param dir string
---@param file string
---@return FieldsDef
function M.load_fields(dir, file)
	local xml = parse(dir, file)

	local dict = {}
	for _, value in ipairs(xml.Fields.Field) do
		local tag = tonumber(value.Tag)
		assert(tag ~= nil, "Invalid tag: " .. value.Tag)
		dict[tag] = {
			tag = tag,
			name = value.Name,
			type = value.Type, -- TODO: convert and use
			description = value.Description,
		}
	end
	return dict
end

-- XXX: seems enum have everything we need for messages
-- ---@param dir string
-- ---@param file string
-- ---@return { [FixMessageType]: MessageDef }
-- function M.load_messages(dir, file)
-- 	local xml = parse(dir, file)
--
-- 	local dict = {}
-- 	for _, value in ipairs(xml.Messages.Message) do
-- 		dict[value.MsgType] = {
-- 			type = value.MsgType,
-- 			name = value.Name,
-- 			category = value.Category,
-- 			description = value.Description,
-- 		}
-- 	end
-- 	return dict
-- end

---@param dir string
---@param file string
---@return { [{tag: string, value: string}]: EnumDef }
function M.load_enums(dir, file)
	local xml = parse(dir, file)

	local dict = {}
	for _, value in ipairs(xml.Enums.Enum) do
		dict[value.Tag .. ":" .. value.Value] = {
			name = value.SymbolicName,
			description = value.Description,
		}
	end
	return dict
end

return M
