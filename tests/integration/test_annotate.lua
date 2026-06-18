local H = require("tests.integration.helpers")
local MiniTest = require("mini.test")

local T = H.new_test_set()
local nvim = H.nvim

local function set_fix_lines(lines)
    nvim().cmd("enew")
    nvim().lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, " .. vim.inspect(lines) .. ")")
    nvim().cmd("set filetype=fix")
    H.wait_annotated(nvim())
end

local function first_title_chunks()
    local chunks = {}
    for _, mark in ipairs(H.get_extmarks(nvim())) do
        if mark.details.virt_lines then
            local line = mark.details.virt_lines[1]
            if line then
                chunks[#chunks + 1] = line
            end
        elseif mark.col == 0 and mark.details.virt_text_pos == "inline" then
            chunks[#chunks + 1] = mark.details.virt_text
        end
    end
    return chunks
end

local function first_title_highlights()
    local highlights = {}
    for _, chunks in ipairs(first_title_chunks()) do
        if chunks[1] then
            highlights[#highlights + 1] = chunks[1][2]
        end
    end
    return highlights
end

local function replace_mark_counts()
    local counts = { conceal = 0, overlay = 0 }
    for _, mark in ipairs(H.get_extmarks(nvim())) do
        if mark.details.conceal ~= nil then
            counts.conceal = counts.conceal + 1
        end
        if mark.details.virt_text_pos == "overlay" and mark.details.virt_text then
            counts.overlay = counts.overlay + 1
        end
    end
    return counts
end

local function row_has_conceal(row)
    for _, mark in ipairs(H.get_extmarks(nvim())) do
        if mark.row == row and mark.details.conceal ~= nil then
            return true
        end
    end
    return false
end

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
    nvim().lua([[require("fix").setup({ annotate = { title = { position = "above" } } })]])
    H.load_fixture(nvim(), "4.4.fix")
    -- 4.4.fix has 2 messages → 2 title extmarks.
    H.expect_virt_lines_count(nvim(), 2)
end

T["position=below anchors title on message line with virt_lines_above=false"] = function()
    nvim().lua([[require("fix").setup({ annotate = { title = { position = "below" } } })]])
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
    nvim().lua([[require("fix").setup({ annotate = { title = { position = "front" } } })]])
    H.load_fixture(nvim(), "4.4.fix")
    H.expect_virt_lines_count(nvim(), 0)

    local front_titles = 0
    for _, m in ipairs(H.get_extmarks(nvim())) do
        local vt = m.details.virt_text
        if
            m.col == 0
            and m.details.virt_text_pos == "inline"
            and vt
            and vt[1]
            and type(vt[1][2]) == "string"
            and vt[1][2]:match("^FixRoute")
        then
            front_titles = front_titles + 1
        end
    end

    MiniTest.expect.equality(front_titles, 2)
    H.expect_inline_label(nvim(), "BeginString")
    H.expect_inline_label(nvim(), "MsgType")
end

T["position=replace conceals message line and overlays title"] = function()
    nvim().lua([[require("fix").setup({ annotate = { title = { position = "replace" } } })]])
    H.load_fixture(nvim(), "4.4.fix")
    H.expect_virt_lines_count(nvim(), 0)
    H.expect_no_inline_label(nvim(), "BeginString")
    H.expect_no_inline_label(nvim(), "MsgType")

    local counts = replace_mark_counts()
    MiniTest.expect.equality(counts.conceal, 2)
    MiniTest.expect.equality(counts.overlay, 2)

    local first_line_len = nvim().lua_get([=[#vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]]=])
    local first_line_conceal
    local first_line_overlay
    for _, mark in ipairs(H.get_extmarks(nvim())) do
        if mark.row == 1 and mark.details.conceal ~= nil then
            first_line_conceal = mark
        elseif mark.row == 1 and mark.details.virt_text_pos == "overlay" then
            first_line_overlay = mark
        end
    end

    MiniTest.expect.equality(first_line_conceal.details.end_col, first_line_len)
    MiniTest.expect.equality(first_line_overlay.details.virt_text[1][1]:find("Heartbeat", 1, true) ~= nil, true)
end

T["position=replace_front draws active line title at front of raw line"] = function()
    nvim().lua([[
        require("fix").setup({
            annotate = { title = { position = "replace_front" } },
        })
    ]])
    H.load_fixture(nvim(), "4.4.fix")
    nvim().cmd("normal! 2G0")
    nvim().lua([[require("fix.render").refresh_cursor(0)]])

    local active_title
    for _, mark in ipairs(H.get_extmarks(nvim())) do
        if mark.row == 1 and mark.col == 0 and mark.details.virt_text_pos == "inline" then
            active_title = mark
            break
        end
    end

    MiniTest.expect.equality(row_has_conceal(1), false)
    MiniTest.expect.equality(row_has_conceal(2), true)
    MiniTest.expect.equality(active_title.details.virt_text[1][1]:find("Heartbeat", 1, true) ~= nil, true)
    MiniTest.expect.equality(H.inline_label_count(nvim(), "BeginString"), 1)

    nvim().cmd("normal! 3G0")
    nvim().lua([[require("fix.render").refresh_cursor(0)]])
    MiniTest.expect.equality(row_has_conceal(1), true)
    MiniTest.expect.equality(row_has_conceal(2), false)
    MiniTest.expect.equality(H.inline_label_count(nvim(), "BeginString"), 1)
end

T["legacy annotate.message config warns and maps to title"] = function()
    nvim().lua([[require("fix").setup({ annotate = { message = { position = "below" } } })]])
    H.load_fixture(nvim(), "4.4.fix")
    H.expect_notified(nvim(), "annotate%.message is deprecated")

    local has_below_anchor = false
    for _, mark in ipairs(H.get_extmarks(nvim())) do
        if mark.details.virt_lines and mark.details.virt_lines_above == false then
            has_below_anchor = true
        end
    end
    MiniTest.expect.equality(has_below_anchor, true)
end

T["annotate.title wins over legacy annotate.message"] = function()
    nvim().lua([[
        require("fix").setup({
            annotate = {
                message = { position = "below" },
                title = { position = "front" },
            },
        })
    ]])
    H.load_fixture(nvim(), "4.4.fix")
    H.expect_notified(nvim(), "annotate%.message is deprecated")
    H.expect_virt_lines_count(nvim(), 0)

    local front_titles = 0
    for _, mark in ipairs(H.get_extmarks(nvim())) do
        if mark.row >= 1 and mark.col == 0 and mark.details.virt_text_pos == "inline" then
            local vt = mark.details.virt_text
            if vt and vt[1] and type(vt[1][2]) == "string" and vt[1][2]:match("^FixRoute") then
                front_titles = front_titles + 1
            end
        end
    end
    MiniTest.expect.equality(front_titles, 2)
end

T["route title highlights distinguish opposite directions"] = function()
    set_fix_lines({
        "8=FIX.4.4|9=70|35=0|34=1|49=CLIENT1|56=BROKER1|52=20251026-09:02:00.000|10=198|",
        "8=FIX.4.4|9=70|35=0|34=2|49=BROKER1|56=CLIENT1|52=20251026-09:02:00.010|10=075|",
    })

    local highlights = first_title_highlights()
    MiniTest.expect.equality(#highlights, 2)
    MiniTest.expect.equality(highlights[1]:match("^FixRoute") ~= nil, true)
    MiniTest.expect.equality(highlights[2]:match("^FixRoute") ~= nil, true)
    MiniTest.expect.equality(highlights[1] ~= highlights[2], true)
end

T["route title highlight is stable for repeated routes"] = function()
    local line = "8=FIX.4.4|9=70|35=0|34=1|49=CLIENT1|56=BROKER1|52=20251026-09:02:00.000|10=198|"
    set_fix_lines({ line, line })

    local highlights = first_title_highlights()
    MiniTest.expect.equality(#highlights, 2)
    MiniTest.expect.equality(highlights[1], highlights[2])
end

T["route exact override wins over wildcard override"] = function()
    nvim().lua([[
        require("fix").setup({
            annotate = {
                title = {
                    route = {
                        overrides = {
                            { sender = "CLIENT1", target = "*", highlight = "FixWildcardRoute" },
                            { sender = "CLIENT1", target = "BROKER1", highlight = "FixExactRoute" },
                        },
                    },
                },
            },
        })
    ]])
    set_fix_lines({
        "8=FIX.4.4|9=70|35=0|34=1|49=CLIENT1|56=BROKER1|52=20251026-09:02:00.000|10=198|",
    })

    MiniTest.expect.equality(first_title_highlights()[1], "FixExactRoute")
end

T["route wildcard override matches structured sender and target"] = function()
    nvim().lua([[
        require("fix").setup({
            annotate = {
                title = {
                    route = {
                        overrides = {
                            { sender = "CLIENT1", target = "*", highlight = "FixClientSend" },
                        },
                    },
                },
            },
        })
    ]])
    set_fix_lines({
        "8=FIX.4.4|9=70|35=0|34=1|49=CLIENT1|56=BROKER2|52=20251026-09:02:00.000|10=198|",
    })

    MiniTest.expect.equality(first_title_highlights()[1], "FixClientSend")
end

T["route resolver can provide highlight when no override matches"] = function()
    nvim().lua([[
        require("fix").setup({
            annotate = {
                title = {
                    route = {
                        resolver = function(route)
                            if route.target == "CLIENT1" then
                                return "FixInboundClient"
                            end
                        end,
                    },
                },
            },
        })
    ]])
    set_fix_lines({
        "8=FIX.4.4|9=70|35=0|34=1|49=BROKER1|56=CLIENT1|52=20251026-09:02:00.000|10=198|",
    })

    MiniTest.expect.equality(first_title_highlights()[1], "FixInboundClient")
end

T["route default highlights switch to light background palette"] = function()
    local got = nvim().lua_get([[
        (function()
            require("fix").setup({})
            local dark = vim.api.nvim_get_hl(0, { name = "FixRoute1", link = false }).fg
            vim.o.background = "light"
            local light = vim.api.nvim_get_hl(0, { name = "FixRoute1", link = false })
            return { dark = dark, light = light.fg, bold = light.bold }
        end)()
    ]])

    MiniTest.expect.equality(got.dark ~= got.light, true)
    MiniTest.expect.equality(got.light, 0x005fcb)
    MiniTest.expect.equality(got.bold, true)
end

T["route default highlight registration preserves user groups"] = function()
    local got = nvim().lua_get([[
        (function()
            require("fix").setup({})
            vim.api.nvim_set_hl(0, "FixRoute1", { fg = "#123456" })
            vim.o.background = vim.o.background == "dark" and "light" or "dark"
            return vim.api.nvim_get_hl(0, { name = "FixRoute1", link = false }).fg
        end)()
    ]])

    MiniTest.expect.equality(got, 0x123456)
end

T["custom formatter can reuse route highlight without arrow text"] = function()
    nvim().lua([[
        require("fix").setup({
            annotate = {
                title = {
                    route = {
                        overrides = {
                            { sender = "CLIENT1", target = "BROKER1", highlight = "FixClientToBroker" },
                        },
                    },
                    formatter = function(message)
                        local route = message:route()
                        return { { { route.sender .. " to " .. route.target, message:route_highlight() } } }
                    end,
                },
            },
        })
    ]])
    set_fix_lines({
        "8=FIX.4.4|9=70|35=0|34=1|49=CLIENT1|56=BROKER1|52=20251026-09:02:00.000|10=198|",
    })

    local chunks = first_title_chunks()[1]
    MiniTest.expect.equality(chunks[1][1], "CLIENT1 to BROKER1")
    MiniTest.expect.equality(chunks[1][2], "FixClientToBroker")
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

T["SOH-delimited fixture renders with conceallevel=2"] = function()
    H.load_fixture(nvim(), "4.2-with_soh.fix")
    MiniTest.expect.equality(nvim().lua_get("vim.wo.conceallevel"), 2)
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
