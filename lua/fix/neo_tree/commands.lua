local common = require("neo-tree.sources.common.commands")

local M = {}

local function echo(message)
    vim.api.nvim_echo({ { "fix.nvim: " .. message, "Normal" } }, false, {})
end

local function jump_to_field(state, node)
    local bufnr = node.extra.bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local winid = state.fix_winid
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        winid = vim.fn.bufwinid(bufnr)
    end
    if winid == -1 then
        winid = require("neo-tree").get_prior_window()
    end
    if not winid or winid == -1 or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    if vim.api.nvim_win_get_buf(winid) ~= bufnr then
        vim.api.nvim_win_set_buf(winid, bufnr)
    end
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_win_set_cursor(winid, { node.extra.lineno + 1, node.extra.field.tag_start or 0 })
end

local function expand_or_load(state, node)
    if node.type == "message" and not node.loaded then
        require("fix.neo_tree").load_message(state, node)
        -- Lazy loading redraws the whole tree, so override any stale position
        -- Neo-tree restored while inserting this message's children.
        require("neo-tree.ui.renderer").focus_node(state, node.id)
    else
        common.toggle_node(state, nil, node)
    end
end

function M.open(state)
    local node = state.tree:get_node()
    if not node then
        return
    elseif node.type == "field" then
        jump_to_field(state, node)
    elseif node.type == "message" or node.type == "group" then
        expand_or_load(state, node)
    end
end

function M.toggle_node(state)
    local node = state.tree:get_node()
    if not node or node.type == "field" then
        return
    end
    expand_or_load(state, node)
end

-- Unlike neo-tree's own close_node/collapse_all_nodes, message roots collapse
-- like any other node: the FIX tree has one root per message, not a single one.
function M.close_node(state)
    local node = state.tree:get_node()
    if not node then
        return
    end

    local target = node
    if not (node:has_children() and node:is_expanded()) then
        target = state.tree:get_node(node:get_parent_id())
    end
    if not target or not target:has_children() then
        return
    end

    target:collapse()
    require("neo-tree.ui.renderer").redraw(state)
    require("neo-tree.ui.renderer").focus_node(state, target.id)
end

function M.close_all_nodes(state)
    local target = state.tree:get_node()
    while target and target:get_parent_id() do
        target = state.tree:get_node(target:get_parent_id())
    end

    local renderer = require("neo-tree.ui.renderer")
    renderer.reduce_nodes(state.tree, nil, function(node)
        if node:has_children() then
            node:collapse()
        end
    end)
    renderer.redraw(state)
    if target then
        renderer.focus_node(state, target.id)
    end
end

---@param state table
---@param register? string
function M.yank(state, register)
    local node = state.tree:get_node()
    if not node or (node.type ~= "message" and node.type ~= "field" and node.type ~= "group") then
        echo("nothing to yank")
        return
    end

    local parts = {}
    for _, chunk in ipairs(require("fix.neo_tree.components").format_node(node)) do
        parts[#parts + 1] = chunk.text
    end
    local text = table.concat(parts)
    vim.fn.setreg(register or vim.v.register, text, "v")
    echo("yanked tree label")
end

function M.browse_tag(state)
    local node = state.tree:get_node()
    local extra = node and node.extra or nil
    local field
    if node and node.type == "field" then
        field = extra.field
    elseif node and node.type == "group" then
        field = extra.group.field
    end

    if not field or not require("fix").open_tag_online(extra.version, field.tag) then
        echo("no tag documentation for this node")
    end
end

M.refresh = function()
    require("fix.neo_tree").refresh()
end

M.noop = function() end

common._add_common_commands(M, "^close_window$")
common._add_common_commands(M, "source$")
common._add_common_commands(M, "help")
common._add_common_commands(M, "^cancel$")

return M
