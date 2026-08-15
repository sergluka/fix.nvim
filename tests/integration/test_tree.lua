local Helpers = require("tests.integration.helpers")
local MiniTest = require("mini.test")

local T = Helpers.new_test_set({ real_tree = true })

local MESSAGE = "8=FIX.4.4|9=120|35=W|34=1276|49=EXCHANGE|56=CLIENT|52=20251026-09:02:00.000|"
    .. "55=BTCUSD|268=2|269=0|270=100.25|271=500|269=1|270=100.30|271=300|10=057|"

local function setup_tree(nvim, cursor_col, message)
    message = message or MESSAGE
    nvim.lua(string.format(
        [[
            require("fix").setup({
                annotate = { tag = { enabled = false }, value = { enabled = false }, title = { enabled = false } },
            })
            require("neo-tree").setup({
                sources = { "filesystem", "buffers", "git_status", "fix.neo_tree" },
            })
            vim.api.nvim_buf_set_lines(0, 0, -1, false, { %q })
            vim.bo.filetype = "fix"
            vim.api.nvim_win_set_cursor(0, { 1, %d })
        ]],
        message,
        cursor_col or #message - 1
    ))
    nvim.cmd("FIX tree")
    local ready = Helpers.wait_for(
        nvim,
        [[(function()
        local state = require("neo-tree.sources.manager").get_state("fix")
        return state.tree and #state.tree:get_nodes() == 1
            and state.tree:get_nodes()[1].type == "message"
    end)()]],
        5000
    )
    MiniTest.expect.equality(ready, true)
end

