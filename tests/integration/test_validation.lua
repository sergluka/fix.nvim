local H = require("tests.integration.helpers")
local MiniTest = require("mini.test")

local T = H.new_test_set()
local nvim = H.nvim

local HEARTBEAT = "8=FIX.4.4|9=57|35=0|34=1|49=CLIENT1|56=BROKER1|52=20251026-09:02:00.000|10=171|"
local LOGON = "8=FIX.4.4|9=69|35=A|34=1|49=CLIENT1|56=BROKER1|52=20251026-09:00:00.000|98=0|108=30|10=214|"

local function load(name)
    H.load_fixture(nvim(), "validation/" .. name)
    H.wait_validated(nvim())
end

local function lines()
    return nvim().lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)")
end

local function line(lnum)
    return lines()[lnum + 1]
end

local function setup(opts)
    nvim().lua("require('fix').setup(" .. opts .. ")")
end

T["clean messages produce no diagnostics"] = function()
    load("valid.fix")
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
end

T["the validation server attaches with byte offsets"] = function()
    load("valid.fix")
    local client = nvim().lua_get([[(function()
		local c = vim.lsp.get_clients({ bufnr = 0, name = "fix-validate" })[1]
		return c and { name = c.name, encoding = c.offset_encoding } or nil
	end)()]])
    MiniTest.expect.equality(client, { name = "fix-validate", encoding = "utf-8" })
end

