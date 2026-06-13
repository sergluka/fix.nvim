local xml2lua = require("xml2lua")

---@class M
---@field _cache table<string, Dictionary>

---@alias FixMessageType integer
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

local aliases = {
    ["FIXT.1.1"] = "FIX.5.0SP2",
}

local function module_dir()
    return debug.getinfo(1, "S").source:sub(2):match("(.*/)")
end

local function base_path(version)
    return module_dir() .. "../../xml/" .. version .. "/Base/"
end

---@param version string
---@return string
function M.resolve_version(version)
    return aliases[version] or version
end

---@param version string
---@return boolean
function M.has_version(version)
    if type(version) ~= "string" or version == "" then
        return false
    end

    local dir = base_path(M.resolve_version(version))
    return vim.uv.fs_stat(dir .. "Fields.xml") ~= nil and vim.uv.fs_stat(dir .. "Enums.xml") ~= nil
end

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
            type = value.Type,
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
---@return Dictionary?
function M.load(version)
    -- TODO: consider using 1128 (ApplVerID) and 1137 (DefaultApplVerID) to reference the correct SP.
    -- It may be required for validation in the future.
    -- For now, we default to using SP2, where all fields are defined.
    version = M.resolve_version(version)

    if not M.has_version(version) then
        vim.notify_once("fix.nvim: FIX dictionary not found for version " .. tostring(version), vim.log.levels.WARN)
        return nil
    end

    M._cache = M._cache or {}
    if M._cache[version] then
        return M._cache[version]
    end

    vim.notify("fix.nvim: Loading FIX dictionary for version " .. version, vim.log.levels.DEBUG)

    local dir = base_path(version)
    local fields = load_fields(dir, "Fields.xml")
    local enums = load_enums(dir, "Enums.xml")
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
