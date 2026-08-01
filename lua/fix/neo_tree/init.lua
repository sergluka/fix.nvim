local Cache = require("fix.cache")
local Document = require("fix.document")
local Items = require("fix.neo_tree.items")
local Scan = require("fix.scan")

local M = {
    name = "fix",
    display_name = " FIX ",
}

local targets = {}
local pending_targets = {}
local message_namespace = vim.api.nvim_create_namespace("fix-neo-tree-messages")

-- neo-tree is optional: keep its modules out of load time so `:FIX tree` can
-- report it missing instead of failing on require.
local renderer_module
local function renderer()
    renderer_module = renderer_module or require("neo-tree.ui.renderer")
    return renderer_module
end

M.default_config = {
    renderers = {
        message = {
            { "fix_expander" },
            { "fix_icon" },
            { "fix_text" },
        },
        group = {
            { "indent", with_expanders = true },
            { "fix_icon" },
            { "fix_text" },
        },
        field = {
            { "indent" },
            { "fix_icon" },
            { "fix_text" },
        },
        progress = {
            { "fix_icon" },
            { "name", highlight = "Comment" },
        },
        empty = {
            { "name", highlight = "Comment" },
        },
    },
    window = {
        mappings = {
            ["<cr>"] = "open",
            ["<space>"] = { "toggle_node", nowait = false },
            ["C"] = "close_node",
            ["z"] = "close_all_nodes",
            ["R"] = "refresh",
            ["y"] = "yank",
            ["gx"] = "browse_tag",
            ["q"] = "close_window",
            ["?"] = "show_help",
            ["<"] = "prev_source",
            [">"] = "next_source",
            ["<2-LeftMouse>"] = "open",
            -- neo-tree's filesystem-oriented defaults make no sense on a message tree.
            ["<C-s>"] = "noop",
            ["<Tab>"] = "noop",
            ["P"] = "noop",
            ["<C-f>"] = "noop",
            ["<C-b>"] = "noop",
            ["l"] = "noop",
            ["S"] = "noop",
            ["s"] = "noop",
            ["t"] = "noop",
            ["w"] = "noop",
            ["a"] = "noop",
            ["A"] = "noop",
            ["d"] = "noop",
            ["T"] = "noop",
            ["u"] = "noop",
            ["U"] = "noop",
            ["r"] = "noop",
            ["x"] = "noop",
            ["p"] = "noop",
            ["<C-r>"] = "noop",
            ["c"] = "noop",
            ["m"] = "noop",
            ["e"] = "noop",
            ["<C-;>"] = "noop",
        },
    },
}

local function current_fix_target()
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].filetype ~= "fix" then
        return nil
    end
    local winid = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(winid)
    return { bufnr = bufnr, winid = winid, cursor = cursor }
end

local function remember_target(bufnr, winid, cursor)
    if not cursor and winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
        cursor = vim.api.nvim_win_get_cursor(winid)
    end
    targets[vim.api.nvim_get_current_tabpage()] = { bufnr = bufnr, winid = winid, cursor = cursor }
end

local function remembered_target()
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].filetype ~= "neo-tree" then
        return nil
    end
    return targets[vim.api.nvim_get_current_tabpage()]
end

local function valid_target(target)
    return target and vim.api.nvim_buf_is_valid(target.bufnr) and vim.bo[target.bufnr].filetype == "fix"
end

local function render_empty(state, text)
    renderer().show_nodes({
        { id = "fix:empty", name = text, type = "empty" },
    }, state)
end

local function message_id(bufnr, lnum)
    return string.format("fix:%d:message:%d", bufnr, lnum)
end

local function scan_is_current(state, scan)
    return scan ~= nil and state._fix_scan == scan and vim.api.nvim_buf_is_valid(scan.bufnr) and state.tree ~= nil
end

local function sort_message_roots(state)
    local by_id = state.tree.nodes.by_id
    table.sort(state.tree.nodes.root_ids, function(left_id, right_id)
        local left = by_id[left_id]
        local right = by_id[right_id]
        local left_line = left and left.extra and left.extra.lineno
        local right_line = right and right.extra and right.extra.lineno
        if left_line and right_line then
            return left_line < right_line
        elseif left_line then
            return true
        elseif right_line then
            return false
        end
        return left_id < right_id
    end)
