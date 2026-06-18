local Helpers = require("tests.integration.helpers")
local MiniTest = require("mini.test")

local T = Helpers.new_test_set()

T["module"] = MiniTest.new_set()

T["module"]["key is a 32-char hash, stable per content"] = function()
    local nvim = Helpers.nvim()
    local keys = nvim.lua_get([[(function()
        local Cache = require("fix.cache")
        return { Cache.key("8=FIX.4.4|35=D"), Cache.key("8=FIX.4.4|35=D"), Cache.key("other") }
    end)()]])
    MiniTest.expect.equality(#keys[1], 32)
    MiniTest.expect.equality(keys[1], keys[2])
    MiniTest.expect.no_equality(keys[1], keys[3])
end

T["module"]["semantic layer stores tables and negative entries"] = function()
    local nvim = Helpers.nvim()
    local got = nvim.lua_get([[(function()
        local Cache = require("fix.cache")
        local k1, k2 = Cache.key("a"), Cache.key("b")
        Cache.put_semantic(k1, { version = "FIX.4.4", fields = {} })
        Cache.put_semantic(k2, false)
        return {
            hit = Cache.get_semantic(k1) ~= nil,
            negative = Cache.get_semantic(k2) == false,
            unknown = Cache.get_semantic(Cache.key("c")) == nil,
        }
    end)()]])
    MiniTest.expect.equality(got, { hit = true, negative = true, unknown = true })
end

T["module"]["drop_render keeps semantics, clear drops everything"] = function()
    local nvim = Helpers.nvim()
    local got = nvim.lua_get([[(function()
        local Cache = require("fix.cache")
        local k = Cache.key("a")
        Cache.put_semantic(k, { version = "FIX.4.4", fields = {} })
        Cache.put_render(k, { marks = {} })
        Cache.drop_render()
        local after_drop = { Cache.get_semantic(k) ~= nil, Cache.get_render(k) == nil }
        Cache.clear()
        local after_clear = { Cache.get_semantic(k) == nil }
        return { drop = after_drop, clear = after_clear }
    end)()]])
    MiniTest.expect.equality(got.drop, { true, true })
    MiniTest.expect.equality(got.clear, { true })
end

T["module"]["collect returns only positive entries for given keys"] = function()
    local nvim = Helpers.nvim()
    local got = nvim.lua_get([[(function()
        local Cache = require("fix.cache")
        local k1, k2, k3 = Cache.key("a"), Cache.key("b"), Cache.key("c")
        Cache.put_semantic(k1, { version = "FIX.4.4", fields = {} })
        Cache.put_semantic(k2, false)
        local out = Cache.collect({ [k1] = true, [k2] = true, [k3] = true })
        return vim.tbl_count(out)
    end)()]])
    MiniTest.expect.equality(got, 1)
end

T["module"]["merge stores only table entries, skips false and strings"] = function()
    local nvim = Helpers.nvim()
    local got = nvim.lua_get([[(function()
        local Cache = require("fix.cache")
        local k1, k2, k3 = Cache.key("a"), Cache.key("b"), Cache.key("c")
        Cache.merge({ [k1] = false, [k2] = "x", [k3] = { version = "FIX.4.4", fields = {} } })
        return {
            k1_nil = Cache.get_semantic(k1) == nil,
            k2_nil = Cache.get_semantic(k2) == nil,
            k3_hit = Cache.get_semantic(k3) ~= nil,
        }
    end)()]])
    MiniTest.expect.equality(got, { k1_nil = true, k2_nil = true, k3_hit = true })
end

-- Re-setup inside the child with a counting tag formatter. Read the count
-- via _G._tag_calls.
local COUNTING_SETUP = [[
    _G._tag_calls = 0
    local default = require("fix.formatters.tag").default
    require("fix").setup({
        annotate = { tag = { formatter = function(field)
            _G._tag_calls = _G._tag_calls + 1
            return default(field)
        end } },
    })
]]

T["behavior"] = MiniTest.new_set()

T["behavior"]["identical lines are computed once"] = function()
    local nvim = Helpers.nvim()
    nvim.lua(COUNTING_SETUP)
    Helpers.load_fixture(nvim, "duplicated-lines.fix")

    local calls_after_load = nvim.lua_get("_G._tag_calls")
    MiniTest.expect.equality(calls_after_load > 0, true)
    -- All 3 identical lines should be annotated.
    MiniTest.expect.equality(Helpers.inline_label_count(nvim, "BeginString"), 3)

    -- Toggle off then on: re-apply from render cache, no formatter calls.
    nvim.cmd("FIX annotations")
    Helpers.wait_annotated(nvim)
    nvim.cmd("FIX annotations")
    Helpers.wait_annotated(nvim)

    local calls_after_toggle = nvim.lua_get("_G._tag_calls")
    MiniTest.expect.equality(calls_after_toggle, calls_after_load)
end

T["behavior"]["dd shift does not recompute"] = function()
    local nvim = Helpers.nvim()
    nvim.lua(COUNTING_SETUP)
    Helpers.load_fixture(nvim, "duplicated-lines.fix")

    local calls_snapshot = nvim.lua_get("_G._tag_calls")
    MiniTest.expect.equality(calls_snapshot > 0, true)

    nvim.type_keys("gg", "dd")
    Helpers.wait_annotated(nvim)

    -- No new formatter invocations: remaining lines hit the render cache.
    MiniTest.expect.equality(nvim.lua_get("_G._tag_calls"), calls_snapshot)
    -- 2 lines remain, each annotated.
    MiniTest.expect.equality(Helpers.inline_label_count(nvim, "BeginString"), 2)
end

T["behavior"]["editing one line recomputes only that line"] = function()
    local nvim = Helpers.nvim()
    nvim.lua(COUNTING_SETUP)
    Helpers.load_fixture(nvim, "4.4.fix")

    local calls_snapshot = nvim.lua_get("_G._tag_calls")

    -- Count fields on the first message line (line 2 in 4.4.fix, 0-based lnum=1).
    -- build_line returns a Message; list_fields() enumerates its fields.
    local fields_of_line_1 = nvim.lua_get([[#require("fix.document").build_line(0, 1):list_fields()]])
    MiniTest.expect.equality(fields_of_line_1 > 0, true)

    -- Edit the first message line: append "X" then escape.
    nvim.type_keys("gg", "j", "$", "a", "X", "<Esc>")
    Helpers.wait_annotated(nvim)

    local delta = nvim.lua_get("_G._tag_calls") - calls_snapshot
    MiniTest.expect.equality(delta > 0, true)
    MiniTest.expect.equality(delta <= fields_of_line_1, true)
end

T["behavior"]["toggle off->on with unchanged content redraws (generation)"] = function()
    local nvim = Helpers.nvim()
    Helpers.load_fixture(nvim, "4.4.fix")

    local before = Helpers.inline_label_count(nvim, "BeginString")
    MiniTest.expect.equality(before > 0, true)

    nvim.cmd("FIX annotations")
    Helpers.wait_annotated(nvim)
    MiniTest.expect.equality(Helpers.inline_label_count(nvim, "BeginString"), 0)

    nvim.cmd("FIX annotations")
    Helpers.wait_annotated(nvim)
    MiniTest.expect.equality(Helpers.inline_label_count(nvim, "BeginString"), before)
end

T["behavior"]["position=below leaves no stale title after edit"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[require("fix").setup({ annotate = { title = { position = "below" } } })]])
    Helpers.load_fixture(nvim, "4.4.fix")

    local titles_before = Helpers.virt_lines_count(nvim)

    -- Edit line 1 (the first message line in 4.4.fix, line 2 = index 1).
    nvim.type_keys("gg", "j", "$", "a", "X", "<Esc>")
    Helpers.wait_annotated(nvim)

    MiniTest.expect.equality(Helpers.virt_lines_count(nvim), titles_before)
end

T["behavior"]["position=below renders title for a message on the last line"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[require("fix").setup({ annotate = { title = { position = "below" } } })]])

    -- Build a buffer whose sole message line is the LAST buffer line.
    local first_line = nvim.lua_get([=[vim.fn.readfile("tests/integration/fixtures/4.4.fix")[2]]=])
    MiniTest.expect.equality(type(first_line), "string")

    nvim.cmd("enew")
    nvim.lua(string.format([=[vim.api.nvim_buf_set_lines(0, 0, -1, false, { %q })]=], first_line))
    nvim.lua([[vim.bo.filetype = "fix"]])
    Helpers.wait_annotated(nvim)

    Helpers.expect_virt_lines_count(nvim, 1)
end

T["behavior"]["deleting the last line removes its annotations"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[require("fix").setup({ annotate = { title = { position = "above" } } })]])
    Helpers.load_fixture(nvim, "duplicated-lines.fix")
    Helpers.expect_virt_lines_count(nvim, 3)

    -- Marks of a deleted trailing line migrate to the phantom row at
    -- line_count, which per-line clears never reach.
    nvim.type_keys("G", "d", "d")
    Helpers.wait_annotated(nvim)

    Helpers.expect_virt_lines_count(nvim, 2)
end

T["behavior"]["shrinking reload leaves no stale titles"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[require("fix").setup({ annotate = { title = { position = "above" } } })]])

    -- Simulate `git revert` of a big file: open it, then replace it on disk
    -- with shorter content and reload.
    local message_line = nvim.lua_get([=[vim.fn.readfile("tests/integration/fixtures/4.4.fix")[2]]=])
    nvim.lua(string.format(
        [=[
        _G._reload_path = vim.fn.tempname() .. ".fix"
        local lines = {}
        for i = 1, 6 do lines[i] = %q end
        vim.fn.writefile(lines, _G._reload_path)
        vim.cmd("edit " .. _G._reload_path)
    ]=],
        message_line
    ))
    Helpers.wait_annotated(nvim)
    Helpers.expect_virt_lines_count(nvim, 6)

    nvim.lua(string.format(
        [=[
        vim.fn.writefile({ %q, %q }, _G._reload_path)
        vim.cmd("edit!")
    ]=],
        message_line,
        message_line
    ))
    Helpers.wait_annotated(nvim)

    Helpers.expect_virt_lines_count(nvim, 2)
