local xml2lua = require("xml2lua")

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

---@class DictionarySource
---@field key string
---@field version string
---@field format "repository"|"quickfix"
---@field path string
---@field fields_path? string
---@field enums_path? string

---@class FixDictionaryModule
---@field private _cache? table<string, Dictionary>
---@field resolve_version fun(version: string): string
---@field has_version fun(version: string): boolean
---@field new fun(fields?: FieldsDef, enums?: table<string, EnumDef>): Dictionary
---@field load fun(version: string): Dictionary?
---@field register fun(path: string): DictionarySource
---@field clear_cache fun()
local M = {}

local aliases = {
    ["FIXT.1.1"] = "FIX.5.0SP2",
}

M._custom = {} ---@type table<string, DictionarySource>

local function module_dir()
    return debug.getinfo(1, "S").source:sub(2):match("(.*/)")
end

local function repo_root()
    return (vim.fn.fnamemodify(module_dir() .. "../..", ":p"):gsub("/$", ""))
end

local function base_path(version)
    return vim.fn.fnamemodify(module_dir() .. "../../xml/" .. version .. "/Base/", ":p")
end

local function as_list(value)
    if value == nil then
        return {}
    end
    if type(value) ~= "table" then
        return { value }
    end
    if value[1] ~= nil then
        return value
    end
    return { value }
end

local function attr(node, name)
    if type(node) ~= "table" then
        return nil
    end
    local attrs = node._attr
    return attrs and (attrs[name] or attrs[name:lower()] or attrs[name:upper()])
end

local function text(value)
    if type(value) == "table" then
        return value[1] or value._text
    end
    return value
end

local function path_version(path)
    local fixt_major, fixt_minor = path:match("FIXT(%d)(%d)")
    if fixt_major then
        return string.format("FIXT.%s.%s", fixt_major, fixt_minor)
    end

    local major, minor, service_pack = path:match("FIX(%d)(%d)SP(%d+)")
    if major then
        return string.format("FIX.%s.%sSP%s", major, minor, service_pack)
    end

    major, minor = path:match("FIX(%d)(%d)")
    if major then
        return string.format("FIX.%s.%s", major, minor)
    end

    return path:match("(FIXT?%.%d+%.%d+SP%d+)") or path:match("(FIXT?%.%d+%.%d+)")
end

local function quickfix_version(root, path)
    local attrs = root and root._attr or {}
    if attrs.version then
        return attrs.version
    end

    local typ = attrs.type or "FIX"
    local major = attrs.major
    local minor = attrs.minor
    if major and minor then
        local version = string.format("%s.%s.%s", typ, major, minor)
        local service_pack = attrs.servicepack or attrs.servicePack
        if service_pack and tonumber(service_pack) and tonumber(service_pack) > 0 then
            version = version .. "SP" .. service_pack
        end
        return version
    end

    return path_version(path)
end

---@param version string
---@return string
function M.resolve_version(version)
    return aliases[version] or version
end

local function has_bundled_version(version)
    local dir = base_path(version)
    return vim.uv.fs_stat(dir .. "Fields.xml") ~= nil and vim.uv.fs_stat(dir .. "Enums.xml") ~= nil
end

---@param version string
---@return DictionarySource?
local function source_for(version)
    if type(version) ~= "string" or version == "" then
        return nil
    end

    local custom = M._custom[version]
    if custom then
        return custom
    end

    local resolved = M.resolve_version(version)
    custom = M._custom[resolved]
    if custom then
        return custom
    end

    if has_bundled_version(resolved) then
        local dir = base_path(resolved)
        return {
            key = "bundled:" .. resolved,
            version = resolved,
            format = "repository",
            path = dir,
            fields_path = dir .. "Fields.xml",
            enums_path = dir .. "Enums.xml",
        }
    end
end

---@param version string
---@return boolean
function M.has_version(version)
    return source_for(version) ~= nil
end

local function parse_file(path)
    local xml = xml2lua.loadFile(path)

    local handler = require("xmlhandler.tree"):new()
    local parser = xml2lua.parser(handler)
    parser:parse(xml)

    return handler.root
end

---@param dir string
---@param file string
---@return FieldsDef
local function load_fields(dir, file)
    local xml = parse_file(dir .. file)

    local dict = {}
    for _, value in ipairs(as_list(xml.Fields.Field)) do
        local tag = tonumber(text(value.Tag))
        assert(tag ~= nil, "Invalid tag: " .. tostring(text(value.Tag)))
        dict[tag] = {
            tag = tag,
            name = text(value.Name),
            type = text(value.Type),
            description = text(value.Description),
        }
    end
    return dict
end

---@param dir string
---@param file string
---@return { [{tag: string, value: string}]: EnumDef }
local function load_enums(dir, file)
    local xml = parse_file(dir .. file)

    local dict = {}
    for _, value in ipairs(as_list(xml.Enums.Enum)) do
        local tag = text(value.Tag)
        local enum_value = text(value.Value)
        dict[tag .. ":" .. enum_value] = {
            name = text(value.SymbolicName),
            description = text(value.Description),
        }
    end
    return dict
end

