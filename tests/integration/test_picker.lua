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

return T