end

T["behavior"]["growing reload does not poison the cache"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[require("fix").setup({ annotate = { title = { position = "above" } } })]])
    local message_line = nvim.lua_get([=[vim.fn.readfile("tests/integration/fixtures/4.4.fix")[2]]=])

    -- Small warmed file...
    nvim.lua(string.format(
        [=[
        vim.o.autoread = true
        _G._reload_path = vim.fn.tempname() .. ".fix"
        vim.fn.writefile({ %q, %q }, _G._reload_path)
        vim.cmd("edit " .. _G._reload_path)
    ]=],
        message_line,
        message_line
    ))
    Helpers.wait_annotated(nvim)
    Helpers.expect_virt_lines_count(nvim, 2)

    -- ...replaced on disk by a much bigger version (git revert restoring it).
    -- Rendering must not race tree-sitter's view of the reloaded buffer: a
    -- stale tree used to cache negative entries for rows past the old end of
    -- file, leaving them permanently bare. Jumping to the bottom must still
    -- annotate, proving those rows were not poisoned.
    nvim.lua(string.format(
        [=[
        local lines = {}
        for i = 1, 600 do lines[i] = %q .. "X" .. i end
        vim.fn.writefile(lines, _G._reload_path)
        vim.cmd("checktime")
    ]=],
        message_line
    ))
    Helpers.wait_annotated(nvim, 60000)

    nvim.type_keys("G")
    local ok = Helpers.wait_for(
        nvim,
        [[
        (function()
            local ns = vim.api.nvim_create_namespace("fix-protocol")
            local last = vim.api.nvim_buf_line_count(0) - 1
            return #vim.api.nvim_buf_get_extmarks(0, ns, { last, 0 }, { last, -1 }, {}) > 0
        end)()
    ]],
        10000
    )
    MiniTest.expect.equality(ok, true)