local function setup_large_tree(nvim, count, visible_line)
    nvim.lua(string.format(
        [[
            require("fix").setup({
                annotate = { tag = { enabled = false }, value = { enabled = false }, title = { enabled = false } },
                render = { lines_per_batch = 1, viewport_margin = 0 },
            })
            require("neo-tree").setup({
                sources = { "filesystem", "buffers", "git_status", "fix.neo_tree" },
            })
            local message = %q
            local lines = {}
            for index = 1, %d do
                lines[index] = message:gsub("34=1276", "34=" .. index, 1)
            end
            vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
            vim.bo.filetype = "fix"
            vim.api.nvim_win_set_cursor(0, { %d, #message - 1 })
            vim.cmd("normal! zz")
        ]],
        MESSAGE,
        count,
        visible_line
    ))
    nvim.cmd("FIX tree")
    local ready = Helpers.wait_for(
        nvim,
        string.format(
            [[(function()
                local state = require("neo-tree.sources.manager").get_state("fix")
                local scan = state._fix_scan
                return scan and not scan.complete and scan.walk.next < %d
                    and state.tree and state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:%d") ~= nil
            end)()]],
            visible_line - 1,
            visible_line - 1
        ),
        5000
    )
    MiniTest.expect.equality(ready, true)
end

T["formatters"] = MiniTest.new_set()

T["formatters"]["defaults use decoded-first highlighted chunks"] = function()
    local result = Helpers.nvim().lua_get(string.format(
        [[(function()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { %q })
        local message = require("fix.document").summary_line(0, 0)
        local summary = require("fix.formatters.tree.summary").default(message)
        local field = require("fix.formatters.tree.field").default({
            tag = 269, tag_text = "MDEntryType", value = "0", value_text = "Bid",
        })
        local count_field = { tag = 268, tag_text = "NoMDEntries", value = "2" }
        local tree_group = require("fix.tree_group").new({
            name = "NoMDEntries", index = 1, field = count_field,
        })
        local group = require("fix.formatters.tree.group").default(tree_group, count_field)
        return {
            summary[1], summary[2], summary[3], summary[4][1], summary[4][2]:match("^FixRoute") ~= nil,
            summary[5], summary[6][1], summary[6][2]:match("^FixRoute") ~= nil, summary[7],
            field, group, tree_group.field.tag,
        }
    end)()]],
        MESSAGE
    ))
    MiniTest.expect.equality(result, {
        { "1276 · ", "FixTreeMeta" },
        { "MarketDataSnapshotFullRefresh", "FixTreeName" },
        { "  ", "Normal" },
        "EXCHANGE",
        true,
        { " → ", "FixTreeOperator" },
        "CLIENT",
        true,
        { " · W", "FixTreeMeta" },
        {
            { "MDEntryType", "FixTreeName" },
            { " = ", "FixTreeOperator" },
            { "Bid", "FixTreeValue" },
            { " · 269=0", "FixTreeMeta" },
        },
        {
            { "NoMDEntries", "FixTreeGroup" },
            { "  #1/2", "FixTreeMeta" },
            { " · 268", "FixTreeMeta" },
        },
        268,
    })
end

T["formatters"]["components accept legacy tuples and chunk lists"] = function()
    local result = Helpers.nvim().lua_get([[(function()
        local opts = require("fix").opts.tree.field
        local components = require("fix.neo_tree.components")
        local node = { type = "field", name = "269", extra = { field = {} } }

        opts.formatter = function() return { "legacy", "Comment" } end
        local legacy = components.format_node(node)
        opts.formatter = function()
            return { { "decoded", "Identifier" }, { " · 269=0", "Comment" } }
        end
        local chunks = components.format_node(node)
        return { legacy, chunks }
    end)()]])
    MiniTest.expect.equality(result, {
        { { text = "legacy", highlight = "Comment" } },
        {
            { text = "decoded", highlight = "Identifier" },
            { text = " · 269=0", highlight = "Comment" },
        },
    })
end

T["formatters"]["tree highlight groups are linked by default"] = function()
    local links = Helpers.nvim().lua_get([[(function()
        local result = {}
        for _, name in ipairs({
            "FixTreeIcon", "FixTreeName", "FixTreeValue", "FixTreeMeta", "FixTreeOperator", "FixTreeGroup",
        }) do
            result[name] = vim.api.nvim_get_hl(0, { name = name, link = true }).link
        end
        return result
    end)()]])
    MiniTest.expect.equality(links, {
        FixTreeIcon = "Special",
        FixTreeName = "Identifier",
        FixTreeValue = "String",
        FixTreeMeta = "Comment",
        FixTreeOperator = "Operator",
        FixTreeGroup = "Type",
    })
end

T["source"] = MiniTest.new_set()

T["source"]["cold summaries do not populate the decoded message cache"] = function()
    local cached = Helpers.nvim().lua_get(string.format(
        [[(function()
            require("fix.cache").clear()
            vim.api.nvim_buf_set_lines(0, 0, -1, false, { %q })
            local message, key = require("fix.document").summary_line(0, 0)
            return {
                message:field(34).value,
                message:field(35).value_text,
                require("fix.cache").get_semantic(key),
            }
        end)()]],
        MESSAGE
    ))
    MiniTest.expect.equality(cached, { "1276", "MarketDataSnapshotFullRefresh" })
end

T["source"]["shows summaries first and loads fields on demand"] = function()
    local nvim = Helpers.nvim()
    setup_tree(nvim)

    local before = nvim.lua_get([[(function()
        local root = require("neo-tree.sources.manager").get_state("fix").tree:get_nodes()[1]
        return {
            root.loaded,
            root.extra.message:field(34).value,
            root.extra.message:field(35).value_text,
        }
    end)()]])
    MiniTest.expect.equality(before, { false, "1276", "MarketDataSnapshotFullRefresh" })

    nvim.lua([[
        local state = require("neo-tree.sources.manager").get_state("fix")
        require("fix.neo_tree").load_message(state, state.tree:get_nodes()[1])
    ]])
    local loaded = Helpers.wait_for(
        nvim,
        [[(function()
        local root = require("neo-tree.sources.manager").get_state("fix").tree:get_nodes()[1]
        return root.loaded and root:has_children()
    end)()]],
        5000
    )
    MiniTest.expect.equality(loaded, true)

    local shape = nvim.lua_get([[(function()
        local state = require("neo-tree.sources.manager").get_state("fix")
        local root = state.tree:get_nodes()[1]
        local out = {}
        local function visit(parent)
            for _, node in ipairs(state.tree:get_nodes(parent.id)) do
                out[#out + 1] = {
                    node.type,
                    node.name,
                    node:get_depth(),
                    node.type == "group" and node.extra.group.field.tag or nil,
                    node.type == "group" and not node:is_expanded() or nil,
                }
                visit(node)
            end
        end
        visit(root)
        return out
    end)()]])
    local group_count = 0
    local group_field_count = 0
    local entry_type_count = 0
    local collapsed_group_count = 0
    for _, node in ipairs(shape) do
        if node[1] == "group" and node[2] == "NoMDEntries" then
            group_count = group_count + 1
            if node[4] == 268 then
                group_field_count = group_field_count + 1
            end
            if node[5] == true then
                collapsed_group_count = collapsed_group_count + 1
            end
        elseif node[1] == "field" and node[2] == "269" then
            entry_type_count = entry_type_count + 1
        end
    end
    MiniTest.expect.equality(group_count, 2)
    MiniTest.expect.equality(group_field_count, 2)
    MiniTest.expect.equality(entry_type_count, 2)
    MiniTest.expect.equality(collapsed_group_count, 2)
end

T["source"]["opens the current message and selects the field under the cursor"] = function()
    local nvim = Helpers.nvim()
    setup_tree(nvim, MESSAGE:find("270=100.25", 1, true) - 1)

    local focused = Helpers.wait_for(
        nvim,
        [[(function()
            local state = require("neo-tree.sources.manager").get_state("fix")
            local root = state.tree and state.tree:get_nodes()[1]
            local node = state.tree and state.tree:get_node()
            return root and root.loaded and root:is_expanded()
                and node and node.type == "field" and node.name == "270"
                and node.extra.field.value == "100.25"
                and state.tree:get_node(node:get_parent_id()):is_expanded()
                and vim.api.nvim_get_current_win() == state.winid
        end)()]],
        5000
    )
    MiniTest.expect.equality(focused, true)
end

T["source"]["preserves expansion and selection when the FIX buffer is saved"] = function()
    local nvim = Helpers.nvim()
    setup_tree(nvim, MESSAGE:find("270=100.25", 1, true) - 1)

    nvim.lua([[
        local state = require("neo-tree.sources.manager").get_state("fix")
        local root = state.tree:get_nodes()[1]
        local groups = {}
        for _, node in ipairs(state.tree:get_nodes(root.id)) do
            if node.type == "group" then
                groups[#groups + 1] = node
            end
        end
        groups[2]:collapse()
        require("neo-tree.ui.renderer").redraw(state)
        _G._fix_tree_before_save = {
            generation = state._fix_generation,
            selected_id = state.tree:get_node().id,
            collapsed_id = groups[2].id,
        }

        vim.api.nvim_set_current_win(state.fix_winid)
        vim.api.nvim_buf_set_name(state.fix_bufnr, vim.fn.tempname() .. ".fix")
        local line = vim.api.nvim_buf_get_lines(state.fix_bufnr, 0, 1, false)[1]
        vim.api.nvim_buf_set_lines(state.fix_bufnr, 0, 1, false, { (line:gsub("34=1276", "34=1277", 1)) })
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = state.fix_bufnr })
        vim.cmd("write!")
    ]])

    local refreshed = Helpers.wait_for(
        nvim,
        [[(function()
            local state = require("neo-tree.sources.manager").get_state("fix")
            local before = _G._fix_tree_before_save
            local root = state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:0")
            return state._fix_generation > before.generation and not state._fix_scan.restore
                and state._fix_scan.complete and root and root.loaded
        end)()]],
        5000
    )
    MiniTest.expect.equality(refreshed, true)

    local preserved = nvim.lua_get([[(function()
        local state = require("neo-tree.sources.manager").get_state("fix")
        local before = _G._fix_tree_before_save
        local root = state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:0")
        local collapsed = state.tree:get_node(before.collapsed_id)
        local selected = state.tree:get_node()
        return {
            root.loaded,
            root:is_expanded(),
            collapsed ~= nil,
            collapsed and collapsed:is_expanded() or false,
            selected and selected.id == before.selected_id or false,
        }
    end)()]])
    MiniTest.expect.equality(preserved, { true, true, true, false, true })
