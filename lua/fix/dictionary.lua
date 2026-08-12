local xml2lua = require("xml2lua")

---@alias FixMessageType integer
---@alias FieldsDef  { [number]: FieldDef }
---@alias GroupDefsByTag table<integer, GroupDef>

---@class MessageDef
---@field type string           MsgType value, e.g. "D"
---@field name string
---@field category? string
---@field description? string

---@class FieldDef
---@field tag number
---@field name string
---@field type string
---@field description string

---@class GroupDef
---@field name string
---@field count_tag integer
---@field delimiter_tag integer?
---@field member_tags table<integer, boolean>
---@field groups_by_count GroupDefsByTag

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
---@field private _groups   table<string, GroupDefsByTag>
---@field private _messages table<string, MessageDef>

---@class DictionarySource
---@field key string
---@field version string
---@field format "repository"|"quickfix"
---@field path string
---@field fields_path? string
---@field enums_path? string
---@field messages_path? string
---@field msg_contents_path? string
---@field components_path? string
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
---@field new fun(fields?: FieldsDef, enums?: table<string, EnumDef>, tags?: table<integer, FixTagDecoder>,
---  groups?: table<string, GroupDefsByTag>, messages?: table<string, MessageDef>): Dictionary
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
        messages_path = dir .. "Messages.xml",
        msg_contents_path = dir .. "MsgContents.xml",
        components_path = dir .. "Components.xml",
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

local function field_by_name(fields)
    local by_name = {}
    for tag, field in pairs(fields) do
        by_name[field.name] = tag
    end
    return by_name
end

local function group_member_tags(children)
    local tags = {}
    for _, child in ipairs(children) do
        if child.kind == "field" then
            tags[child.tag] = true
        elseif child.kind == "group" then
            tags[child.count_tag] = true
        end
    end
    return tags
end

local function group_defs_by_count(children)
    local groups = {}
    for _, child in ipairs(children) do
        if child.kind == "group" then
            groups[child.count_tag] = child
        end
    end
    return groups
end

local function first_child_tag(children)
    for _, child in ipairs(children) do
        if child.kind == "field" then
            return child.tag
        elseif child.kind == "group" then
            return child.count_tag
        end
    end
end

local function new_group(name, count_tag, children)
    return {
        kind = "group",
        name = name,
        count_tag = count_tag,
        delimiter_tag = first_child_tag(children),
        member_tags = group_member_tags(children),
        groups_by_count = group_defs_by_count(children),
    }
end

local function can_count_group(field)
    if not field then
        return false
    end
    local field_type = field.type
    if type(field_type) == "string" and field_type:lower() == "numingroup" then
        return true
    end
    return type(field.name) == "string" and field.name:match("^No") ~= nil
end