end

local function scan_progress_name(scan)
    local scanned = 0
    for _, range in ipairs(scan.scanned_ranges) do
        scanned = scanned + range[2] - range[1]
    end
    local percent = scan.line_count == 0 and 100 or math.floor(scanned * 100 / scan.line_count)
    return string.format("%s  %d%% · %d messages", scan.filename, percent, scan.count)
end

---@param state table
---@param scan table
---@param summaries table[]
local function add_summaries(state, scan, summaries)
    if not scan_is_current(state, scan) then
        return
    end

    local selected_id
    if renderer().window_exists(state) then
        local ok, selected = pcall(state.tree.get_node, state.tree)
        selected_id = ok and selected and selected.id or nil
    end
    local NuiTree = require("nui.tree")
    local added = 0
    for _, summary in ipairs(summaries) do
        local id = message_id(scan.bufnr, summary.lineno)
        if not state.tree:get_node(id) then
            state.tree:add_node(NuiTree.Node({
                id = id,
                name = string.format("Message %d", summary.lineno + 1),
                type = "message",
                loaded = false,
                extra = {
                    bufnr = scan.bufnr,
                    key = summary.key,
                    lineno = summary.lineno,
                    message = summary.message,
                    mark = vim.api.nvim_buf_set_extmark(scan.bufnr, message_namespace, summary.lineno, 0, {
                        right_gravity = false,
                    }),
                },
                level = 0,
            }))
            added = added + 1
        end
    end
    if added > 0 then
        scan.count = scan.count + added
        sort_message_roots(state)
    end
    local progress = state.tree:get_node("fix:progress")
    if progress then
        progress.name = scan_progress_name(scan)
    end
    if added > 0 or progress then
        renderer().redraw(state)
    end
    if selected_id and state.tree:get_node(selected_id) then
        renderer().focus_node(state, selected_id, true)
    end
end