end

T["source"]["refreshes loaded fields when setup changes dictionaries"] = function()
    local nvim = Helpers.nvim()
    setup_tree(nvim)

    local refreshed = nvim.lua_get([[(function()
        local manager = require("neo-tree.sources.manager")
        local state = manager.get_state("fix")
        local root = state.tree:get_nodes()[1]
        require("fix.neo_tree").load_message(state, root)
        local before = state._fix_generation
        require("fix").setup({
            dictionaries = {
                ["FIX.4.4"] = {
                    tags = {
                        [55] = function()
                            return { tag_text = "VenueSymbol" }
                        end,
                    },
                },
            },
        })
        return vim.wait(5000, function()
            state = manager.get_state("fix")
            root = state.tree and state.tree:get_nodes()[1]
            if not root or state._fix_generation <= before or not root.loaded then
                return false
            end
            for _, node in ipairs(state.tree:get_nodes(root.id)) do
                if node.type == "field" and node.name == "55" then
                    return node.extra.field.tag_text == "VenueSymbol"
                end
            end
            return false
        end, 25)
    end)()]])
    MiniTest.expect.equality(refreshed, true)
end

T["source"]["refreshes loaded fields when FIX dictionary registers a dictionary"] = function()
    local nvim = Helpers.nvim()
    local message = "8=FIX.4.4|9=0|35=A|34=1|49=EXAMPLE|52=20240627-11:17:25.223|56=SPOT|25035=2|10=000|"
    setup_tree(nvim, nil, message)

    local refreshed = nvim.lua_get([[(function()
        local manager = require("neo-tree.sources.manager")
        local state = manager.get_state("fix")
        local root = state.tree:get_nodes()[1]
        require("fix.neo_tree").load_message(state, root)
        local before = state._fix_generation
        require("fix").use_dictionary("xml/custom/binance/spot-fix-oe.xml")
        return vim.wait(5000, function()
            state = manager.get_state("fix")
            root = state.tree and state.tree:get_nodes()[1]
            if not root or state._fix_generation <= before or not root.loaded then
                return false
            end
            for _, node in ipairs(state.tree:get_nodes(root.id)) do
                if node.type == "field" and node.name == "25035" then
                    return node.extra.field.tag_text == "MessageHandling"
                end
            end
            return false
        end, 25)
    end)()]])
    MiniTest.expect.equality(refreshed, true)
