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

---@class FixTagDecodeContext
---@field version string
---@field fields Field[]
---@field dictionary Dictionary

---@class FixTagDecodeResult
---@field tag_text? string
---@field value_text? string

---@alias FixTagDecoder fun(field: Field, ctx: FixTagDecodeContext): FixTagDecodeResult|nil

---@class Dictionary
---@field private _fields   table<integer, FieldDef>
---@field private _enums    table<string, EnumDef>
---@field private _tags     table<integer, FixTagDecoder>

---@class DictionarySource
---@field key string
---@field version string
---@field format "repository"|"quickfix"
---@field path string
---@field fields_path? string
---@field enums_path? string
---@field tags? table<integer, FixTagDecoder>
---@field tags_fingerprint? string

---@alias DictionaryMode "auto"|"repository"|"quickfix"
---@class DictionaryConfigSpec
---@field path? string
---@field mode? DictionaryMode
---@field version? string
---@field tags? table<integer|string, FixTagDecoder>

---@alias DictionaryConfig string|DictionaryConfigSpec
---@alias DictionaryRegistry table<string, DictionarySource>

---@class FixDictionaryModule
---@field private _cache? table<string, Dictionary>
---@field resolve_version fun(version: string): string
---@field has_version fun(version: string, custom?: DictionaryRegistry): boolean
---@field new fun(fields?: FieldsDef, enums?: table<string, EnumDef>, tags?: table<integer, FixTagDecoder>): Dictionary
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

---@param tags table<integer, FixTagDecoder>|nil
---@return string|nil
local function tag_decoders_fingerprint(tags)
    if not tags then
        return nil
    end

    local parts = {}
    for tag, decoder in pairs(tags) do
        parts[#parts + 1] = tostring(tag) .. ":" .. tostring(decoder)
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

---@param version string
---@param tags table<integer, FixTagDecoder>|nil
---@param tags_fingerprint string|nil
---@return DictionarySource?
local function bundled_source(version, tags, tags_fingerprint)
    local resolved = M.resolve_version(version)
    if not has_bundled_version(resolved) then
        return nil
    end

    local dir = base_path(resolved)
    local key = "bundled:" .. resolved
    local source_version = resolved
    if tags then
        source_version = version
        key = "custom:" .. version .. ":bundled:" .. resolved .. ":" .. (tags_fingerprint or "")
    end

    return {
        key = key,
        version = source_version,
        format = "repository",
        path = dir,
        fields_path = dir .. "Fields.xml",
        enums_path = dir .. "Enums.xml",
        tags = tags,
        tags_fingerprint = tags_fingerprint,
    }
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

    return bundled_source(version)
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

function M.new(fields, enums, tags)
    local self = {
        _fields = fields or {},
        _enums = enums or {},
        _tags = tags or {},
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
    local dict = M.new(fields, enums, source.tags)
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

---@param tags any
---@return table<integer, FixTagDecoder>|nil
local function normalize_tags(tags)
    if tags == nil then
        return nil
    end
    assert(type(tags) == "table", "dictionary tags must be a table")

    local normalized = {}
    for tag, decoder in pairs(tags) do
        local tag_number = tonumber(tag)
        assert(
            tag_number ~= nil and tag_number > 0 and tag_number % 1 == 0,
            "dictionary tag keys must be positive integers"
        )
        assert(type(decoder) == "function", "dictionary tag decoder for " .. tostring(tag) .. " must be a function")
        normalized[tag_number] = decoder
    end
    return normalized
end

---@param config DictionaryConfig
---@param explicit_version? string
---@return string? path
---@return DictionaryMode mode
---@return string? version
---@return table<integer, FixTagDecoder>? tags
local function normalize_config(config, explicit_version)
    if type(config) == "string" then
        return config, "auto", explicit_version, nil
    end

    assert(type(config) == "table", "dictionary entry must be a path string or table")
    if config.path == nil then
        assert(config.tags ~= nil, "dictionary entry must have a non-empty path")
    else
        assert(type(config.path) == "string" and config.path ~= "", "dictionary entry must have a non-empty path")
    end
    local version = explicit_version or config.version
    if version ~= nil then
        assert(type(version) == "string" and version ~= "", "dictionary version must be a non-empty string")
    end
    return config.path, normalize_mode(config.mode), version, normalize_tags(config.tags)
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
    local path, mode, version, tags = normalize_config(config, explicit_version)
    local tags_fingerprint = tag_decoders_fingerprint(tags)

    if path == nil then
        assert(version ~= nil, "dictionary entry without path requires an explicit version")
        local source = bundled_source(version, tags, tags_fingerprint)
        assert(source ~= nil, "dictionary entry without path requires a bundled dictionary for " .. version)
        return source
    end

    local source
    if mode == "repository" then
        source = detect_repository_source(path, version)
    elseif mode == "quickfix" then
        source = detect_quickfix_source(path, version)
    else
        local normalized_path = normalize_path(path)
        local stat = vim.uv.fs_stat(normalized_path)
        assert(stat ~= nil, "dictionary path does not exist: " .. normalized_path)

        if stat.type == "directory" or normalized_path:match("[/\\]Fields%.xml$") then
            source = detect_repository_source(normalized_path, version)
        else
            source = detect_quickfix_source(normalized_path, version)
        end
    end

    source.tags = tags
    source.tags_fingerprint = tags_fingerprint
    if tags then
        source.key = source.key .. ":tags:" .. (tags_fingerprint or "")
    end
    return source
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
        if source.tags_fingerprint then
            parts[#parts + 1] = string.format("custom-tags:%s:%s", version, source.tags_fingerprint)
        end
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

---@param field Field
---@param decoded any
local function apply_decode_result(field, decoded)
    if decoded == nil then
        return
    end
    if type(decoded) ~= "table" then
        vim.notify_once("fix.nvim: custom tag decoder returned non-table result", vim.log.levels.ERROR)
        return
    end

    for _, key in ipairs({ "tag_text", "value_text" }) do
        local value = decoded[key]
        if value ~= nil then
            if type(value) ~= "string" then
                vim.notify_once("fix.nvim: custom tag decoder returned non-string " .. key, vim.log.levels.ERROR)
            else
                field[key] = value
            end
        end
    end
end

---@param field Field
---@param ctx FixTagDecodeContext
function M:decode(field, ctx)
    local field_def = self:field(field.tag)
    if field_def then
        field.tag_text = field_def.name
    end

    local enum_def = self:enum(field.tag, field.value)
    if enum_def then
        field.value_text = enum_def.name
    end

    local decoder = self._tags[field.tag]
    if not decoder then
        return
    end

    local ok, decoded = pcall(decoder, field, ctx)
    if not ok then
        vim.notify_once("fix.nvim: custom tag decoder failed: " .. tostring(decoded), vim.log.levels.ERROR)
        return
    end
    apply_decode_result(field, decoded)
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
