--- Markdown for `textDocument/hover`: what the FIX dictionary knows about the
--- field under the cursor. Consumed only by `fix.validate.lsp`.

local Consts = require("fix.consts")
local Overrides = require("fix.overrides")

local M = {}

---@param field Field
---@param field_def FieldDef|nil
---@return string
local function header(field, field_def)
    local name = field.tag_text or (field_def and field_def.name)
    local title = name and string.format("**%s** (%d)", name, field.tag) or string.format("**Tag %d**", field.tag)
    if field_def and field_def.type then
        title = title .. " — " .. field_def.type
    end
    return title
end

---@param field Field
---@param enum_def EnumDef|nil
---@return string|nil
local function value_line(field, enum_def)
    if field.value == nil or field.value == "" then
        return nil
    end
    -- Backticks keep markdown metacharacters in raw values inert; a value
    -- containing a backtick itself would break the span — accepted edge.
    local line = string.format("Value: `%s`", field.value)
    local symbolic = field.value_text or (enum_def and enum_def.name)
    if symbolic then
        line = line .. string.format(" — **%s**", symbolic)
    end
    if enum_def and enum_def.description and enum_def.description ~= symbolic then
        line = line .. "\n\n" .. enum_def.description
    end
    return line
end

---@param buf number
---@param message Message
---@param field Field
---@return string|nil markdown nil when the dictionaries know nothing about the tag
function M.markdown(buf, message, field)
    if field.tag == nil then
        return nil
    end

    local dict = Overrides.dictionary_for(buf, message.version)
    local field_def = dict and dict:field(field.tag) or nil
    if not field_def and not field.tag_text then
        return nil
    end

    local about = { header(field, field_def) }
    if field_def and field_def.description then
        about[#about + 1] = field_def.description
    end

    local enum_def = dict and dict:enum(field.tag, field.value) or nil

    local value = { value_line(field, enum_def) }
    if field.tag == Consts.FixTag.MsgType and dict and field.value ~= nil then
        local msg_def = dict:message_def(field.value)
        if msg_def then
            value[#value + 1] = msg_def.description
            value[#value + 1] = msg_def.category and string.format("*Category: %s*", msg_def.category) or nil
        end
    end
    if field.group_instances and #field.group_instances > 0 and field.group_path_text then
        value[#value + 1] = string.format("Group: `%s`", field.group_path_text)
    end

    local url = require("fix").tag_url(message.version, field.tag)
    local link = { url and string.format("[FIX Reference: onixs.biz](%s)", url) or nil }

    local sections = {}
    for _, section in ipairs({ about, value, link }) do
        if #section > 0 then
            sections[#sections + 1] = table.concat(section, "\n\n")
        end
    end
    return table.concat(sections, "\n\n---\n\n")
end

return M