end

T["behavior"]["edit during warm-up causes no stale annotations or errors"] = function()
    local nvim = Helpers.nvim()
    -- 3000 unique lines to force warm-up chunking.
    local first_line = nvim.lua_get([=[vim.fn.readfile("tests/integration/fixtures/4.4.fix")[2]]=])
    nvim.cmd("enew")
    nvim.lua(string.format(
        [[
        local base = %q
        local lines = {}
        for i = 1, 3000 do
            lines[i] = base .. "X" .. i
        end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.bo.filetype = "fix"
    ]],
        first_line
    ))

    -- Immediately delete the first line while warm-up is in progress.
    nvim.type_keys("gg", "dd")
    Helpers.wait_annotated(nvim, 30000)

    Helpers.expect_no_error_notifications(nvim)
end

T["behavior"]["two windows, large file: both viewports annotated"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[
        require("fix").setup({
            render = { viewport_margin = 5 },
        })
    ]])

    local first_line = nvim.lua_get([=[vim.fn.readfile("tests/integration/fixtures/4.4.fix")[2]]=])
    nvim.cmd("enew")
    nvim.lua(string.format(
        [[
        local line = %q
        local lines = {}
        for i = 1, 500 do
            lines[i] = line
        end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.bo.filetype = "fix"
    ]],
        first_line
    ))
    Helpers.wait_annotated(nvim, 30000)

    -- Open a split and scroll to the bottom.
    nvim.cmd("vsplit")
    nvim.type_keys("G")

    -- Force viewport refresh after scroll.
    nvim.lua([[
        local buf = vim.api.nvim_get_current_buf()
        require("fix.render").refresh_viewport(buf)
    ]])
    Helpers.sleep(nvim, 200)

    -- Collect all extmark rows.
    local marks = Helpers.get_extmarks(nvim)
    MiniTest.expect.equality(#marks > 0, true)

    local has_top = false
    local has_bottom = false
    local has_middle = false
    for _, m in ipairs(marks) do
        if m.row < 40 then
            has_top = true
        end
        if m.row > 460 then
            has_bottom = true
        end
        if m.row > 200 and m.row < 300 then
            has_middle = true
        end
    end
    MiniTest.expect.equality(has_top, true)
    MiniTest.expect.equality(has_bottom, true)
    MiniTest.expect.equality(has_middle, false)
end

T["behavior"]["scroll after whole-file edit repairs annotations"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[
        require("fix").setup({
            render = { viewport_margin = 5 },
        })
    ]])

    local first_line = nvim.lua_get([=[vim.fn.readfile("tests/integration/fixtures/4.4.fix")[2]]=])
    nvim.cmd("enew")
    nvim.lua(string.format(
        [[
        local line = %q
        local lines = {}
        for i = 1, 300 do
            lines[i] = line
        end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.bo.filetype = "fix"
    ]],
        first_line
    ))
    Helpers.wait_annotated(nvim, 30000)

    -- Whole-file edit: append "X" to every line (all lines change uniformly).
    -- Relies on fixture lines NOT already ending in "X" — otherwise the
    -- substitution is a no-op and this test passes vacuously.
    nvim.cmd([[%s/X*$/X/]])
    Helpers.wait_annotated(nvim, 30000)

    -- Jump to bottom — triggers WinScrolled → refresh_viewport.
    nvim.type_keys("G")
    Helpers.sleep(nvim, 200)

    -- Wait for extmarks to appear on the last line.
    local ns_check = [[
        (function()
            local ns = vim.api.nvim_create_namespace("fix-protocol")
            local last = vim.api.nvim_buf_line_count(0) - 1
            local marks = vim.api.nvim_buf_get_extmarks(0, ns, {last, 0}, {last, -1}, {})
            return #marks > 0
        end)()
    ]]
    local ok = Helpers.wait_for(nvim, ns_check, 10000)
    MiniTest.expect.equality(ok, true)
end

T["behavior"]["bwipeout during warm-up is clean"] = function()
    local nvim = Helpers.nvim()
    local first_line = nvim.lua_get([=[vim.fn.readfile("tests/integration/fixtures/4.4.fix")[2]]=])
    nvim.cmd("enew")
    nvim.lua(string.format(
        [[
        local base = %q
        local lines = {}
        for i = 1, 3000 do
            lines[i] = base .. "X" .. i
        end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.bo.filetype = "fix"
    ]],
        first_line
    ))

    -- Wipe the buffer while warm-up is running.
    nvim.cmd("bwipeout!")
    Helpers.sleep(nvim, 300)

    Helpers.expect_no_error_notifications(nvim)
end

return T