end

T["source"]["restores loaded nodes and selection after lines shift"] = function()
    local nvim = Helpers.nvim()
    local visible_line = 90
    setup_large_tree(nvim, 120, visible_line)
    local complete =
        Helpers.wait_for(nvim, [[require("neo-tree.sources.manager").get_state("fix")._fix_scan.complete]], 5000)
    MiniTest.expect.equality(complete, true)

    nvim.lua(string.format(
        [[
            local state = require("neo-tree.sources.manager").get_state("fix")
            require("fix.neo_tree").focus_field(
                state,
                state.fix_bufnr,
                %d,
                %d
            )
            _G._fix_tree_before_shift = state._fix_generation
            vim.api.nvim_set_current_win(state.fix_winid)
            vim.api.nvim_buf_set_lines(state.fix_bufnr, 0, 0, false, { "not a FIX message" })
            vim.api.nvim_exec_autocmds("TextChanged", { buffer = state.fix_bufnr })
        ]],
        visible_line - 1,
        MESSAGE:find("270=100.25", 1, true) - 1
    ))

    local restored = Helpers.wait_for(
        nvim,
        string.format(
            [[(function()
                local state = require("neo-tree.sources.manager").get_state("fix")
                if state._fix_generation <= _G._fix_tree_before_shift then
                    return false
                end
                local root = state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:%d")
                local selected = state.tree:get_node()
                return root and root.loaded and root:is_expanded()
                    and root.extra.message:field(34).value == %q
                    and selected and selected.type == "field"
                    and selected.extra.lineno == %d
                    and selected.extra.field.tag == 270
            end)()]],
            visible_line,
            tostring(visible_line),
            visible_line
        ),
        5000
    )
    MiniTest.expect.equality(restored, true)
end

