local H = require("tests.integration.helpers")
local MiniTest = require("mini.test")

local T = H.new_test_set()
local nvim = H.nvim

T["FIX annotations tag toggle"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    local before = #H.get_extmarks(nvim())
    nvim().cmd("FIX annotations tag")
    MiniTest.expect.equality(#H.get_extmarks(nvim()) < before, true)
    nvim().cmd("FIX annotations tag")
    MiniTest.expect.equality(#H.get_extmarks(nvim()), before)
end

T["FIX annotations value toggle"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    local before = #H.get_extmarks(nvim())
    nvim().cmd("FIX annotations value")
    MiniTest.expect.equality(#H.get_extmarks(nvim()) < before, true)
    nvim().cmd("FIX annotations value")
    MiniTest.expect.equality(#H.get_extmarks(nvim()), before)
end

T["FIX annotations message toggle"] = function()
    nvim().lua([[require("fix").setup({ annotate = { message = { position = "above" } } })]])
    H.load_fixture(nvim(), "4.4.fix")
    H.expect_virt_lines_count(nvim(), 2)
    nvim().cmd("FIX annotations message")
    H.expect_virt_lines_count(nvim(), 0)
    nvim().cmd("FIX annotations message")
    H.expect_virt_lines_count(nvim(), 2)
end

T["FIX annotations all off then on restores per-scope flags"] = function()
    nvim().lua([[require("fix").setup({ annotate = { message = { position = "above" } } })]])
    H.load_fixture(nvim(), "4.4.fix")
    nvim().cmd("FIX annotations message")
    local pre_off_count = #H.get_extmarks(nvim())
    nvim().cmd("FIX annotations all")
    MiniTest.expect.equality(#H.get_extmarks(nvim()), 0)
    nvim().cmd("FIX annotations all")
    MiniTest.expect.equality(#H.get_extmarks(nvim()), pre_off_count)
    -- Message scope must remain off after restore.
    H.expect_virt_lines_count(nvim(), 0)
end

T["FIX annotations without scope toggles all"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    local before = H.get_extmarks(nvim())
    nvim().cmd("FIX annotations")
    MiniTest.expect.equality(#H.get_extmarks(nvim()), 0)
    nvim().cmd("FIX annotations")
    MiniTest.expect.equality(#H.get_extmarks(nvim()), #before)
end

T["FIX yank smart default yanks current field in normal mode"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().cmd("normal! 2G0")
    nvim().fn.setreg("", "")
    nvim().cmd("FIX yank")
    local reg = nvim().fn.getreg("")

    MiniTest.expect.equality(reg:find("8", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("FIX.4.4", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("BeginString", 1, true) ~= nil, true)
    MiniTest.expect.equality(nvim().fn.getregtype(""), "v")
end

T["FIX yank smart default yanks fields inside characterwise visual range"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().fn.setreg("", "")
    nvim().cmd([[execute "normal! 2G015lv8l\<Esc>"]])
    nvim().cmd([['<,'>FIX yank]])
    local reg = nvim().fn.getreg("")
    local _, sep_count = reg:gsub("|", "|")

    MiniTest.expect.equality(sep_count, 1)
    MiniTest.expect.equality(reg:find("MsgType", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("MsgSeqNum", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("BeginString", 1, true), nil)
    MiniTest.expect.equality(reg:find("SenderCompID", 1, true), nil)
    MiniTest.expect.equality(nvim().fn.getregtype(""), "v")
end

T["FIX yank smart default yanks characterwise visual mapping"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().lua([[vim.keymap.set("x", "<F5>", ":FIX yank<CR>", { buffer = true })]])
    nvim().fn.setreg("", "")
    nvim().cmd([[execute "normal 2G015lv8l\<F5>"]])
    local reg = nvim().fn.getreg("")
    local _, sep_count = reg:gsub("|", "|")

    MiniTest.expect.equality(sep_count, 1)
    MiniTest.expect.equality(reg:find("MsgType", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("MsgSeqNum", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("BeginString", 1, true), nil)
    MiniTest.expect.equality(reg:find("SenderCompID", 1, true), nil)
    MiniTest.expect.equality(nvim().fn.getregtype(""), "v")
end

T["FIX yank smart default visual mapping supports explicit register"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().lua([[vim.keymap.set("x", "<F5>", ":FIX yank --reg=a<CR>", { buffer = true })]])
    nvim().fn.setreg("a", "")
    nvim().fn.setreg("", "")
    nvim().cmd([[execute "normal 2G015lv8l\<F5>"]])
    local reg_a = nvim().fn.getreg("a")
    local unnamed = nvim().fn.getreg("")
    local _, sep_count = reg_a:gsub("|", "|")

    MiniTest.expect.equality(sep_count, 1)
    MiniTest.expect.equality(reg_a:find("MsgType", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg_a:find("MsgSeqNum", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg_a:find("BeginString", 1, true), nil)
    MiniTest.expect.equality(unnamed, "")
    MiniTest.expect.equality(nvim().fn.getregtype("a"), "v")
end

T["FIX yank smart default yanks characterwise visual lua mapping"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().lua([[vim.keymap.set("x", "<F5>", function() require("fix").yank() end, { buffer = true })]])
    nvim().fn.setreg("", "")
    nvim().cmd([[execute "normal 2G015lv8l\<F5>"]])
    local reg = nvim().fn.getreg("")
    local _, sep_count = reg:gsub("|", "|")

    MiniTest.expect.equality(sep_count, 1)
    MiniTest.expect.equality(reg:find("MsgType", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("MsgSeqNum", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("BeginString", 1, true), nil)
    MiniTest.expect.equality(reg:find("SenderCompID", 1, true), nil)
    MiniTest.expect.equality(nvim().fn.getregtype(""), "v")
end

T["FIX yank operator mapping yanks characterwise visual selection"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().lua([[
        local function smart_yank()
            vim.go.operatorfunc = "v:lua.require'fix'.operator_yank"
            return "g@"
        end
        vim.keymap.set({ "n", "x" }, "<F5>", smart_yank, { expr = true, buffer = true })
    ]])
    nvim().fn.setreg("", "")
    nvim().cmd([[execute "normal 2G015lv8l\<F5>"]])
    local reg = nvim().fn.getreg("")
    local _, sep_count = reg:gsub("|", "|")

    MiniTest.expect.equality(sep_count, 1)
    MiniTest.expect.equality(reg:find("MsgType", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("MsgSeqNum", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("BeginString", 1, true), nil)
    MiniTest.expect.equality(reg:find("SenderCompID", 1, true), nil)
    MiniTest.expect.equality(nvim().fn.getregtype(""), "v")
end

T["FIX yank operator mapping works with v mode mapping alias"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().lua([[
        local function smart_yank()
            vim.go.operatorfunc = "v:lua.require'fix'.operator_yank"
            return "g@"
        end
        vim.keymap.set({ "n", "v" }, "<F5>", smart_yank, { expr = true, buffer = true })
    ]])
    nvim().fn.setreg("", "")
    nvim().cmd([[execute "normal 2G015lv8l\<F5>"]])
    local reg = nvim().fn.getreg("")
    local _, sep_count = reg:gsub("|", "|")

    MiniTest.expect.equality(sep_count, 1)
    MiniTest.expect.equality(reg:find("MsgType", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("MsgSeqNum", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("BeginString", 1, true), nil)
    MiniTest.expect.equality(reg:find("SenderCompID", 1, true), nil)
    MiniTest.expect.equality(nvim().fn.getregtype(""), "v")
end

T["FIX yank operator mapping can default to a register for visual selection"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().lua([[
        vim.keymap.set({ "n", "x" }, "<F5>", function()
            return require("fix").operator_yank_register("a")
        end, { expr = true, buffer = true })
    ]])
    nvim().fn.setreg("a", "old")
    nvim().fn.setreg("", "old")
    nvim().cmd([[execute "normal 2G0vee\<F5>"]])
    local reg_a = nvim().fn.getreg("a")

    MiniTest.expect.equality(reg_a, "8(BeginString)=FIX.4.4")
    MiniTest.expect.equality(nvim().fn.getreg(""), "old")
    MiniTest.expect.equality(nvim().fn.getregtype("a"), "v")
end

T["FIX yank operator register helper defaults to unnamed register"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().lua([[
        vim.keymap.set({ "n", "x" }, "<F5>", function()
            return require("fix").operator_yank_register()
        end, { expr = true, buffer = true })
    ]])
    nvim().fn.setreg("a", "old")
    nvim().fn.setreg("", "old")
    nvim().cmd([[execute "normal 2G0vee\<F5>"]])

    MiniTest.expect.equality(nvim().fn.getreg(""), "8(BeginString)=FIX.4.4")
    MiniTest.expect.equality(nvim().fn.getreg("a"), "old")
    MiniTest.expect.equality(nvim().fn.getregtype(""), "v")
end

T["FIX yank smart default yanks messages for line range"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().fn.setreg("", "")
    nvim().cmd("2,3FIX yank")
    local reg = nvim().fn.getreg("")

    MiniTest.expect.equality(reg:find("Heartbeat", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("NewOrderSingle", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("ClOrdID", 1, true) ~= nil, true)
    MiniTest.expect.equality(nvim().fn.getregtype(""), "V")
end

T["FIX yank smart default yanks messages for linewise visual mapping"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().lua([[vim.keymap.set("x", "<F5>", ":FIX yank<CR>", { buffer = true })]])
    nvim().fn.setreg("", "")
    nvim().cmd([[execute "normal 2GVj\<F5>"]])
    local reg = nvim().fn.getreg("")

    MiniTest.expect.equality(reg:find("Heartbeat", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("NewOrderSingle", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("ClOrdID", 1, true) ~= nil, true)
    MiniTest.expect.equality(nvim().fn.getregtype(""), "V")
end

T["FIX operator yank yanks messages for line motion"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().fn.setreg("", "")
    nvim().lua([[vim.go.operatorfunc = "v:lua.require'fix'.operator_yank"]])
    nvim().cmd("normal! 2G0g@j")
    local reg = nvim().fn.getreg("")

    MiniTest.expect.equality(reg:find("Heartbeat", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("NewOrderSingle", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("ClOrdID", 1, true) ~= nil, true)
    MiniTest.expect.equality(nvim().fn.getregtype(""), "V")
end

T["FIX operator yank accepts operator-pending field motion"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().fn.setreg("", "")
    nvim().lua([[
        vim.go.operatorfunc = "v:lua.require'fix'.operator_yank"
        vim.keymap.set("o", "]}", function()
            local cursor = vim.api.nvim_win_get_cursor(0)
            local message = require("fix.document").build_line(0, cursor[1] - 1)
            local fields = message:list_fields()
            local matches = {}
            for _, field in ipairs(fields) do
                if field.value_end - 1 > cursor[2] then
                    matches[#matches + 1] = field
                end
            end
            local target = matches[math.min(vim.v.count1, #matches)]
            vim.api.nvim_win_set_cursor(0, { message.lineno + 1, target.value_end - 1 })
        end, { buffer = true })
    ]])
    nvim().cmd("normal 2G015lg@3]}")
    local reg = nvim().fn.getreg("")
    local _, sep_count = reg:gsub("|", "|")

    MiniTest.expect.equality(sep_count, 2)
    MiniTest.expect.equality(reg:find("MsgType", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("MsgSeqNum", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("SenderCompID", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("TargetCompID", 1, true), nil)
    MiniTest.expect.equality(nvim().fn.getregtype(""), "v")
end

T["FIX browse opens onixs URL with current tag"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().cmd("normal! 2G0")
    nvim().cmd("FIX browse")
    local opens = H.get_ui_opens(nvim())
    MiniTest.expect.equality(#opens, 1)
    MiniTest.expect.equality(opens[1], "https://www.onixs.biz/fix-dictionary/4.4/tagNum_8.html")
end

T["FIX --help does not error"] = function()
    -- mega.cmdparse prints help via stdout, not via :messages, so redir
    -- can't capture it. Asserting that the command runs without throwing
    -- and produces no ERROR-level notification is enough to catch
    -- regressions in command registration.
    nvim().cmd("FIX --help")
    for _, n in ipairs(H.get_notifications(nvim())) do
        MiniTest.expect.equality(n[2] ~= vim.log.levels.ERROR, true)
    end
end

T["FIX cache clear is registered"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().cmd("FIX cache clear")
    H.expect_no_error_notifications(nvim())
end

T["FIX dictionary uses Binance QuickFIX dictionary"] = function()
    nvim().cmd("enew")
    nvim().lua([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            "8=FIX.4.4|9=0|35=A|34=1|49=EXAMPLE|52=20240627-11:17:25.223|56=SPOT|25035=2|25036=1|25000=5000|10=000|",
        })
    ]])
    nvim().cmd("set filetype=fix")
    H.wait_annotated(nvim())
    H.expect_no_inline_label(nvim(), "MessageHandling")

    nvim().cmd("FIX dictionary xml/custom/binance/spot-fix-oe.xml")
    H.wait_annotated(nvim())

    H.expect_inline_label(nvim(), "MessageHandling")
    H.expect_inline_label(nvim(), "SEQUENTIAL")
    H.expect_inline_label(nvim(), "ResponseMode")
    H.expect_inline_label(nvim(), "EVERYTHING")
    H.expect_inline_label(nvim(), "RecvWindow")
end

T["FIX dictionary uses Coinbase QuickFIX dictionary"] = function()
    nvim().cmd("enew")
    nvim().lua([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            "8=FIX.4.2|9=0|35=D|34=1|49=A|52=20240627-11:17:25.223|56=B|7928=O|9406=Y|10=000|",
        })
    ]])
    nvim().cmd("set filetype=fix")
    H.wait_annotated(nvim())
    H.expect_no_inline_label(nvim(), "SelfTradePrevention")

    nvim().cmd("FIX dictionary xml/custom/coinbase/order-entry/FIX42-prod-sand.xml")
    H.wait_annotated(nvim())

    H.expect_inline_label(nvim(), "SelfTradePrevention")
    H.expect_inline_label(nvim(), "CANCEL_OLDEST")
    H.expect_inline_label(nvim(), "DropCopyFlag")
    H.expect_inline_label(nvim(), "YES")
end

T["FIX picker dispatches to fix.snacks.open"] = function()
    MiniTest.expect.equality(H.get_picker_opens(nvim()), 0)
    nvim().cmd("FIX picker")
    MiniTest.expect.equality(H.get_picker_opens(nvim()), 1)
end

T["FIX yank --reg=a writes to register a"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().cmd("normal! 2G0")
    nvim().fn.setreg("a", "")
    nvim().fn.setreg("", "")
    nvim().cmd("FIX yank --reg=a")
    local reg_a = nvim().fn.getreg("a")
    local reg_unnamed = nvim().fn.getreg("")
    MiniTest.expect.equality(reg_a:find("8", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg_a:find("BeginString", 1, true) ~= nil, true)
    -- Unnamed register must be untouched when an explicit --reg is given.
    MiniTest.expect.equality(reg_unnamed, "")
end

return T