---@param state table
---@param scan table
---@param first number 0-based inclusive
---@param last number 0-based exclusive
---@return boolean authoritative
local function scan_range(state, scan, first, last)
    if not scan_is_current(state, scan) then
        return false
    end
    first = math.max(first, 0)
    last = math.min(last, scan.line_count)
    if first >= last then
        return true
    end

    local lines = vim.api.nvim_buf_get_lines(scan.bufnr, first, last, false)
    if #lines ~= last - first then
        return false
    end
    local summaries = {}
    for offset, line in ipairs(lines) do
        local row = first + offset - 1
        local message, key, authoritative = Document.summary_line(scan.bufnr, row, line)
        if not authoritative then
            return false
        elseif message then
            summaries[#summaries + 1] = { message = message, key = key, lineno = row }
        end
    end
    scan.scanned_ranges = Scan.cover(scan.scanned_ranges, first, last)
    add_summaries(state, scan, summaries)
    return true
end

local function capture_tree_state(state, bufnr)
    if not state.tree or state.fix_bufnr ~= bufnr then
        return nil
    end

    local selected
    if renderer().window_exists(state) then
        local ok, node = pcall(state.tree.get_node, state.tree)
        selected = ok and node or nil
    end

    local messages = {}
    local has_messages = false
    for _, node in ipairs(state.tree:get_nodes()) do
        if node.type == "message" then
            has_messages = true
            local selected_here = selected
                and (selected.id == node.id or selected.id:sub(1, #node.id + 1) == node.id .. ":")
            if node.loaded or selected_here then
                local position = {}
                if node.extra.mark then
                    position = vim.api.nvim_buf_get_extmark_by_id(bufnr, message_namespace, node.extra.mark, {})
                end
                messages[#messages + 1] = {
                    old_id = node.id,
                    lnum = position[1] or node.extra.lineno,
                    loaded = node.loaded,
                }
            end
        end
    end
    if not has_messages then
        return nil
    end

    local expanded_by_id = {}
    renderer().reduce_nodes(state.tree, expanded_by_id, function(node, expanded)
        if node:has_children() then
            expanded[node.id] = node:is_expanded()
        end
    end)
    return {
        bufnr = bufnr,
        messages = messages,
        expanded_by_id = expanded_by_id,
        selected_id = selected and selected.id or nil,
    }
end

local function remap_node_id(id, message_ids)
    if not id then
        return nil
    end
    local old_id, rest = id:match("^(fix:%d+:message:%d+)(.*)$")
    local new_id = old_id and message_ids[old_id]
    return new_id and (new_id .. rest) or id
end

local function restore_tree_state(state, scan)
    local restore = scan.restore
    scan.restore = nil
    if not restore or not scan_is_current(state, scan) then
        return true
    end

    local message_ids = {}
    for _, message in ipairs(restore.messages) do
        for _, range in ipairs(Scan.pending(scan.scanned_ranges, message.lnum, message.lnum + 1)) do
            if not scan_range(state, scan, range[1], range[2]) then
                scan.restore = restore
                return false
            end
        end
        local node = state.tree:get_node(message_id(scan.bufnr, message.lnum))
        if node then
            message_ids[message.old_id] = node.id
            if message.loaded then
                M.load_message(state, node)
            end
        end
    end

    for id, expanded in pairs(restore.expanded_by_id) do
        local node = state.tree:get_node(remap_node_id(id, message_ids))
        if node then
            if expanded then
                node:expand()
            else
                node:collapse()
            end
        end
    end
    renderer().redraw(state)
    local selected_id = remap_node_id(restore.selected_id, message_ids)
    if selected_id and state.tree:get_node(selected_id) then
        renderer().focus_node(state, selected_id, true)
    end
    if state._fix_restore == restore then
        state._fix_restore = nil
    end
    return true
end

---@param state table
---@return boolean authoritative
function M.refresh_viewport(state)
    local scan = state._fix_scan
    if not scan_is_current(state, scan) then
        return false
    end

    local authoritative = true
    for _, viewport in ipairs(Scan.viewport_ranges(scan.bufnr)) do
        local first = math.max(viewport[1], 0)
        local last = math.min(viewport[2], scan.line_count)
        for _, range in ipairs(Scan.pending(scan.scanned_ranges, first, last)) do
            if not scan_range(state, scan, range[1], range[2]) then
                authoritative = false
                break
            end
        end
    end
    if authoritative and scan.restore then
        authoritative = restore_tree_state(state, scan)
    elseif authoritative and scan.initial_focus then
        local focus = scan.initial_focus
        scan.initial_focus = nil
        M.focus_field(state, scan.bufnr, focus.lnum, focus.col)
    end
    if not authoritative and not scan.viewport_retry_pending then
        scan.viewport_retry_pending = true
        vim.defer_fn(function()
            scan.viewport_retry_pending = false
            if scan_is_current(state, scan) then
                M.refresh_viewport(state)
            end
        end, 10)
    end
    return authoritative
end

--- Walk the rest of the buffer once the viewport is on screen, so messages
--- below the fold appear without the user having to scroll to them.
---@param state table
---@param scan table
---@return FixScanWalk
local function background_walk(state, scan)
    return Scan.walk({
        buf = scan.bufnr,
        alive = function()
            return scan_is_current(state, scan)
        end,
        line_count = function()
            return scan.line_count
        end,
        advance = function(cursor)
            return Scan.advance(scan.scanned_ranges, cursor)
        end,
        on_batch = function(first, last)
            for _, range in ipairs(Scan.pending(scan.scanned_ranges, first, last)) do
                if not scan_range(state, scan, range[1], range[2]) then
                    return false
                end
            end
            return true
        end,
        on_complete = function()
            scan.complete = true
            local progress = state.tree:get_node("fix:progress")
            if progress then
                state.tree:remove_node(progress.id)
            end
            if scan.count == 0 then
                render_empty(state, "No FIX messages")
            else
                renderer().redraw(state)
            end
        end,
    })
end

local function scan_summaries(state, bufnr, initial_focus, restore)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local filename = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
    state._fix_generation = (state._fix_generation or 0) + 1
    if state._fix_scan then
        state._fix_scan.walk:cancel()
    end
    local scan = {
        generation = state._fix_generation,
        bufnr = bufnr,
        line_count = vim.api.nvim_buf_line_count(bufnr),
        scanned_ranges = {},
        count = 0,
        complete = false,
        filename = filename,
        initial_focus = initial_focus,
        restore = restore,
    }
    scan.walk = background_walk(state, scan)
    state._fix_scan = scan
    vim.api.nvim_buf_clear_namespace(bufnr, message_namespace, 0, -1)

    renderer().show_nodes({
        {
            id = "fix:progress",
            name = string.format("%s  0%% · 0 messages", filename),
            type = "progress",
        },
    }, state)

    vim.schedule(function()
        if not scan_is_current(state, scan) then
            return
        end
        M.refresh_viewport(state)
        scan.walk:resume()
    end)
end

M.navigate = function(state)
    local tabid = vim.api.nvim_get_current_tabpage()
    local target = current_fix_target() or pending_targets[tabid] or remembered_target()
    pending_targets[tabid] = nil
    if not valid_target(target) then
        return
    end

    remember_target(target.bufnr, target.winid, target.cursor)
    state.fix_bufnr = target.bufnr
    state.fix_winid = target.winid
    local name = vim.api.nvim_buf_get_name(target.bufnr)
    state.path = name ~= "" and name or ("fix://" .. target.bufnr)
    local restore = state._fix_restore
    if not restore or restore.bufnr ~= target.bufnr then
        restore = capture_tree_state(state, target.bufnr)
        state._fix_restore = restore
    end
    local initial_focus
    if not restore then
        local position = target.cursor
        if
            target.winid
            and vim.api.nvim_win_is_valid(target.winid)
            and vim.api.nvim_win_get_buf(target.winid) == target.bufnr
        then
            position = vim.api.nvim_win_get_cursor(target.winid)
        end
        if position then
            initial_focus = { lnum = position[1] - 1, col = position[2] }
        end
    end
    scan_summaries(state, target.bufnr, initial_focus, restore)
end

function M.load_message(state, node)
    local extra = node.extra
    if not vim.api.nvim_buf_is_valid(extra.bufnr) then
        return
    end
    local line = vim.api.nvim_buf_get_lines(extra.bufnr, extra.lineno, extra.lineno + 1, false)[1]
    if not line or Cache.key(line) ~= extra.key then
        M.refresh()
        return
    end

    local message = Document.build_line(extra.bufnr, extra.lineno, line, extra.key)
    if not message then
        return
    end
    local children = Items.from_message(message, node.id, extra.bufnr)
    renderer().show_nodes(children, state, node.id)
end

---@param state table
---@param bufnr number
---@param lnum number 0-based
---@param col number 0-based byte column
---@return boolean
function M.focus_field(state, bufnr, lnum, col)
    if
        state.fix_bufnr ~= bufnr
        or not state.tree
        or not renderer().window_exists(state)
        or not vim.api.nvim_buf_is_valid(bufnr)
    then
        return false
    end

    local message, field = Document.get_field_at(bufnr, lnum, col)
    if not message or not field then
        return false
    end

    local id = message_id(bufnr, message.lineno)
    local message_node = state.tree:get_node(id)
    if not message_node then
        local line = vim.api.nvim_buf_get_lines(bufnr, message.lineno, message.lineno + 1, false)[1]
        local scan = state._fix_scan
        if not line or not scan_is_current(state, scan) then
            return false
        end
        local key = Cache.key(line)
        add_summaries(state, scan, { { message = message, key = key, lineno = message.lineno } })
        scan.scanned_ranges = Scan.cover(scan.scanned_ranges, message.lineno, message.lineno + 1)
        message_node = state.tree:get_node(id)
        if not message_node then
            return false
        end
    end
    if not message_node.loaded then
        M.load_message(state, message_node)
    end

    local target_id = id .. ":field:" .. tostring(field.index)
    if not state.tree:get_node(target_id) then
        for index = #(field.group_instances or {}), 1, -1 do
            local group_id = id .. ":group:" .. field.group_instances[index].key
            if state.tree:get_node(group_id) then
                target_id = group_id
                break
            end
        end
    end
    if not state.tree:get_node(target_id) then
        target_id = id
    end
    return renderer().focus_node(state, target_id, true)
end

M.setup = function()
    local manager = require("neo-tree.sources.manager")
    local events = require("neo-tree.events")
    local utils = require("neo-tree.utils")
    local function target_from(args)
        local bufnr = (args and args.buf) or vim.api.nvim_get_current_buf()
        if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "fix" then
            local winid = vim.api.nvim_get_current_win()
            remember_target(bufnr, winid)
            return bufnr
        end
    end

    manager.subscribe(M.name, {
        event = events.VIM_BUFFER_ENTER,
        handler = function(args)
            local bufnr = target_from(args)
            if not bufnr then
                return
            end
            local state = manager.get_state(M.name)
            if state.tree and state.fix_bufnr == bufnr then
                state.fix_winid = vim.api.nvim_get_current_win()
                M.refresh_viewport(state)
            else
                manager.refresh("fix")
            end
        end,
    })

    for _, event in ipairs({
        events.VIM_INSERT_LEAVE,
        events.VIM_TEXT_CHANGED_NORMAL,
    }) do
        manager.subscribe(M.name, {
            event = event,
            handler = function(args)
                if target_from(args) then
                    manager.refresh("fix")
                end
            end,
        })
    end

    manager.subscribe(M.name, {
        event = events.VIM_CURSOR_MOVED,
        handler = function(args)
            local bufnr = (args and args.buf) or vim.api.nvim_get_current_buf()
            if
                not vim.api.nvim_buf_is_valid(bufnr)
                or vim.bo[bufnr].filetype ~= "fix"
                or vim.api.nvim_get_current_buf() ~= bufnr
            then
                return
            end

            local position = vim.api.nvim_win_get_cursor(0)
            remember_target(bufnr, vim.api.nvim_get_current_win(), position)
            local state = manager.get_state(M.name)
            if not state.tree or not renderer().window_exists(state) then
                return
            end
            utils.debounce(string.format("fix_tree_follow_%d_%d", state.tabid, bufnr), function()
                M.refresh_viewport(state)
                M.focus_field(state, bufnr, position[1] - 1, position[2])
            end, 100, utils.debounce_strategy.CALL_LAST_ONLY)
        end,
    })

    local group = vim.api.nvim_create_augroup("fix-neo-tree-source", { clear = true })
    vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
        group = group,
        callback = function()
            local state = manager.get_state(M.name)
            if
                not state
                or not state.fix_bufnr
                or not vim.api.nvim_buf_is_valid(state.fix_bufnr)
                or not state.tree
                or not renderer().window_exists(state)
            then
                return
            end
            utils.debounce(string.format("fix_tree_viewport_%d_%d", state.tabid, state.fix_bufnr), function()
                M.refresh_viewport(state)
            end, 10, utils.debounce_strategy.CALL_LAST_ONLY)
        end,
    })
end

function M.open()
    local ok, neo_tree = pcall(require, "neo-tree")
    if not ok then
        vim.notify("fix.nvim: neo-tree.nvim is required for :FIX tree", vim.log.levels.ERROR)
        return
    end
    neo_tree.ensure_config()
    if not neo_tree.config.fix then
        vim.notify('fix.nvim: register "fix.neo_tree" in neo-tree sources before using :FIX tree', vim.log.levels.ERROR)
        return
    end

    local target = current_fix_target()
    if target then
        remember_target(target.bufnr, target.winid, target.cursor)
        pending_targets[vim.api.nvim_get_current_tabpage()] = target
    end
    require("neo-tree.command").execute({ source = "fix", action = "focus" })
end

function M.refresh()
    local neo_tree = package.loaded["neo-tree"]
    if type(neo_tree) ~= "table" or not neo_tree.config or not neo_tree.config.fix then
        return
    end
    require("neo-tree.sources.manager").refresh(M.name)
end

return M