T["source"]["loads the viewport first and completes the summary tree in background"] = function()
    local nvim = Helpers.nvim()
    local count = 120
    local visible_line = 90
    setup_large_tree(nvim, count, visible_line)

    local initial = nvim.lua_get(string.format(
        [[(function()
            local state = require("neo-tree.sources.manager").get_state("fix")
            local node = state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:%d")
            local progress = state.tree:get_node("fix:progress")
            return {
                node ~= nil, node.loaded, node:has_children(), state._fix_scan.complete,
                progress ~= nil,
                progress and progress.name:find("[No Name]", 1, true) ~= nil or false,
                progress and progress.name:find("%%", 1, true) ~= nil or false,
                progress and progress.name:find("messages", 1, true) ~= nil or false,
            }
        end)()]],
        visible_line - 1
    ))
    MiniTest.expect.equality(initial, { true, false, false, false, true, true, true, true })

    local complete =
        Helpers.wait_for(nvim, [[require("neo-tree.sources.manager").get_state("fix")._fix_scan.complete]], 5000)
    MiniTest.expect.equality(complete, true)

    local final = nvim.lua_get([[(function()
        local state = require("neo-tree.sources.manager").get_state("fix")
        local roots = state.tree:get_nodes()
        local ordered = true
        local summaries_only = true
        for index, node in ipairs(roots) do
            ordered = ordered and node.extra.lineno == index - 1
            summaries_only = summaries_only and not node.loaded and not node:has_children()
        end
        return { #roots, ordered, summaries_only, state.tree:get_node("fix:progress") == nil }
    end)()]])
    MiniTest.expect.equality(final, { count, true, true, true })
end

T["source"]["keeps cursor context with neo-tree in the current window"] = function()
    local nvim = Helpers.nvim()
    local count = 120
    local visible_line = 90
    nvim.lua(string.format(
        [[
            require("fix").setup({
                annotate = { tag = { enabled = false }, value = { enabled = false }, title = { enabled = false } },
                render = { lines_per_batch = 1, viewport_margin = 0 },
            })
            require("neo-tree").setup({
                sources = { "filesystem", "buffers", "git_status", "fix.neo_tree" },
                window = { position = "current" },
            })
            local message = %q
            local lines = {}
            for index = 1, %d do
                lines[index] = message:gsub("34=1276", "34=" .. index, 1)
            end
            vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
            vim.bo.filetype = "fix"
            _G._fix_current_window_bufnr = vim.api.nvim_get_current_buf()
            vim.api.nvim_win_set_cursor(0, { %d, %d })
            vim.api.nvim_exec_autocmds("CursorMoved", { buffer = _G._fix_current_window_bufnr })
        ]],
        MESSAGE,
        count,
        visible_line,
        MESSAGE:find("270=100.25", 1, true) - 1
    ))
    nvim.cmd("Neotree fix")

    local focused = Helpers.wait_for(
        nvim,
        string.format(
            [[(function()
                local manager = require("neo-tree.sources.manager")
                local state = manager.get_state("fix", nil, vim.api.nvim_get_current_win())
                if not state or state.name ~= "fix" or state.fix_bufnr ~= _G._fix_current_window_bufnr then
                    return false
                end
                local root = state.tree and state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:%d")
                local selected = state.tree and state.tree:get_node()
                return root and root.loaded and root:is_expanded()
                    and selected and selected.type == "field"
                    and selected.extra.lineno == %d
                    and selected.extra.field.tag == 270
            end)()]],
            visible_line - 1,
            visible_line - 1
        ),
        5000
    )
    MiniTest.expect.equality(focused, true)
end

T["source"]["prioritizes a changed viewport without restarting background loading"] = function()
    local nvim = Helpers.nvim()
    local count = 300
    local visible_line = 150
    local promoted_line = 280
    setup_large_tree(nvim, count, visible_line)

    nvim.lua(string.format(
        [[
            local state = require("neo-tree.sources.manager").get_state("fix")
            local node = state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:%d")
            require("fix.neo_tree").load_message(state, node)
        ]],
        visible_line - 1
    ))
    local expanded = Helpers.wait_for(
        nvim,
        string.format(
            [[(function()
                local state = require("neo-tree.sources.manager").get_state("fix")
                local node = state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:%d")
                return node and node.loaded and node:has_children()
            end)()]],
            visible_line - 1
        ),
        5000
    )
    MiniTest.expect.equality(expanded, true)

    local promoted = nvim.lua_get(string.format(
        [[(function()
            local state = require("neo-tree.sources.manager").get_state("fix")
            local scan = state._fix_scan
            local generation = scan.generation
            local warm_next = scan.walk.next
            vim.api.nvim_set_current_win(state.fix_winid)
            vim.api.nvim_win_set_cursor(state.fix_winid, { %d, 0 })
            vim.cmd("normal! zz")
            require("fix.neo_tree").refresh_viewport(state)
            local node = state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:%d")
            return {
                node ~= nil,
                node and node.loaded or false,
                scan.generation == generation,
                scan.walk.next >= warm_next,
                scan.walk.next < %d,
            }
        end)()]],
        promoted_line,
        promoted_line - 1,
        promoted_line - 1
    ))
    MiniTest.expect.equality(promoted, { true, false, true, true, true })

    nvim.lua(string.format(
        [[
        local state = require("neo-tree.sources.manager").get_state("fix")
        require("fix.neo_tree").focus_field(state, state.fix_bufnr, %d, 0)
    ]],
        promoted_line - 1
    ))
    local selected = Helpers.wait_for(
        nvim,
        string.format(
            [[(function()
                local state = require("neo-tree.sources.manager").get_state("fix")
                local node = state.tree:get_node()
                return node and node.type == "field" and node.extra.lineno == %d
                    and vim.api.nvim_get_current_win() == state.fix_winid
            end)()]],
            promoted_line - 1
        ),
        5000
    )
    MiniTest.expect.equality(selected, true)

    local complete =
        Helpers.wait_for(nvim, [[require("neo-tree.sources.manager").get_state("fix")._fix_scan.complete]], 7000)
    MiniTest.expect.equality(complete, true)

    local preserved = nvim.lua_get(string.format(
        [[(function()
            local state = require("neo-tree.sources.manager").get_state("fix")
            local roots = state.tree:get_nodes()
            local node = state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:%d")
            local ordered = true
            for index, root in ipairs(roots) do
                ordered = ordered and root.extra.lineno == index - 1
            end
            return { #roots, ordered, node.loaded, node:has_children() }
        end)()]],
        visible_line - 1
    ))
    MiniTest.expect.equality(preserved, { count, true, true, true })
end

T["source"]["opening a field jumps to its raw tag"] = function()
    local nvim = Helpers.nvim()
    setup_tree(nvim)
    local jumped = nvim.lua_get([[(function()
        local state = require("neo-tree.sources.manager").get_state("fix")
        local root = state.tree:get_nodes()[1]
        require("fix.neo_tree").load_message(state, root)
        vim.wait(1000, function() return root.loaded end, 10)
        local target
        local function find(parent)
            for _, node in ipairs(state.tree:get_nodes(parent.id)) do
                if node.type == "field" and node.name == "270" then
                    target = node
                    return
                end
                find(node)
                if target then return end
            end
        end
        find(root)
        require("neo-tree.ui.renderer").focus_node(state, target.id)
        require("fix.neo_tree.commands").open(state)
        return {
            vim.api.nvim_get_current_buf() == target.extra.bufnr,
            vim.api.nvim_win_get_cursor(0)[2] == target.extra.field.tag_start,
        }
    end)()]])
    MiniTest.expect.equality(jumped, { true, true })
end

T["source"]["C collapses one branch and z collapses every loaded branch"] = function()
    local nvim = Helpers.nvim()
    setup_tree(nvim)
    local collapsed = nvim.lua_get([[(function()
        local state = require("neo-tree.sources.manager").get_state("fix")
        local renderer = require("neo-tree.ui.renderer")
        local commands = require("fix.neo_tree.commands")
        local root = state.tree:get_nodes()[1]
        require("fix.neo_tree").load_message(state, root)
        vim.wait(1000, function() return root.loaded end, 10)
        local groups = {}
        for _, node in ipairs(state.tree:get_nodes(root.id)) do
            if node.type == "group" then groups[#groups + 1] = node end
        end

        groups[1]:expand()
        renderer.focus_node(state, groups[1].id)
        commands.close_node(state)
        local one = {
            not groups[1]:is_expanded(),
            state.tree:get_node().id == groups[1].id,
        }

        root:expand()
        for _, group in ipairs(groups) do group:expand() end
        local child = state.tree:get_nodes(groups[2].id)[1]
        renderer.focus_node(state, child.id)
        commands.close_all_nodes(state)
        return {
            one[1], one[2],
            not root:is_expanded(),
            not groups[1]:is_expanded(),
            not groups[2]:is_expanded(),
            state.tree:get_node().id == root.id,
        }
    end)()]])
    MiniTest.expect.equality(collapsed, { true, true, true, true, true, true })
end

T["source"]["y yanks the displayed label and gx opens field and group docs"] = function()
    local nvim = Helpers.nvim()
    setup_tree(nvim)
    local result = nvim.lua_get([[(function()
        local state = require("neo-tree.sources.manager").get_state("fix")
        local renderer = require("neo-tree.ui.renderer")
        local commands = require("fix.neo_tree.commands")
        local root = state.tree:get_nodes()[1]
        require("fix.neo_tree").load_message(state, root)
        vim.wait(1000, function() return root.loaded end, 10)
        local group
        for _, node in ipairs(state.tree:get_nodes(root.id)) do
            if node.type == "group" then group = node break end
        end
        local field = state.tree:get_nodes(group.id)[1]

        renderer.focus_node(state, field.id)
        commands.yank(state, "a")
        commands.browse_tag(state)
        renderer.focus_node(state, group.id)
        commands.browse_tag(state)
        return { vim.fn.getreg("a"), vim.fn.getregtype("a"), _G._fix_test_ui_opens }
    end)()]])
    MiniTest.expect.equality(result, {
        "MDEntryType = Bid · 269=0",
        "v",
        {
            "https://www.onixs.biz/fix-dictionary/4.4/tagNum_269.html",
            "https://www.onixs.biz/fix-dictionary/4.4/tagNum_268.html",
        },
    })
end

T["source"]["cursor movement selects the matching field without stealing focus"] = function()
    local nvim = Helpers.nvim()
    setup_tree(nvim)
    nvim.lua(string.format(
        [[
            local state = require("neo-tree.sources.manager").get_state("fix")
            vim.api.nvim_set_current_win(state.fix_winid)
            vim.api.nvim_win_set_cursor(state.fix_winid, { 1, %d })
            vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.fix_bufnr })
        ]],
        MESSAGE:find("270=100.25", 1, true) - 1
    ))

    local selected = Helpers.wait_for(
        nvim,
        [[(function()
            local state = require("neo-tree.sources.manager").get_state("fix")
            local node = state.tree:get_node()
            return node and node.type == "field" and node.name == "270"
                and vim.api.nvim_get_current_win() == state.fix_winid
        end)()]],
        5000
    )
    MiniTest.expect.equality(selected, true)
end

T["source"]["opening another message keeps it selected during lazy loading"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[
        require("fix").setup({
            annotate = { tag = { enabled = false }, value = { enabled = false }, title = { enabled = false } },
        })
        require("neo-tree").setup({
            sources = { "filesystem", "buffers", "git_status", "fix.neo_tree" },
        })
        vim.cmd("edit samples/4.4.fix")
        vim.api.nvim_win_set_cursor(0, { 6, 0 })
    ]])
    nvim.cmd("FIX tree")

    local ready = Helpers.wait_for(
        nvim,
        [[(function()
            local state = require("neo-tree.sources.manager").get_state("fix")
            return state._fix_scan and state._fix_scan.complete
                and state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:5") ~= nil
                and state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:7") ~= nil
        end)()]],
        5000
    )
    MiniTest.expect.equality(ready, true)

    nvim.lua([[
        local state = require("neo-tree.sources.manager").get_state("fix")
        local renderer = require("neo-tree.ui.renderer")
        local order = state.tree:get_node("fix:" .. state.fix_bufnr .. ":message:5")

        require("fix.neo_tree").load_message(state, order)
        local msg_type = state.tree:get_node(order.id .. ":field:3")
        renderer.focus_node(state, msg_type.id)
    ]])
    nvim.type_keys("<CR>")
    nvim.type_keys("<C-w>", "p")
    nvim.lua([[
        local state = require("neo-tree.sources.manager").get_state("fix")
        local renderer = require("neo-tree.ui.renderer")
        renderer.focus_node(state, "fix:" .. state.fix_bufnr .. ":message:5")
    ]])
    nvim.type_keys("<CR>")
    nvim.lua([[
        local state = require("neo-tree.sources.manager").get_state("fix")
        local renderer = require("neo-tree.ui.renderer")
        local order_id = "fix:" .. state.fix_bufnr .. ":message:5"
        local logout_id = "fix:" .. state.fix_bufnr .. ":message:7"
        renderer.focus_node(state, logout_id)

        -- Neo-tree can retain the position saved before the message was
        -- collapsed and restore it while lazy-loaded children are rendered.
        local _, order_line = state.tree:get_node(order_id)
        state.position.topline = 1
        state.position.lnum = order_line
        require("fix.neo_tree.commands").open(state)
    ]])

    local selected = nvim.lua_get([[(function()
        local state = require("neo-tree.sources.manager").get_state("fix")
        local node = state.tree:get_node()
        return node and { node.type, node.extra.lineno }
    end)()]])
    MiniTest.expect.equality(selected, { "message", 7 })
