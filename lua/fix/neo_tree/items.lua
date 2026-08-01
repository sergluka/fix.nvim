local TreeGroup = require("fix.tree_group")

local M = {}

---@param message Message
---@param message_id string
---@param bufnr number
---@return table[]
function M.from_message(message, message_id, bufnr)
    local roots = {}
    local groups = {}
    local fields = message:list_fields()

    for _, field in ipairs(fields) do
        local children = roots
        local instances = field.group_instances or {}
        for _, instance in ipairs(instances) do
            local group = groups[instance.key]
            if not group then
                local count_field = fields[instance.count_index]
                group = {
                    id = message_id .. ":group:" .. instance.key,
                    name = instance.name,
                    type = "group",
                    extra = {
                        group = TreeGroup.new(vim.tbl_extend("force", vim.deepcopy(instance), {
                            field = count_field,
                        })),
                        version = message.version,
                    },
                    children = {},
                    _is_expanded = false,
                }
                groups[instance.key] = group
                children[#children + 1] = group
            end
            children = group.children
        end

        children[#children + 1] = {
            id = message_id .. ":field:" .. tostring(field.index),
            name = tostring(field.tag),
            type = "field",
            extra = {
                bufnr = bufnr,
                field = field,
                lineno = message.lineno,
                version = message.version,
            },
        }
    end

    return roots
end

return M
