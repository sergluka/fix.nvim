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

---@class Dictionary
---@field private _fields   table<integer, FieldDef>
---@field private _enums    table<string, EnumDef>
local M = {}

local function parse(dir, file)
	local xml = xml2lua.loadFile(dir .. file)

	local handler = require("xmlhandler.tree"):new()
	local parser = xml2lua.parser(handler)
	parser:parse(xml)

	return handler.root
end

---@param dir string
---@param file string
---@return FieldsDef
local function load_fields(dir, file)
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

---@param dir string
---@param file string
---@return { [{tag: string, value: string}]: EnumDef }
local function load_enums(dir, file)
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

function M.new(fields, enums)
	local self = {
		_fields = fields or {},
		_enums = enums or {},
	}
	setmetatable(self, { __index = M }) -- __index is set here
	return self
end

---@param version string
---@return Dictionary
function M.load(version)
	-- TODO: consider using 1128 (ApplVerID) and 1137 (DefaultApplVerID) to reference the correct SP.
	-- It may be required for validation in the future.
	-- For now, we default to using SP2, where all fields are defined.
	if version == "FIXT.1.1" then
		version = "FIX.5.0SP2"
	end

	M._cache = M._cache or {}
	if M._cache[version] then
		return M._cache[version]
	end

	print("Loading FIX dictionary for version " .. version)

	local module_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
	local base_path = module_dir .. "../../xml/" .. version .. "/Base/"
	local fields = load_fields(base_path, "Fields.xml")
	local enums = load_enums(base_path, "Enums.xml")
	local dict = M.new(fields, enums)
	M._cache[version] = dict

	return dict
end

--@param tag integer
function M:field(tag)
	return self._fields[tag]
end

--@param tag integer
--@param value string
function M:enum(tag, value)
	return self._enums[tag .. ":" .. value]
end

--@param value string
function M:message(value)
	return self:enum(35, value)
end

return M