end

T["source"]["does not reopen the remembered tree from a non-FIX buffer"] = function()
    local nvim = Helpers.nvim()
    setup_tree(nvim)
    nvim.cmd("Neotree close")
    nvim.cmd("enew")
    nvim.bo.filetype = "lua"
    nvim.cmd("Neotree fix")
    Helpers.sleep(nvim, 100)

    local opened = nvim.lua_get([[(function()
        local state = require("neo-tree.sources.manager").get_state("fix")
        return require("neo-tree.ui.renderer").window_exists(state)
    end)()]])
    MiniTest.expect.equality(opened, false)
end

T["source"]["uses the remembered FIX buffer when switching sources inside neo-tree"] = function()
    local nvim = Helpers.nvim()
    setup_tree(nvim)
    nvim.cmd("Neotree filesystem")
    nvim.cmd("Neotree fix")

    local restored = Helpers.wait_for(
        nvim,
        [[(function()
            local state = require("neo-tree.sources.manager").get_state("fix")
            local nodes = state.tree and state.tree:get_nodes() or {}
            return require("neo-tree.ui.renderer").window_exists(state)
                and #nodes == 1 and nodes[1].type == "message"
        end)()]],
        5000
    )
    MiniTest.expect.equality(restored, true)
end

T["configuration"] = MiniTest.new_set()

