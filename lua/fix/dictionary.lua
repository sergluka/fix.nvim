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

---@alias DictionaryMode "auto"|"repository"|"quickfix"
---@alias DictionaryConfig string|{path: string, mode?: DictionaryMode, version?: string}
---@alias DictionaryRegistry table<string, DictionarySource>

---@class FixDictionaryModule
---@field private _cache? table<string, Dictionary>
---@field resolve_version fun(version: string): string
---@field has_version fun(version: string): boolean
---@field new fun(fields?: FieldsDef, enums?: table<string, EnumDef>): Dictionary
---@field load fun(version: string): Dictionary?
---@field register fun(config: DictionaryConfig): DictionarySource
---@field prepare fun(dictionaries?: table): DictionaryRegistry
---@field apply fun(registry: DictionaryRegistry): boolean
---@field configure fun(dictionaries?: table): DictionaryRegistry
---@field clear_cache fun()
local M = {}

local aliases = {
    ["FIXT.1.1"] = "FIX.5.0SP2",
}

M._custom = {} ---@type DictionaryRegistry

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
---@param custom? DictionaryRegistry
---@return DictionarySource?
local function source_for(version, custom)
    if type(version) ~= "string" or version == "" then
        return nil
    end

    custom = custom or M._custom
    local source = custom[version]
    if source then
        return source
    end

    local resolved = M.resolve_version(version)
    source = custom[resolved]
    if source then
        return source
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
---@param custom? DictionaryRegistry
---@return boolean
function M.has_version(version, custom)
    return source_for(version, custom) ~= nil
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

---@param mode any
---@return DictionaryMode
local function normalize_mode(mode)
    mode = mode or "auto"
    assert(
        mode == "auto" or mode == "repository" or mode == "quickfix",
        "dictionary mode must be auto, repository, or quickfix"
    )
    return mode
end

---@param config DictionaryConfig
---@param explicit_version? string
---@return string path, DictionaryMode mode, string? version
local function normalize_config(config, explicit_version)
    if type(config) == "string" then
        return config, "auto", explicit_version
    end

    assert(type(config) == "table", "dictionary entry must be a path string or table")
    assert(type(config.path) == "string" and config.path ~= "", "dictionary entry must have a non-empty path")
    local version = explicit_version or config.version
    if version ~= nil then
        assert(type(version) == "string" and version ~= "", "dictionary version must be a non-empty string")
    end
    return config.path, normalize_mode(config.mode), version
end

---@param path string
---@param explicit_version? string
---@return DictionarySource
local function detect_repository_source(path, explicit_version)
    path = normalize_path(path)
    local stat = vim.uv.fs_stat(path)
    assert(stat ~= nil, "dictionary path does not exist: " .. path)

    if stat.type ~= "directory" then
        assert(path:match("[/\\]Fields%.xml$"), "repository dictionary mode requires a directory or Fields.xml path")
        path = vim.fs.dirname(path)
        stat = vim.uv.fs_stat(path)
        assert(stat and stat.type == "directory", "dictionary path does not exist: " .. path)
    end

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
    local version = explicit_version or attr(fields_xml.Fields, "version") or path_version(dir)
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

---@param path string
---@param explicit_version? string
---@return DictionarySource
local function detect_quickfix_source(path, explicit_version)
    path = normalize_path(path)
    local stat = vim.uv.fs_stat(path)
    assert(stat ~= nil, "dictionary path does not exist: " .. path)
    assert(stat.type ~= "directory", "quickfix dictionary mode requires an XML file path")

    local xml = parse_file(path)
    local root = xml.fix or xml.FIX
    assert(root ~= nil, "custom dictionary file must be a QuickFIX <fix> XML file")
    local version = explicit_version or quickfix_version(root, path)
    assert(version ~= nil, "cannot detect FIX version for dictionary: " .. path)

    return {
        key = "custom:" .. version .. ":" .. path,
        version = version,
        format = "quickfix",
        path = path,
    }
end

---@param config DictionaryConfig
---@param explicit_version? string
---@return DictionarySource
local function detect_source(config, explicit_version)
    local path, mode, version = normalize_config(config, explicit_version)
    if mode == "repository" then
        return detect_repository_source(path, version)
    elseif mode == "quickfix" then
        return detect_quickfix_source(path, version)
    end

    local normalized_path = normalize_path(path)
    local stat = vim.uv.fs_stat(normalized_path)
    assert(stat ~= nil, "dictionary path does not exist: " .. normalized_path)

    if stat.type == "directory" or normalized_path:match("[/\\]Fields%.xml$") then
        return detect_repository_source(normalized_path, version)
    end
    return detect_quickfix_source(normalized_path, version)
end

---@param source DictionarySource
local function assert_loadable(source)
    -- Parse once at registration time so invalid XML fails before caches are
    -- dropped and the UI is re-rendered.
    local parsed_ok, err = pcall(load_source, source)
    if not parsed_ok then
        error("failed to load custom dictionary: " .. tostring(err), 2)
    end
end

---@param config DictionaryConfig
---@param explicit_version? string
---@return DictionarySource
local function prepare_source(config, explicit_version)
    local source = detect_source(config, explicit_version)
    assert_loadable(source)
    return source
end

---@param dictionaries? table
---@return DictionaryRegistry
local function prepare_registry(dictionaries)
    if dictionaries == nil then
        return {}
    end
    assert(type(dictionaries) == "table", "dictionaries must be a table")

    local registry = {}
    local list_versions = {}
    local list_keys = {}
    for key in pairs(dictionaries) do
        if type(key) == "number" then
            list_keys[#list_keys + 1] = key
        end
    end
    table.sort(list_keys)

    for _, key in ipairs(list_keys) do
        local source = prepare_source(dictionaries[key])
        if list_versions[source.version] then
            error(
                string.format(
                    "multiple dictionaries infer %s; use explicit version keys in setup({ dictionaries = ... })",
                    source.version
                ),
                2
            )
        end
        list_versions[source.version] = true
        registry[source.version] = source
    end

    for version, config in pairs(dictionaries) do
        if type(version) ~= "number" then
            assert(type(version) == "string" and version ~= "", "dictionary version keys must be non-empty strings")
            registry[version] = prepare_source(config, version)
        end
    end

    return registry
end

---@param dictionaries? table
---@return DictionaryRegistry
function M.prepare(dictionaries)
    local ok, registry = pcall(prepare_registry, dictionaries)
    if not ok then
        error("fix.nvim: " .. tostring(registry), 2)
    end
    return registry
end

---@param registry DictionaryRegistry
---@return boolean changed
function M.apply(registry)
    registry = registry or {}
    local changed = not vim.deep_equal(M._custom, registry)
    M._custom = registry
    if changed then
        M.clear_cache()
    end
    M._fingerprint = nil
    return changed
end

---@param dictionaries? table
---@return DictionaryRegistry
function M.configure(dictionaries)
    local registry = M.prepare(dictionaries)
    M.apply(registry)
    return registry
end

---@param config DictionaryConfig
---@return DictionarySource
function M.register(config)
    local ok, source = pcall(prepare_source, config)
    if not ok then
        error("fix.nvim: " .. tostring(source), 2)
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
