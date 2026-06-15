local Cache = require("fix.cache")
local Consts = require("fix.consts")
local Dictionary = require("fix.dictionary")
local Field = require("fix.field")
local Message = require("fix.message")

local M = {}
local FixTag = Consts.FixTag

local versions = {
    ["FIX.2.7"] = Consts.FixVersion.FIX_2_7,
    ["FIX.3.0"] = Consts.FixVersion.FIX_3_0,
    ["FIX.4.0"] = Consts.FixVersion.FIX_4_0,
    ["FIX.4.1"] = Consts.FixVersion.FIX_4_1,
    ["FIX.4.2"] = Consts.FixVersion.FIX_4_2,
    ["FIX.4.3"] = Consts.FixVersion.FIX_4_3,
    ["FIX.4.4"] = Consts.FixVersion.FIX_4_4,
    ["FIXT.1.1"] = Consts.FixVersion.FIX_5_0,
}

---@return string
local function fallback_version()
    local ok, fix = pcall(require, "fix")
    return ok and fix.opts and fix.opts.fallback_version or Consts.FixVersion.FIX_4_4
end

---@param fields Field[]
---@return FixVersion?
local function get_version(fields)
    local begin_string
    for _, field in ipairs(fields) do
        if field.tag == FixTag.BeginString then
            begin_string = field.value
            break
        end
    end
    if not begin_string then
        vim.notify_once(string.format("Missing BeginString (tag %d)", FixTag.BeginString), vim.log.levels.WARN)
        return nil
    end

    local version = versions[begin_string]
    if not version then
        vim.notify_once(
            string.format("Unknown BeginString (tag %d): %s", FixTag.BeginString, begin_string),
            vim.log.levels.WARN
        )
        return nil
    end

    return version
end

---@param buf number
---@param field_node TSNode
---@param index number
---@return Field
local function node_to_semantic_field(buf, field_node, index)
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

    return Field.new({
        index = index,
        tag = tonumber(vim.treesitter.get_node_text(tag_node, buf)),
        value = vim.treesitter.get_node_text(value_node, buf),
        tag_start = tag_start_col,
        tag_end = tag_end_col,
        value_start = value_start_col,
        value_end = value_end_col,
    })
end

---@param semantic FixSemantic
local function decode(semantic)
    local dict = Dictionary.load(semantic.version)
    if not dict then
        return
    end
    local ctx = { version = semantic.version, fields = semantic.fields, dictionary = dict }
    for _, field in ipairs(semantic.fields) do
        dict:decode(field, ctx)
    end
end

---@param buf number
---@param message_node TSNode
---@return FixSemantic
local function semantic_from_node(buf, message_node)
    local fields = {}
    local index = 1
    for field_node in message_node:iter_children() do
        if field_node:type() == "field" then
            fields[#fields + 1] = node_to_semantic_field(buf, field_node, index)
            index = index + 1
        end
    end

    local version = get_version(fields)
    if not version then
        version = fallback_version()
        vim.notify_once("Cannot get FIX version, fallback to " .. version, vim.log.levels.WARN)
    end

    local semantic = { version = version, fields = fields }
    decode(semantic)
    return semantic
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
        -- group tags cannot be accessed for now
        ---@diagnostic disable-next-line: cast-local-type
        key = field.tag .. ":" .. index
    end
    vim.notify_once("Too many duplicate tags, something is wrong", vim.log.levels.WARN)
end

---@param semantic FixSemantic
---@param lineno number
---@return Message
function M.message_from_semantic(semantic, lineno)
    local fields = {}
    for _, sf in ipairs(semantic.fields) do
        insert_field(fields, Field.copy(sf))
    end
    return Message.new(semantic.version, lineno, fields)
end

---@param buf number
---@param lnum number 0-based
---@param line_text string
---@return TSNode|nil node, boolean covered  -- covered=false: the tree does not span lnum (stale/in-flight parse)
local function message_node_at(buf, lnum, line_text)
    local ok, parser = pcall(vim.treesitter.get_parser, buf, "fix")
    if not ok or not parser then
        error("No FIX parser for buffer " .. buf)
    end
    local root = parser:parse()[1]:root()
    local _, _, end_row, end_col = root:range()
    if lnum > end_row or (lnum == end_row and end_col == 0) then
        return nil, false
    end
    local first_nonblank = line_text:find("%S")
    local col = first_nonblank and first_nonblank - 1 or 0
    local node = root:descendant_for_range(lnum, col, lnum, col)
    while node and node:type() ~= "message" do
        node = node:parent()
    end
    return node, true
end

--- Build (or fetch from cache) the message on a line.
--- `line_text`/`key` may be passed by callers that already fetched them.
--- `authoritative=false` means the result must not be remembered: the tree
--- did not span the line (a render racing a buffer reload).
---@param buf number
---@param lnum number 0-based
---@param line_text string|nil
---@param key string|nil
---@return Message|nil message, string key, boolean authoritative
function M.build_line(buf, lnum, line_text, key)
    line_text = line_text or vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1]
    if line_text == nil then
        return nil, "", true
    end
    key = key or Cache.key(line_text)

    local semantic = Cache.get_semantic(key)
    if semantic == nil then
        local node, covered = message_node_at(buf, lnum, line_text)
        if node then
            semantic = semantic_from_node(buf, node)
            Cache.put_semantic(key, semantic)
        elseif covered then
            semantic = false
            Cache.put_semantic(key, semantic)
        else
            -- Caching a negative here would poison the content-keyed cache
            -- permanently. Treat as "no message" for this render only.
            return nil, key, false
        end
    end

    if not semantic then
        return nil, key, true
    end
    return M.message_from_semantic(semantic, lnum), key, true
end

-- Cold/whole-buffer path; per-line cache misses are amortized by the render scheduler.
---@param buf number
---@param on_message fun(message: Message)
function M.iter_messages(buf, on_message)
    for lnum = 0, vim.api.nvim_buf_line_count(buf) - 1 do
        local message = M.build_line(buf, lnum)
        if message then
            on_message(message)
        end
    end
end

--- Resolve the field at the cursor by column containment — no buffer-tree
--- access, so it stays correct on bigfile buffers (where the tree may be
--- unparsed at the cursor) and never throws on an unexpected node shape.
---@param buf number
---@return Message|nil, Field|nil
function M.get_field_under_cursor(buf)
    local pos = vim.api.nvim_win_get_cursor(0)
    local lnum, col = pos[1] - 1, pos[2]

    local message = M.build_line(buf, lnum)
    if message == nil then
        return nil, nil
    end

    for _, field in pairs(message:fields()) do
        if col >= field.tag_start and col < field.value_end then
            return message, field
        end
    end
    return nil, nil
end

return M
