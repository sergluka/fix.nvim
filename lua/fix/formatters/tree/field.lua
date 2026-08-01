local M = {}

--- @param field Field
--- @return FixTreeFormatterChunk[]
function M.default(field)
    local key = field.tag_text or tostring(field.tag)
    local value = field.value_text or tostring(field.value)
    local chunks = {
        { key, "FixTreeName" },
        { " = ", "FixTreeOperator" },
        { value, "FixTreeValue" },
    }
    if field.tag_text or field.value_text then
        local raw = tostring(field.tag)
        if field.value_text then
            raw = raw .. "=" .. tostring(field.value)
        end
        chunks[#chunks + 1] = { " · " .. raw, "FixTreeMeta" }
    end
    return chunks
end

return M