---@param children table[]
---@param start integer
---@param parent_indent integer
---@param fields FieldsDef
---@return table[], integer
local function grouped_by_indent(children, start, parent_indent, fields)
    local grouped = {}
    local index = start
    while index <= #children do
        local child = children[index]
        local indent = child.indent or 0
        if indent <= parent_indent then
            break
        end

        if child.kind == "field" and can_count_group(fields[child.tag]) then
            local nested, next_index = grouped_by_indent(children, index + 1, indent, fields)
            if #nested > 0 then
                grouped[#grouped + 1] = new_group(fields[child.tag].name, child.tag, nested)
                index = next_index
            else
                grouped[#grouped + 1] = child
                index = index + 1
            end
        else
            grouped[#grouped + 1] = child
            index = index + 1
        end
    end
    return grouped, index
end

local function repository_structure_paths(dir)
    local messages_path = dir .. "Messages.xml"
    local msg_contents_path = dir .. "MsgContents.xml"
    local components_path = dir .. "Components.xml"
    if
        vim.uv.fs_stat(messages_path) == nil
        or vim.uv.fs_stat(msg_contents_path) == nil
        or vim.uv.fs_stat(components_path) == nil
    then
        return nil
    end
    return messages_path, msg_contents_path, components_path
end

local function load_repository_groups(dir, fields)
    local messages_path, msg_contents_path, components_path = repository_structure_paths(dir)
    if not messages_path then
        return {}, {}
    end

    local messages_xml = parse_file(messages_path)
    local contents_xml = parse_file(msg_contents_path)
    local components_xml = parse_file(components_path)

    local components_by_name = {}
    for _, component in ipairs(as_list(components_xml.Components.Component)) do
        local id = tonumber(text(component.ComponentID))
        local name = text(component.Name)
        if id and name then
            local def = {
                id = id,
                name = name,
                component_type = text(component.ComponentType) or "",
            }
            components_by_name[name] = def
        end
    end

    local contents_by_component = {}
    for _, content in ipairs(as_list(contents_xml.MsgContents.MsgContent)) do
        local component_id = tonumber(text(content.ComponentID))
        local tag_text = text(content.TagText)
        if component_id and tag_text then
            local list = contents_by_component[component_id] or {}
            list[#list + 1] = {
                tag_text = tag_text,
                indent = tonumber(text(content.Indent)) or 0,
                position = tonumber(text(content.Position)) or 0,
            }
            contents_by_component[component_id] = list
        end
    end
    for _, list in pairs(contents_by_component) do
        table.sort(list, function(lhs, rhs)
            return lhs.position < rhs.position
        end)
    end

    local function component_children(component_id, seen, base_indent)
        if seen[component_id] then
            return {}
        end
        seen[component_id] = true

        local children = {}
        for _, content in ipairs(contents_by_component[component_id] or {}) do
            local indent = base_indent + content.indent
            local tag = tonumber(content.tag_text)
            if tag then
                children[#children + 1] = { kind = "field", tag = tag, indent = indent }
            else
                local component = components_by_name[content.tag_text]
                if component then
                    local nested = component_children(component.id, seen, indent)
                    if component.component_type:find("Repeating", 1, true) then
                        local count = first_child_tag(nested)
                        if count and fields[count] then
                            table.remove(nested, 1)
                            children[#children + 1] = new_group(fields[count].name, count, nested)
                        end
                    else
                        vim.list_extend(children, nested)
                    end
                end
            end
        end

        seen[component_id] = nil
        return children
    end

    local groups = {}
    local messages = {}
    for _, message in ipairs(as_list(messages_xml.Messages.Message)) do
        local msg_type = text(message.MsgType)
        local component_id = tonumber(text(message.ComponentID))
        if msg_type and component_id then
            local children = component_children(component_id, {}, 0)
            groups[msg_type] = group_defs_by_count(grouped_by_indent(children, 1, -1, fields))
        end
        local name = text(message.Name)
        if msg_type and name then
            messages[msg_type] = {
                type = msg_type,
                name = name,
                category = text(message.CategoryID),
                description = text(message.Description),
            }
        end
    end

    return groups, messages
end

local function load_quickfix_group(group, by_name)
    local name = attr(group, "name")
    local count_tag = name and by_name[name] or nil
    if not count_tag then
        return nil
    end

    local children = {}
    for _, field in ipairs(as_list(group.field or group.Field)) do
        local field_name = attr(field, "name")
        local tag = field_name and by_name[field_name] or nil
        if tag then
            children[#children + 1] = { kind = "field", tag = tag }
        end
    end
    for _, nested in ipairs(as_list(group.group or group.Group)) do
        local nested_group = load_quickfix_group(nested, by_name)
        if nested_group then
            children[#children + 1] = nested_group
        end
    end

    return new_group(name, count_tag, children)
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

    local groups = {}
    local messages = {}
    local by_name = field_by_name(fields)
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
                -- QuickFIX DTD carries no message descriptions; name-only defs.
                messages[msgtype] = { type = msgtype, name = name }
            end
            if msgtype then
                local children = {}
                for _, group in ipairs(as_list(message.group or message.Group)) do
                    local group_def = load_quickfix_group(group, by_name)
                    if group_def then
                        children[#children + 1] = group_def
                    end
                end
                groups[msgtype] = group_defs_by_count(children)
            end
        end
    end

    return fields, enums, groups, messages
end

---@param source DictionarySource
local function load_source(source)
    if source.format == "quickfix" then
        return load_quickfix(source.path)
    end

    local fields = load_fields(source.path, "Fields.xml")
    local groups, messages = load_repository_groups(source.path, fields)
    return fields, load_enums(source.path, "Enums.xml"), groups, messages
end

function M.new(fields, enums, tags, groups, messages)
    local self = {
        _fields = fields or {},
        _enums = enums or {},
        _tags = tags or {},
        _groups = groups or {},
        _messages = messages or {},
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

    local fields, enums, groups, messages = load_source(source)
    local dict = M.new(fields, enums, source.tags, groups, messages)
    M._cache[source.key] = dict

    return dict
end

local function normalize_path(path)
    return vim.fn.fnamemodify(vim.fn.expand(path), ":p")
end

---@param mode any
---@return DictionaryMode
local function non_empty_string(v)
    return type(v) == "string" and v ~= ""
end

local function normalize_mode(mode)
    mode = mode or "auto"
    vim.validate("dictionary.mode", mode, function(v)
        return v == "auto" or v == "repository" or v == "quickfix"
    end, "'auto'|'repository'|'quickfix'")
    return mode
end

---@param tags any
---@return table<integer, FixTagDecoder>|nil
local function normalize_tags(tags)
    if tags == nil then
        return nil
    end
    vim.validate("dictionary.tags", tags, "table")

    local normalized = {}
    for tag, decoder in pairs(tags) do
        local name = ("dictionary.tags[%s]"):format(tostring(tag))
        local tag_number = tonumber(tag)
        vim.validate(name, tag_number, function(v)
            return v ~= nil and v > 0 and v % 1 == 0
        end, "positive integer tag")
        vim.validate(name, decoder, "function")
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

    vim.validate("dictionary entry", config, "table", "a path string or a table")
    if config.path == nil then
        assert(config.tags ~= nil, "dictionary entry must have a non-empty path")
    else
        vim.validate("dictionary.path", config.path, non_empty_string, "non-empty path string")
    end
    local version = explicit_version or config.version
    if version ~= nil then
        vim.validate("dictionary.version", version, non_empty_string, "non-empty string")
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
        messages_path = dir .. "Messages.xml",
        msg_contents_path = dir .. "MsgContents.xml",
        components_path = dir .. "Components.xml",
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
    vim.validate("dictionaries", dictionaries, "table")

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
            vim.validate("dictionaries key", version, non_empty_string, "non-empty version string")
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
            parts[#parts + 1] = fingerprint_part(source.messages_path)
            parts[#parts + 1] = fingerprint_part(source.msg_contents_path)
            parts[#parts + 1] = fingerprint_part(source.components_path)
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
---@param value string|nil
---@return EnumDef|nil
function M:enum(tag, value)
    if value == nil then
        return nil
    end
    return self._enums[tag .. ":" .. value]
end

---@param value string
function M:message(value)
    return self:enum(35, value)
end

--- Message metadata from Messages.xml; quickfix dictionaries carry name only.
---@param msg_type string
---@return MessageDef|nil
function M:message_def(msg_type)
    return self._messages[msg_type]
end

---@param msg_type string
---@return GroupDefsByTag|nil
function M:groups(msg_type)
    return self._groups[msg_type]
end

return M
