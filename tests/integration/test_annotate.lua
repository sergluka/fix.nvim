local H = require("tests.integration.helpers")
local MiniTest = require("mini.test")

local T = H.new_test_set()
local nvim = H.nvim

T["4.4.fix tag extmarks contain field names"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    H.expect_inline_label(nvim(), "BeginString")
    H.expect_inline_label(nvim(), "MsgType")
    H.expect_inline_label(nvim(), "SenderCompID")
end

T["4.4.fix value extmarks contain enum names"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    H.expect_inline_label(nvim(), "Heartbeat")
    H.expect_inline_label(nvim(), "NewOrderSingle")
end

T["4.4.fix message title is virt_lines above each message"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    -- 4.4.fix has 2 messages → 2 title extmarks.
    H.expect_virt_lines_count(nvim(), 2)
end

T["position=below anchors title on message line with virt_lines_above=false"] = function()
    nvim().lua([[require("fix").setup({ annotate = { message = { position = "below" } } })]])
    H.load_fixture(nvim(), "4.4.fix")
    H.expect_virt_lines_count(nvim(), 2)
    -- With position=below all title marks anchor on the message line itself
    -- (virt_lines_above=false), not on the following line.
    local marks = H.get_extmarks(nvim())
    local has_below_anchor = false
    for _, m in ipairs(marks) do
        if m.details.virt_lines and m.details.virt_lines_above == false then
            has_below_anchor = true
        end
    end
    MiniTest.expect.equality(has_below_anchor, true)
end

T["FIXT.1.1 BeginString resolves to FIX.5.0SP2 dictionary"] = function()
    H.load_fixture(nvim(), "5.0sp2.fix")
    -- ApplVerID (tag 1128) is only defined in FIX 5.0+; presence proves
    -- we loaded the FIX.5.0SP2 dictionary, not a fallback.
    H.expect_inline_label(nvim(), "ApplVerID")
end

T["multi-version session uses each message's own dictionary"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    H.load_fixture(nvim(), "5.0sp2.fix")
    H.expect_inline_label(nvim(), "ApplVerID")
end

T["SOH-delimited fixture renders with conceallevel=1"] = function()
    H.load_fixture(nvim(), "4.2-with_soh.fix")
    MiniTest.expect.equality(nvim().lua_get("vim.wo.conceallevel"), 1)
    H.expect_inline_label(nvim(), "BeginString")
end

return T
