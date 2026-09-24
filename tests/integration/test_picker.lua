local Helpers = require("tests.integration.helpers")
local MiniTest = require("mini.test")

local T = Helpers.new_test_set({ real_picker = true })

T["picker"] = MiniTest.new_set()

T["picker"]["opens immediately on cold cache and streams to full count"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[
        require("fix").setup({ render = { lines_per_batch = 50 } })
        local f = io.open("tests/integration/fixtures/4.4.fix", "r")
        local line = f:read("*l")
        while line == "" do line = f:read("*l") end
        f:close()
        local lines = {}
        for i = 1, 300 do lines[i] = line end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.bo.filetype = "fix"
        _G._fields_per_line = #require("fix.document").build_line(0, 0):list_fields()
    ]])
    -- open the picker right away — most of the buffer is not cached yet
    nvim.cmd("FIX picker")
    -- defer_fn ticks cannot run during the blocking cmd RPC, so the picker
    -- holds exactly the first synchronous chunk here — proving it opened
    -- before the full item list was built.
    local partial_ok = nvim.lua_get([[(function()
        local p = require("snacks.picker").get()[1]
        if not (p and p.finder) then return false end
        local n = #p.finder.items
        return n > 0 and n < _G._fields_per_line * 300
    end)()]])
    MiniTest.expect.equality(partial_ok, true)
    local ok = Helpers.wait_for(
        nvim,
        [[(function()
            local pickers = require("snacks.picker").get()
            return pickers[1] ~= nil and pickers[1].finder ~= nil
                and #pickers[1].finder.items == (_G._fields_per_line * 300)
        end)()]],
        15000
    )
    MiniTest.expect.equality(ok, true)
end

T["picker"]["previews an unnamed buffer"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[
        require("fix").setup({})
        local f = io.open("tests/integration/fixtures/4.4.fix", "r")
        local line = f:read("*l")
        while line == "" do line = f:read("*l") end
        f:close()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
        vim.bo.filetype = "fix"
        _G._source_line = line
    ]])
    nvim.cmd("FIX picker")
    local ok = Helpers.wait_for(
        nvim,
        [[(function()
            local p = require("snacks.picker").get()[1]
            local win = p and p.preview and p.preview.win
            if not (win and win.buf and vim.api.nvim_buf_is_valid(win.buf)) then return false end
            return vim.api.nvim_buf_get_lines(win.buf, 0, 1, false)[1] == _G._source_line
        end)()]],
        5000
    )
    MiniTest.expect.equality(ok, true)
end

-- Buffer of `count` copies of the first 4.4 message, cursor on the start of the
-- 5th field of line `row`; picker opened right away.
local function open_on_field(nvim, count, row, lines_per_batch)
    nvim.lua(
        [[
        local count, row, lines_per_batch = ...
        require("fix").setup({ render = { lines_per_batch = lines_per_batch } })
        local f = io.open("tests/integration/fixtures/4.4.fix", "r")
        local line = f:read("*l")
        while line == "" do line = f:read("*l") end
        f:close()
        local lines = {}
        for i = 1, count do lines[i] = line end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.bo.filetype = "fix"
        local field = require("fix.document").build_line(0, row - 1):list_fields()[5]
        _G._target = { lineno = row - 1, index = field.index }
        -- one byte into the value, so the lookup must map a column inside the field
        vim.api.nvim_win_set_cursor(0, { row, field.value_start + 1 })
    ]],
        { count, row, lines_per_batch }
    )
    nvim.cmd("FIX picker")
end

local function wait_focused(nvim)
    return Helpers.wait_for(
        nvim,
        [[(function()
            local p = require("snacks.picker").get()[1]
            local item = p and p.list and p:current()
            return item ~= nil and item.lineno == _G._target.lineno
                and item.field.index == _G._target.index
        end)()]],
        15000
    )
end

T["picker"]["focuses the field under the cursor"] = function()
    local nvim = Helpers.nvim()
    open_on_field(nvim, 10, 7, 500)
    MiniTest.expect.equality(wait_focused(nvim), true)
end

T["picker"]["focuses the field under the cursor beyond the first chunk"] = function()
    local nvim = Helpers.nvim()
    open_on_field(nvim, 300, 200, 50)
    MiniTest.expect.equality(wait_focused(nvim), true)
end

return T
