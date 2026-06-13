local H = require("tests.integration.helpers")
local MiniTest = require("mini.test")

local T = H.new_test_set()
local nvim = H.nvim

T["missing tag 8 emits primary and fallback notifications"] = function()
    H.load_fixture(nvim(), "malformed-missing-tag8.fix", { expect_extmarks = false, timeout_ms = 200 })
    H.expect_notified(nvim(), "Missing BeginString %(tag 8%)")
    H.expect_notified(nvim(), "Cannot get FIX version, fallback to FIX%.4%.0")
end

T["unknown BeginString emits primary and fallback notifications"] = function()
    H.load_fixture(nvim(), "malformed-unknown-version.fix", { expect_extmarks = false, timeout_ms = 200 })
    H.expect_notified(nvim(), "Unknown BeginString %(tag 8%): FIX%.9%.9")
    H.expect_notified(nvim(), "Cannot get FIX version, fallback to FIX%.4%.0")
end

T["duplicate tags render both extmarks"] = function()
    H.load_fixture(nvim(), "malformed-duplicate-tags.fix")
    -- Two 55= fields → two Symbol tag labels.
    MiniTest.expect.equality(H.inline_label_count(nvim(), "Symbol"), 2)
end

T["empty buffer produces no extmarks and no errors"] = function()
    H.load_fixture(nvim(), "empty.fix", { expect_extmarks = false, timeout_ms = 100 })
    MiniTest.expect.equality(#H.get_extmarks(nvim()), 0)
    H.expect_no_error_notifications(nvim())
end

T["header-only message does not crash iter_messages"] = function()
    H.load_fixture(nvim(), "header-only.fix", { expect_extmarks = false, timeout_ms = 200 })
    -- May produce 0–2 extmarks (BeginString annotation only). Just no crash.
    MiniTest.expect.equality(#H.get_extmarks(nvim()) <= 4, true)
    H.expect_no_error_notifications(nvim())
end

T["long message places extmarks for known fields"] = function()
    H.load_fixture(nvim(), "long-message.fix")
    -- Long message has 7 known header fields + 100 unknown 5000xxx tags.
    -- BeginString is annotated; 5000xxx tags are not.
    H.expect_inline_label(nvim(), "BeginString")
    H.expect_inline_label(nvim(), "MsgType")
    H.expect_inline_label(nvim(), "SenderCompID")
end

T["unknown tag number is not annotated; known neighbours are"] = function()
    H.load_fixture(nvim(), "long-message.fix")
    H.expect_inline_label(nvim(), "BeginString")
    -- A "5000xxx" labelled annotation would indicate the unknown tag
    -- was decoded; production formatters return nil for unknown.
    H.expect_no_inline_label(nvim(), "5000001")
end

T["known tag with unknown enum value annotates tag only"] = function()
    nvim().cmd("enew")
    nvim().lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, {
			"",
			"8=FIX.4.4|9=20|35=ZZ|49=A|56=B|10=000|",
		})
	]])
    nvim().cmd("set filetype=fix")
    H.wait_annotated(nvim())
    -- MsgType tag is known → annotated; value "ZZ" is not a known enum →
    -- no value annotation.
    H.expect_inline_label(nvim(), "MsgType")
    H.expect_no_inline_label(nvim(), "ZZ")
end

return T
