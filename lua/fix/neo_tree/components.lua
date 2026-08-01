local common = require("neo-tree.sources.common.components")

local M = {}

---@param chunk any
---@return { text: string, highlight: string }|nil
local function normalize_chunk(chunk)
    if type(chunk) ~= "table" or type(chunk[1]) ~= "string" then
        return nil
    end
    return { text = chunk[1], highlight = chunk[2] or "Normal" }
end

---@param formatter function
---@param fallback string
---@param ... any
---@return { text: string, highlight: string }[]
local function format(formatter, fallback, ...)
    local ok, result = pcall(formatter, ...)
    if not ok then
        vim.notify_once("fix.nvim: tree formatter failed: " .. tostring(result), vim.log.levels.ERROR)
        return { { text = fallback, highlight = "Normal" } }
    end

    local legacy = normalize_chunk(result)
    if legacy then
        return { legacy }
    end

    local chunks = {}
    if type(result) == "table" then
        for _, chunk in ipairs(result) do
            local normalized = normalize_chunk(chunk)
            if not normalized then
                chunks = {}
                break
            end
            chunks[#chunks + 1] = normalized
        end
    end
    if #chunks == 0 then
        vim.notify_once(
            "fix.nvim: tree formatter must return { text, highlight } or a list of these chunks",
            vim.log.levels.ERROR
        )
        return { { text = fallback, highlight = "Normal" } }
    end
    return chunks
end

---@param node table
---@return { text: string, highlight: string }[]
function M.format_node(node)
    local opts = require("fix").opts.tree
    if node.type == "message" then
        return format(opts.summary.formatter, node.name, node.extra.message)
    elseif node.type == "field" then
        return format(opts.field.formatter, node.name, node.extra.field)
    elseif node.type == "group" then
        local group = node.extra.group
        return format(opts.group.formatter, node.name, group, group.field)
    end
    return { { text = node.name, highlight = "Comment" } }
end

function M.fix_text(_, node)
    return M.format_node(node)
end

local icons = {
    message = "󰍡 ",
    group = "󰙅 ",
    field = " ",
    progress = "󰔟 ",
}

function M.fix_icon(_, node)
    return { text = icons[node.type] or "", highlight = "FixTreeIcon" }
end

function M.fix_expander(_, node)
    if node.type ~= "message" then
        return { text = "", highlight = "NeoTreeExpander" }
    end
    if node.loaded and not node:has_children() then
        return { text = "  ", highlight = "NeoTreeExpander" }
    end
    return {
        text = node:is_expanded() and " " or " ",
        highlight = "NeoTreeExpander",
    }
end

return vim.tbl_deep_extend("force", common, M)