local function load_quickfix(path)
    local xml = parse_file(path)
    local root = xml.fix or xml.FIX
    assert(root ~= nil, "missing <fix> root")

    local fields_root = root.fields or root.Fields
    assert(fields_root ~= nil, "missing <fields> section")

    local fields = {}
    local enums = {}
    for _, value in ipairs(as_list(fields_root.field or fields_root.Field)) do
        local tag = tonumber(attr(value, "number") or attr(value, "tag"))
        assert(tag ~= nil, "Invalid tag: " .. tostring(attr(value, "number") or attr(value, "tag")))

        fields[tag] = {
            tag = tag,
            name = attr(value, "name"),
            type = attr(value, "type"),
            description = attr(value, "description"),
        }

        for _, enum in ipairs(as_list(value.value or value.Value)) do
            local enum_value = attr(enum, "enum") or attr(enum, "value")
            if enum_value then
                local description = attr(enum, "description") or attr(enum, "name")
                enums[tag .. ":" .. enum_value] = {
                    name = description,
                    description = description,
                }
            end
        end
    end

    local messages_root = root.messages or root.Messages
    if messages_root then
        for _, message in ipairs(as_list(messages_root.message or messages_root.Message)) do
            local msgtype = attr(message, "msgtype")
            local name = attr(message, "name")
            if msgtype and name then
                enums["35:" .. msgtype] = {
                    name = name,
                    description = name,
                }
            end
        end
    end

    return fields, enums
end

---@param source DictionarySource
local function load_source(source)
    if source.format == "quickfix" then
        return load_quickfix(source.path)
    end

    return load_fields(source.path, "Fields.xml"), load_enums(source.path, "Enums.xml")
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
    local source = source_for(version)

    if not source then
        vim.notify_once("fix.nvim: FIX dictionary not found for version " .. tostring(version), vim.log.levels.WARN)
        return nil
    end

    M._cache = M._cache or {}
    if M._cache[source.key] then
        return M._cache[source.key]
    end

    vim.notify("fix.nvim: Loading FIX dictionary for version " .. source.version, vim.log.levels.DEBUG)

    local fields, enums = load_source(source)
    local dict = M.new(fields, enums)
    M._cache[source.key] = dict

    return dict
end

local function normalize_path(path)
    return vim.fn.fnamemodify(vim.fn.expand(path), ":p")
end

---@param path string
---@return DictionarySource
local function detect_source(path)
    path = normalize_path(path)
    local stat = vim.uv.fs_stat(path)
    assert(stat ~= nil, "dictionary path does not exist: " .. path)

    if stat.type == "directory" then
        local dir = path:gsub("/+$", "") .. "/"
        local fields_path = dir .. "Fields.xml"
        local enums_path = dir .. "Enums.xml"
        if vim.uv.fs_stat(fields_path) == nil and vim.uv.fs_stat(dir .. "Base/Fields.xml") ~= nil then
            dir = dir .. "Base/"
            fields_path = dir .. "Fields.xml"
            enums_path = dir .. "Enums.xml"
        end
        assert(vim.uv.fs_stat(fields_path) ~= nil, "dictionary directory is missing Fields.xml: " .. dir)
        assert(vim.uv.fs_stat(enums_path) ~= nil, "dictionary directory is missing Enums.xml: " .. dir)

        local fields_xml = parse_file(fields_path)
        local version = attr(fields_xml.Fields, "version") or path_version(dir)
        assert(version ~= nil, "cannot detect FIX version for dictionary: " .. dir)

        return {
            key = "custom:" .. version .. ":" .. dir,
            version = version,
            format = "repository",
            path = dir,
            fields_path = fields_path,
            enums_path = enums_path,
        }
    end

    if path:match("[/\\]Fields%.xml$") then
        return detect_source(vim.fs.dirname(path))
    end

    local xml = parse_file(path)
    local root = xml.fix or xml.FIX
    assert(root ~= nil, "custom dictionary file must be a QuickFIX <fix> XML file")
    local version = quickfix_version(root, path)
    assert(version ~= nil, "cannot detect FIX version for dictionary: " .. path)

    return {
        key = "custom:" .. version .. ":" .. path,
        version = version,
        format = "quickfix",
        path = path,
    }
end

---@param path string
---@return DictionarySource
function M.register(path)
    local ok, source = pcall(detect_source, path)
    if not ok then
        error("fix.nvim: " .. tostring(source), 2)
    end

    -- Parse once at registration time so invalid XML fails before caches are
    -- dropped and the UI is re-rendered.
    local parsed_ok, err = pcall(load_source, source)
    if not parsed_ok then
        error("fix.nvim: failed to load custom dictionary: " .. tostring(err), 2)
    end

    M._custom[source.version] = source
    M.clear_cache()
    M._fingerprint = nil
    return source
end

function M.clear_cache()
    M._cache = {}
end

local function fingerprint_part(path, root)
    local stat = vim.uv.fs_stat(path)
    if not stat then
        return nil
    end
    local name = path
    if root and path:sub(1, #root + 1) == root .. "/" then
        name = path:sub(#root + 2)
    end
    return string.format("%s:%d:%d", name, stat.mtime.sec, stat.size)
end

function M.fingerprint()
    if M._fingerprint then
        return M._fingerprint
    end

    local root = repo_root()
    local parts = {}
    for _, xml in ipairs(vim.fn.globpath(root .. "/xml", "**/Base/*.xml", false, true)) do
        local part = fingerprint_part(xml, root)
        if part then
            parts[#parts + 1] = part
        end
    end

    for version, source in pairs(M._custom) do
        parts[#parts + 1] = string.format("custom:%s:%s:%s", version, source.format, source.path)
        if source.format == "repository" then
            parts[#parts + 1] = fingerprint_part(source.fields_path)
            parts[#parts + 1] = fingerprint_part(source.enums_path)
        else
            parts[#parts + 1] = fingerprint_part(source.path)
        end
    end

    table.sort(parts)
    M._fingerprint = vim.fn.sha256(table.concat(parts, ";")):sub(1, 16)
    return M._fingerprint
end

---@param tag integer
function M:field(tag)
    return self._fields[tag]
end

---@param tag integer
---@param value string
function M:enum(tag, value)
    return self._enums[tag .. ":" .. value]
end

---@param value string
function M:message(value)
    return self:enum(35, value)
end

return M
