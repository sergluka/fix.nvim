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

T["position=above renders title as virt_lines above each message"] = function()
    nvim().lua([[require("fix").setup({ annotate = { message = { position = "above" } } })]])
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

T["position=front renders title as inline text at column zero"] = function()
    nvim().lua([[require("fix").setup({ annotate = { message = { position = "front" } } })]])
    H.load_fixture(nvim(), "4.4.fix")
    H.expect_virt_lines_count(nvim(), 0)

    local front_titles = 0
    for _, m in ipairs(H.get_extmarks(nvim())) do
        local vt = m.details.virt_text
        if m.col == 0 and m.details.virt_text_pos == "inline" and vt and vt[1] and vt[1][2] == "Title" then
            front_titles = front_titles + 1
        end
    end

    MiniTest.expect.equality(front_titles, 2)
    H.expect_inline_label(nvim(), "BeginString")
    H.expect_inline_label(nvim(), "MsgType")
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

T["custom tags overlay bundled dictionary and decode unknown tag"] = function()
    nvim().lua([[
        require("fix").setup({
            dictionaries = {
                ["FIX.4.4"] = {
                    tags = {
                        [5001] = function(field)
                            return {
                                tag_text = "VenueOrderState",
                                value_text = ({ A = "Accepted" })[field.value],
                            }
                        end,
                    },
                },
            },
        })
    ]])
    nvim().cmd("enew")
    nvim().lua([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            "8=FIX.4.4|9=20|35=D|49=A|56=B|5001=A|10=000|",
        })
    ]])
    nvim().cmd("set filetype=fix")
    H.wait_annotated(nvim())

    H.expect_inline_label(nvim(), "VenueOrderState")
    H.expect_inline_label(nvim(), "Accepted")
    H.expect_inline_label(nvim(), "BeginString")
end

T["custom tag decoder overrides XML tag and enum text"] = function()
    nvim().lua([[
        require("fix").setup({
            dictionaries = {
                ["FIX.4.4"] = {
                    tags = {
                        [35] = function()
                            return { tag_text = "VenueMsgType", value_text = "VenueOrder" }
                        end,
                    },
                },
            },
        })
    ]])
    nvim().cmd("enew")
    nvim().lua([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            "8=FIX.4.4|9=20|35=D|49=A|56=B|10=000|",
        })
    ]])
    nvim().cmd("set filetype=fix")
    H.wait_annotated(nvim())

    H.expect_inline_label(nvim(), "VenueMsgType")
    H.expect_inline_label(nvim(), "VenueOrder")
    H.expect_no_inline_label(nvim(), "MsgType")
    H.expect_no_inline_label(nvim(), "NewOrderSingle")
end

T["custom tag decoder partial result preserves XML value text"] = function()
    nvim().lua([[
        require("fix").setup({
            dictionaries = {
                ["FIX.4.4"] = {
                    tags = {
                        [35] = function()
                            return { tag_text = "OnlyTagOverride" }
                        end,
                    },
                },
            },
        })
    ]])
    nvim().cmd("enew")
    nvim().lua([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            "8=FIX.4.4|9=20|35=D|49=A|56=B|10=000|",
        })
    ]])
    nvim().cmd("set filetype=fix")
    H.wait_annotated(nvim())

    H.expect_inline_label(nvim(), "OnlyTagOverride")
    H.expect_inline_label(nvim(), "NewOrderSingle")
    H.expect_no_inline_label(nvim(), "MsgType")
end

T["custom tag decoder failure is reported without aborting render"] = function()
    nvim().lua([[
        require("fix").setup({
            dictionaries = {
                ["FIX.4.4"] = {
                    tags = {
                        [5002] = function()
                            error("decoder exploded")
                        end,
                    },
                },
            },
        })
    ]])
    nvim().cmd("enew")
    nvim().lua([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            "8=FIX.4.4|9=20|35=D|49=A|56=B|5002=X|10=000|",
        })
    ]])
    nvim().cmd("set filetype=fix")
    H.wait_annotated(nvim())

    H.expect_inline_label(nvim(), "BeginString")
    H.expect_notified(nvim(), "custom tag decoder failed")
end

T["custom tag setup change clears semantic cache"] = function()
    nvim().lua([[
        _G._custom_tag_label = "FirstCustomLabel"
        require("fix").setup({
            dictionaries = {
                ["FIX.4.4"] = {
                    tags = {
                        [5003] = function()
                            return { tag_text = _G._custom_tag_label }
                        end,
                    },
                },
            },
        })
    ]])
    nvim().cmd("enew")
    nvim().lua([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            "8=FIX.4.4|9=20|35=D|49=A|56=B|5003=X|10=000|",
        })
    ]])
    nvim().cmd("set filetype=fix")
    H.wait_annotated(nvim())
    H.expect_inline_label(nvim(), "FirstCustomLabel")

    nvim().lua([[
        _G._custom_tag_label = "SecondCustomLabel"
        require("fix").setup({
            dictionaries = {
                ["FIX.4.4"] = {
                    tags = {
                        [5003] = function()
                            return { tag_text = _G._custom_tag_label }
                        end,
                    },
                },
            },
        })
    ]])
    H.wait_annotated(nvim())

    H.expect_inline_label(nvim(), "SecondCustomLabel")
    H.expect_no_inline_label(nvim(), "FirstCustomLabel")
end

return T
