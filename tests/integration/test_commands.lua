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
    H.load_fixture(nvim(), "4.4.fix")
    H.expect_virt_lines_count(nvim(), 2)
    nvim().cmd("FIX annotations message")
    H.expect_virt_lines_count(nvim(), 0)
    nvim().cmd("FIX annotations message")
    H.expect_virt_lines_count(nvim(), 2)
end

T["FIX annotations all off then on restores per-scope flags"] = function()
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

T["FIX yank field uses unnamed register by default"] = function()
    -- yank.lua passes `regname or ""` to setreg, which targets the unnamed
    -- register. There is no clipboard provider in the headless container,
    -- so reading from "+" yields empty even when yank succeeded.
    H.load_fixture(nvim(), "4.4.fix")
    nvim().cmd("normal! 2G0")
    nvim().fn.setreg("", "")
    nvim().cmd("FIX yank field")
    local reg = nvim().fn.getreg("")
    MiniTest.expect.equality(reg:find("8", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg:find("FIX.4.4", 1, true) ~= nil, true)
    -- Annotated form includes the tag-name label in parens.
    MiniTest.expect.equality(reg:find("BeginString", 1, true) ~= nil, true)
end

T["FIX yank message yanks full annotated message"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().cmd("normal! 2G0")
    nvim().fn.setreg("", "")
    nvim().cmd("FIX yank message")
    local reg = nvim().fn.getreg("")
    -- Heartbeat (35=0) on line 2 of 4.4.fix has exactly 8 fields → 7
    -- inter-field separators. Asserting the exact count catches both
    -- truncation and accidental duplication; an annotated-label test
    -- below also locks the formatter output.
    local _, sep_count = reg:gsub("|", "|")
    MiniTest.expect.equality(sep_count, 7)
    -- Every header field's name must appear in the yanked text.
    for _, name in ipairs({
        "BeginString",
        "BodyLength",
        "MsgType",
        "MsgSeqNum",
        "SenderCompID",
        "TargetCompID",
        "SendingTime",
        "CheckSum",
    }) do
        MiniTest.expect.equality(reg:find(name, 1, true) ~= nil, true)
    end
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

T["FIX picker dispatches to fix.snacks.open"] = function()
    MiniTest.expect.equality(H.get_picker_opens(nvim()), 0)
    nvim().cmd("FIX picker")
    MiniTest.expect.equality(H.get_picker_opens(nvim()), 1)
end

T["FIX yank field --reg=a writes to register a"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    nvim().cmd("normal! 2G0")
    nvim().fn.setreg("a", "")
    nvim().fn.setreg("", "")
    nvim().cmd("FIX yank field --reg=a")
    local reg_a = nvim().fn.getreg("a")
    local reg_unnamed = nvim().fn.getreg("")
    MiniTest.expect.equality(reg_a:find("8", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg_a:find("BeginString", 1, true) ~= nil, true)
    -- Unnamed register must be untouched when an explicit --reg is given.
    MiniTest.expect.equality(reg_unnamed, "")
end

return T
