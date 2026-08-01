local M = {}

--- @param group FixTreeGroup
--- @param field Field
--- @return FixTreeFormatterChunk[]
function M.default(group, field)
    return {
        { group.name, "FixTreeGroup" },
        { string.format("  #%d/%s", group.index, field.value or "?"), "FixTreeMeta" },
        { " · " .. tostring(field.tag), "FixTreeMeta" },
    }
end

return M