T["configuration"]["uses neo-tree conventions for tree actions"] = function()
    local mappings = Helpers.nvim().lua_get([[(function()
        local mappings = require("fix.neo_tree").default_config.window.mappings
        return {
            enter = mappings["<cr>"],
            space = mappings["<space>"][1],
            close = mappings.C,
            close_all = mappings.z,
            yank = mappings.y,
            browse = mappings.gx,
        }
    end)()]])
    MiniTest.expect.equality(mappings, {
        enter = "open",
        space = "toggle_node",
        close = "close_node",
        close_all = "close_all_nodes",
        yank = "yank",
        browse = "browse_tag",
    })
end

T["configuration"]["rejects invalid formatters"] = function()
    local errors = Helpers.nvim().lua_get([[(function()
        local cases = {
            { opts = { tree = { field = { formatter = "field" } } }, needle = "tree" },
            { opts = { formatters = { tag = { custom = "not-a-function" } } }, needle = "formatters.tag.custom" },
            {
                opts = { formatters = { value = { default = function() end } } },
                needle = "formatters.value.default is reserved",
            },
        }
        local result = {}
        for _, case in ipairs(cases) do
            local ok, err = pcall(require("fix").setup, case.opts)
            result[#result + 1] = not ok and err:find(case.needle, 1, true) ~= nil
        end
        return result
    end)()]])
    MiniTest.expect.equality(errors, { true, true, true })
end

return T