T["a wrong BodyLength is reported against the value"] = function()
    load("bad-bodylength.fix")
    local diagnostics = H.get_diagnostics(nvim())
    MiniTest.expect.equality(#diagnostics, 1)
    MiniTest.expect.equality(diagnostics[1].code, "body_length")
    MiniTest.expect.equality(diagnostics[1].message, "BodyLength is 61, expected 57")
    MiniTest.expect.equality({ diagnostics[1].lnum, diagnostics[1].col, diagnostics[1].end_col }, { 0, 12, 14 })
end

T["a wrong CheckSum is reported against the value"] = function()
    load("bad-checksum.fix")
    local diagnostics = H.get_diagnostics(nvim())
    MiniTest.expect.equality(#diagnostics, 1)
    MiniTest.expect.equality(diagnostics[1].code, "checksum")
    MiniTest.expect.equality(diagnostics[1].message, "CheckSum is 178, expected 171")
end

T["a message wrong in both places gets both diagnostics"] = function()
    load("bad-both.fix")
    local diagnostics = H.get_diagnostics(nvim())
    MiniTest.expect.equality(#diagnostics, 2)
    MiniTest.expect.equality({ diagnostics[1].code, diagnostics[2].code }, { "body_length", "checksum" })
end

T["SOH-delimited logs validate like pipe-delimited ones"] = function()
    load("soh.fix")
    local diagnostics = H.get_diagnostics(nvim())
    MiniTest.expect.equality(#diagnostics, 1)
    MiniTest.expect.equality(diagnostics[1].lnum, 1)
    MiniTest.expect.equality(diagnostics[1].code, "checksum")
end

T["a line that is not a FIX message is reported as such, and only that"] = function()
    load("fragment.fix")
    local diagnostics = H.get_diagnostics(nvim())

    -- Line 1 is a repeating-group fragment, line 3 a message without tag 8;
    -- neither gets BodyLength or CheckSum complaints on top.
    MiniTest.expect.equality(#diagnostics, 2)
    MiniTest.expect.equality({ diagnostics[1].lnum, diagnostics[2].lnum }, { 0, 2 })
    for _, diagnostic in ipairs(diagnostics) do
        MiniTest.expect.equality(diagnostic.code, "begin_string")
        MiniTest.expect.equality(diagnostic.message, "Not a FIX message: missing BeginString (tag 8)")
        MiniTest.expect.equality(diagnostic.severity, vim.diagnostic.severity.WARN)
    end
end

T["a fragment offers no fixes"] = function()
    load("fragment.fix")
    MiniTest.expect.equality(#H.code_actions(nvim(), 0), 0)
end

T["a lower tier still runs when the tier above stays quiet"] = function()
    setup([[{
		lsp = {
			validate = {
				rules = {
					always_quiet = { tier = 0, check = function() return nil end },
				},
			},
		},
	}]])
    load("bad-checksum.fix")

    local diagnostics = H.get_diagnostics(nvim())
    MiniTest.expect.equality(#diagnostics, 1)
    MiniTest.expect.equality(diagnostics[1].code, "checksum")
end

T["disabling the structural rule lets the lower tier speak again"] = function()
    setup([[{ lsp = { validate = { rules = { begin_string = false } } } }]])
    load("fragment.fix")

    local codes = {}
    for _, diagnostic in ipairs(H.get_diagnostics(nvim())) do
        codes[diagnostic.code] = true
    end
    MiniTest.expect.equality(codes.begin_string, nil)
    MiniTest.expect.equality(codes.body_length, true)
end

T["a missing BodyLength is reported"] = function()
    load("missing-bodylength.fix")
    local diagnostics = H.get_diagnostics(nvim())
    MiniTest.expect.equality(#diagnostics, 1)
    MiniTest.expect.equality(diagnostics[1].message, "Missing BodyLength (tag 9)")
end

T["a missing CheckSum is reported"] = function()
    load("missing-checksum.fix")
    local diagnostics = H.get_diagnostics(nvim())
    MiniTest.expect.equality(#diagnostics, 1)
    MiniTest.expect.equality(diagnostics[1].message, "Missing CheckSum (tag 10)")
end

T["a quickfix action repairs the BodyLength"] = function()
    load("bad-bodylength.fix")
    H.apply_code_action(nvim(), "Fix BodyLength", 0)
    H.wait_validated(nvim())
    MiniTest.expect.equality(line(0), HEARTBEAT)
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
end

T["a quickfix action repairs the CheckSum"] = function()
    load("bad-checksum.fix")
    H.apply_code_action(nvim(), "Fix CheckSum", 0)
    H.wait_validated(nvim())
    MiniTest.expect.equality(line(0), HEARTBEAT)
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
end

T["both diagnostics share one repair, offered once"] = function()
    load("bad-both.fix")
    local actions = H.code_actions(nvim(), 0, 0, { "quickfix" })
    MiniTest.expect.equality(#actions, 1)
    MiniTest.expect.equality(actions[1].title, "Fix BodyLength and CheckSum")

    H.apply_code_action(nvim(), "Fix BodyLength and CheckSum", 0)
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
    MiniTest.expect.equality(line(0):match("9=(%d+)"), "139")
    MiniTest.expect.equality(line(0):match("10=(%d+)"), "213")
end

T["a missing field is inserted where it belongs"] = function()
    load("missing-bodylength.fix")
    H.apply_code_action(nvim(), "Fix BodyLength", 0)
    H.wait_validated(nvim())
    MiniTest.expect.equality(line(0), HEARTBEAT)
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
end

T["a missing CheckSum is appended after the trailing separator"] = function()
    load("missing-checksum.fix")
    H.apply_code_action(nvim(), "Fix CheckSum", 0)
    H.wait_validated(nvim())
    MiniTest.expect.equality(line(0), LOGON)
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
end

T["a line without a trailing separator does not gain one"] = function()
    load("missing-checksum-no-trailing.fix")
    H.apply_code_action(nvim(), "Fix CheckSum", 0)
    H.wait_validated(nvim())
    MiniTest.expect.equality(line(0), LOGON:sub(1, -2))
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
end

T["Fix all repairs the whole buffer and leaves clean lines alone"] = function()
    load("mixed.fix")
    local before = lines()
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 2)

    H.apply_code_action(nvim(), "Fix all FIX messages", 0, 0, { "source.fixAll" })
    H.wait_validated(nvim())

    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
    local after = lines()
    MiniTest.expect.equality({ after[1], after[3], after[5] }, { before[1], before[3], before[5] })
    MiniTest.expect.equality(after[2]:match("9=(%d+)"), "139")
    MiniTest.expect.equality(after[4]:match("10=(%d+)"), "171")
end

T["Fix all lands as a single undo step"] = function()
    load("mixed.fix")
    local before = lines()
    H.apply_code_action(nvim(), "Fix all FIX messages", 0, 0, { "source.fixAll" })
    MiniTest.expect.no_equality(lines(), before)

    nvim().cmd("undo")
    MiniTest.expect.equality(lines(), before)
end

-- The plain, no-options call is the one `gra` makes: it builds its request
-- context out of the diagnostics already published for the buffer.
T["vim.lsp.buf.code_action offers the repair and applies it"] = function()
    load("bad-both.fix")
    nvim().lua([[
		_G._fix_test_select_choice = "Fix BodyLength and CheckSum"
		vim.api.nvim_win_set_cursor(0, { 1, 1 })
		vim.lsp.buf.code_action()
	]])
    MiniTest.expect.equality(H.wait_for(nvim(), "#_G._fix_test_selects > 0", 5000), true)
    H.wait_validated(nvim())

    local menu = H.get_selects(nvim())[1]
    MiniTest.expect.equality(vim.tbl_contains(menu, "Fix BodyLength and CheckSum"), true)
    MiniTest.expect.equality(vim.tbl_contains(menu, "Fix all FIX messages"), true)
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
end

T["an unnamed buffer validates without leaking buffers"] = function()
    nvim().cmd("enew")
    nvim().lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, { " .. vim.inspect(HEARTBEAT) .. " })")
    local before = nvim().lua_get("#vim.api.nvim_list_bufs()")

    nvim().cmd("set filetype=fix")
    H.wait_validated(nvim())

    H.expect_no_error_notifications(nvim())
    MiniTest.expect.equality(nvim().lua_get("#vim.api.nvim_list_bufs()"), before)
end

T["a code action range only covers the lines it names"] = function()
    load("mixed.fix")
    MiniTest.expect.equality(#H.code_actions(nvim(), 0, 0, { "quickfix" }), 0)
    MiniTest.expect.equality(#H.code_actions(nvim(), 0, 2, { "quickfix" }), 1)
    MiniTest.expect.equality(#H.code_actions(nvim(), 0, 4, { "quickfix" }), 2)
end

T["editing a message revalidates it"] = function()
    load("valid.fix")
    nvim().lua([[vim.api.nvim_buf_set_text(0, 0, 12, 0, 14, { "99" })]])
    H.wait_validated(nvim())

    local diagnostics = H.get_diagnostics(nvim())
    MiniTest.expect.equality(#diagnostics, 1)
    MiniTest.expect.equality(diagnostics[1].message, "BodyLength is 99, expected 57")

    nvim().lua([[vim.api.nvim_buf_set_text(0, 0, 12, 0, 14, { "57" })]])
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
end

-- Concealed titles: the line has no display width, so vim.diagnostic's own
-- virtual text has nowhere to go. The title carries the diagnostics instead.
local function overlay_text(lnum)
    for _, mark in ipairs(H.get_extmarks(nvim())) do
        if mark.row == lnum and mark.details.virt_text_pos == "overlay" then
            local parts = {}
            for _, chunk in ipairs(mark.details.virt_text) do
                parts[#parts + 1] = chunk[1]
            end
            return table.concat(parts)
        end
    end
    return nil
end

local function setup_replace()
    setup([[{ annotate = { title = { position = "replace" } } }]])
end

T["a concealed title carries its diagnostics"] = function()
    setup_replace()
    load("bad-both.fix")

    local text = overlay_text(0)
    MiniTest.expect.equality(text ~= nil and text:find("BodyLength is 7, expected 139", 1, true) ~= nil, true)
    MiniTest.expect.equality(text:find("CheckSum is 001, expected 213", 1, true) ~= nil, true)
end

T["a clean concealed title carries nothing extra"] = function()
    setup_replace()
    load("valid.fix")
    MiniTest.expect.equality(overlay_text(0):find("■", 1, true), nil)
end

-- The renderer debounces faster than the validator, so it always paints the
-- line before the diagnostics exist; publishing has to repaint it.
T["a title picks up diagnostics that appear after it was drawn"] = function()
    setup_replace()
    load("valid.fix")
    MiniTest.expect.equality(overlay_text(0):find("■", 1, true), nil)

    nvim().lua([[vim.api.nvim_buf_set_text(0, 0, 12, 0, 14, { "99" })]])
    H.wait_validated(nvim())
    MiniTest.expect.equality(overlay_text(0):find("BodyLength is 99, expected 57", 1, true) ~= nil, true)

    nvim().lua([[vim.api.nvim_buf_set_text(0, 0, 12, 0, 14, { "57" })]])
    H.wait_validated(nvim())
    MiniTest.expect.equality(overlay_text(0):find("■", 1, true), nil)
end

T["a concealed title suppresses the stock virtual text"] = function()
    nvim().lua([[vim.diagnostic.config({ virtual_text = true })]])
    setup_replace()
    load("bad-both.fix")

    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 2)
    MiniTest.expect.equality(#H.stock_virt_text(nvim()), 0)
    MiniTest.expect.equality(overlay_text(0):find("■", 1, true) ~= nil, true)
end

T["replace_front keeps the stock virtual text on the revealed line only"] = function()
    nvim().lua([[vim.diagnostic.config({ virtual_text = { prefix = "●" } })]])
    setup([[{ annotate = { title = { position = "replace_front" } } }]])
    load("mixed.fix")

    nvim().lua([[vim.api.nvim_win_set_cursor(0, { 2, 0 })]])
    H.wait_validated(nvim())

    local marks = H.stock_virt_text(nvim())
    MiniTest.expect.equality(#marks, 1)
    MiniTest.expect.equality(marks[1].lnum, 1)
    -- Narrowed, not replaced: the configured prefix survives.
    MiniTest.expect.equality(marks[1].text:find("●", 1, true) ~= nil, true)
end

T["replace_front does not force virtual text on when it is off"] = function()
    nvim().lua([[vim.diagnostic.config({ virtual_text = false })]])
    setup([[{ annotate = { title = { position = "replace_front" } } }]])
    load("mixed.fix")

    nvim().lua([[vim.api.nvim_win_set_cursor(0, { 2, 0 })]])
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.stock_virt_text(nvim()), 0)
end

T["a visible title leaves the stock virtual text alone"] = function()
    nvim().lua([[vim.diagnostic.config({ virtual_text = true })]])
    load("bad-both.fix")
    MiniTest.expect.equality(#H.stock_virt_text(nvim()) > 0, true)
end

T["moving away from a concealed position restores the stock virtual text"] = function()
    nvim().lua([[vim.diagnostic.config({ virtual_text = true })]])
    setup_replace()
    load("bad-both.fix")
    MiniTest.expect.equality(#H.stock_virt_text(nvim()), 0)

    setup([[{ annotate = { title = { position = "above" } } }]])
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.stock_virt_text(nvim()) > 0, true)
end

T["toggling validation off clears the title diagnostics"] = function()
    setup_replace()
    load("bad-both.fix")
    MiniTest.expect.equality(overlay_text(0):find("■", 1, true) ~= nil, true)

    nvim().cmd("FIX lsp toggle")
    H.wait_validated(nvim())
    MiniTest.expect.equality(overlay_text(0):find("■", 1, true), nil)
end

T["a rule disabled in the config stays quiet"] = function()
    setup([[{ lsp = { validate = { rules = { checksum = false } } } }]])
    load("bad-both.fix")
    local diagnostics = H.get_diagnostics(nvim())
    MiniTest.expect.equality(#diagnostics, 1)
    MiniTest.expect.equality(diagnostics[1].code, "body_length")
end

T["a rule configured at setup runs alongside the built-ins"] = function()
    setup([[{
		lsp = {
			validate = {
				rules = {
					heartbeats = {
						severity = vim.diagnostic.severity.HINT,
						check = function(ctx)
							local field = ctx.message:field(35)
							if field.value ~= "0" then
								return nil
							end
							return { { col = field.tag_start, end_col = field.value_end, message = "heartbeat" } }
						end,
					},
				},
			},
		},
	}]])
    load("bad-checksum.fix")

    local diagnostics = H.get_diagnostics(nvim())
    MiniTest.expect.equality(#diagnostics, 2)
    MiniTest.expect.equality(diagnostics[1].code, "heartbeats")
    MiniTest.expect.equality(diagnostics[1].message, "heartbeat")
    MiniTest.expect.equality(diagnostics[1].severity, 4)
    MiniTest.expect.equality(diagnostics[2].code, "checksum")
end

T["a rule registered at runtime applies to open buffers"] = function()
    load("valid.fix")
    nvim().lua([[require("fix.validate").register({
		id = "always",
		check = function(ctx)
			return { { col = 0, end_col = 1, message = "seen" } }
		end,
	})]])
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 3)
end

T["a failing rule is reported once and does not stop the others"] = function()
    setup([[{ lsp = { validate = { rules = { boom = { check = function() error("kaboom") end } } } } }]])
    load("bad-checksum.fix")

    local diagnostics = H.get_diagnostics(nvim())
    MiniTest.expect.equality(#diagnostics, 1)
    MiniTest.expect.equality(diagnostics[1].code, "checksum")
    H.expect_notified(nvim(), "rule 'boom' failed")
end

T["an unknown rule id without a check is rejected"] = function()
    local ok = nvim().lua_get(
        [[pcall(require("fix").setup, { lsp = { validate = { rules = { nope = { enabled = true } } } } })]]
    )
    MiniTest.expect.equality(ok, false)
end

T["toggling the lsp subsystem clears and restores the diagnostics"] = function()
    load("bad-both.fix")
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 2)

    nvim().cmd("FIX lsp toggle")
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
    MiniTest.expect.equality(#H.code_actions(nvim(), 0), 0)

    nvim().cmd("FIX lsp toggle")
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 2)
end

T["the lsp subsystem can be switched off in the config"] = function()
    setup([[{ lsp = { enabled = false } }]])
    load("bad-both.fix")
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
end

-- Hover ----------------------------------------------------------------------

-- 0-based byte column of the `nth` occurrence of `token` on `lnum`.
local function col_of(lnum, token, nth)
    local text, at = line(lnum), nil
    for _ = 1, nth or 1 do
        at = text:find(token, (at or 0) + 1, true)
        MiniTest.expect.no_equality(at, nil)
    end
    return at - 1
end

local function expect_contains(haystack, needle)
    if not haystack:find(needle, 1, true) then
        MiniTest.expect.equality(haystack, "<markdown containing: " .. needle .. ">")
    end
end

T["hover on an enum field shows name, type, description and value"] = function()
    load("valid.fix")
    local col = col_of(1, "54=")
    local hover = H.hover(nvim(), 1, col)

    MiniTest.expect.no_equality(hover, nil)
    for _, needle in ipairs({ "**Side** (54)", "char", "Side of order", "**Buy**", "/4.4/tagNum_54" }) do
        expect_contains(hover.value, needle)
    end
    MiniTest.expect.equality(hover.range.start, { line = 1, character = col })
    MiniTest.expect.equality(hover.range["end"], { line = 1, character = col + #"54=1" })
end

T["hover on MsgType adds the message description from Messages.xml"] = function()
    load("valid.fix")
    local hover = H.hover(nvim(), 1, col_of(1, "35="))

    MiniTest.expect.no_equality(hover, nil)
    expect_contains(hover.value, "NewOrderSingle")
    -- This phrase exists only in Messages.xml, not in the tag-35 enum table.
    expect_contains(hover.value, "electronically submit securities")
    expect_contains(hover.value, "*Category: SingleGeneralOrderHandling*")
end

T["hover on a field without an enum shows the raw value only"] = function()
    load("valid.fix")
    local hover = H.hover(nvim(), 1, col_of(1, "49="))

    MiniTest.expect.no_equality(hover, nil)
    expect_contains(hover.value, "SenderCompID")
    expect_contains(hover.value, "Value: `CLIENT1`")
    MiniTest.expect.equality(hover.value:find("`CLIENT1` —", 1, true), nil)
end

T["hover between fields returns nothing"] = function()
    load("valid.fix")
    local separator = col_of(1, "54=") - 1
    MiniTest.expect.equality(H.hover(nvim(), 1, separator), nil)
end

T["hover inside a repeating group shows the group path"] = function()
    load("groups.fix")
    local hover = H.hover(nvim(), 0, col_of(0, "269=", 2))

    MiniTest.expect.no_equality(hover, nil)
    expect_contains(hover.value, "MDEntryType")
    expect_contains(hover.value, "Group: `NoMDEntries/2/MDEntryType`")
end

T["hover follows the lsp toggle"] = function()
    load("valid.fix")
    local col = col_of(1, "54=")
    MiniTest.expect.no_equality(H.hover(nvim(), 1, col), nil)

    nvim().cmd("FIX lsp toggle")
    H.wait_validated(nvim())
    MiniTest.expect.equality(H.hover(nvim(), 1, col), nil)

    nvim().cmd("FIX lsp toggle")
    H.wait_validated(nvim())
    MiniTest.expect.no_equality(H.hover(nvim(), 1, col), nil)
end

T["hover can be switched off in the config"] = function()
    setup([[{ lsp = { hover = { enabled = false } } }]])
    load("valid.fix")
    MiniTest.expect.equality(H.hover(nvim(), 1, col_of(1, "54=")), nil)
end

T["disabling validation keeps hover alive"] = function()
    setup([[{ lsp = { validate = { enabled = false } } }]])
    load("bad-both.fix")

    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
    MiniTest.expect.equality(#H.code_actions(nvim(), 0), 0)
    local hover = H.hover(nvim(), 0, col_of(0, "54="))
    MiniTest.expect.no_equality(hover, nil)
    expect_contains(hover.value, "**Side** (54)")
end

return T
