local H = require("tests.integration.helpers")
local MiniTest = require("mini.test")

local T = H.new_test_set()
local nvim = H.nvim

local function autocmd_count(c)
    -- Count autocmds inside the fix-decorate group AND any FileType=fix
    -- autocmds outside the group. The latter catches regressions where a
    -- handler is registered without group=<augroup>, leaking one new
    -- handler per setup() call.
    return c.lua_get([[(function()
		local n = #vim.api.nvim_get_autocmds({ group = "fix-decorate" })
		for _, ac in ipairs(vim.api.nvim_get_autocmds({ event = "FileType" })) do
			if ac.pattern == "fix" and ac.group_name ~= "fix-decorate" then
				n = n + 1
			end
		end
		return n
	end)()]])
end

T["setup is idempotent (no autocmd leak across groups)"] = function()
    local before = autocmd_count(nvim())
    nvim().lua([[require("fix").setup({})]])
    nvim().lua([[require("fix").setup({})]])
    MiniTest.expect.equality(autocmd_count(nvim()), before)
end

T["set ft=fix on plain buffer triggers annotations"] = function()
    nvim().cmd("enew")
    nvim().lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, {
			"",
			"8=FIX.4.4|9=70|35=0|34=1|49=A|56=B|52=20260101-00:00:00.000|10=000|",
		})
	]])
    nvim().cmd("set filetype=fix")
    H.wait_annotated(nvim())
    MiniTest.expect.equality(#H.get_extmarks(nvim()) > 0, true)
end

T["ft change from fix to text leaves namespace intact"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    local before = #H.get_extmarks(nvim())
    MiniTest.expect.equality(before > 0, true)
    nvim().cmd("set filetype=text")
    -- Documents current behaviour: extmarks survive until the next render trigger.
    MiniTest.expect.equality(#H.get_extmarks(nvim()), before)
end

T["edit re-renders without duplicating extmarks"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    local before = #H.get_extmarks(nvim())
    nvim().type_keys("Go# comment", "<Esc>")
    -- The edit flows through on_lines + debounce; wait for the scheduler to
    -- settle. The comment line is not a FIX message, so the count must not
    -- grow beyond a small tolerance.
    H.wait_annotated(nvim())
    local after = #H.get_extmarks(nvim())
    -- A new line was appended; tolerance accounts for any new annotations
    -- but rules out duplication of the originals or a regression that strips them.
    MiniTest.expect.equality(after >= before, true)
    MiniTest.expect.equality(after <= before + 5, true)
end

T["bwipeout then edit re-renders cleanly"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    local before = #H.get_extmarks(nvim())
    nvim().cmd("bwipeout!")
    H.load_fixture(nvim(), "4.4.fix")
    MiniTest.expect.equality(#H.get_extmarks(nvim()), before)
end

T["ftplugin/fix.lua applies buffer-local options"] = function()
    H.load_fixture(nvim(), "4.4.fix")
    MiniTest.expect.equality(nvim().lua_get("vim.bo.commentstring"), "# %s")
    MiniTest.expect.equality(nvim().lua_get("vim.bo.iskeyword"), "33-60,62-123,125-255")
    MiniTest.expect.equality(nvim().lua_get("vim.wo.conceallevel"), 2)
    MiniTest.expect.equality(nvim().lua_get("vim.wo.concealcursor"), "nc")
    MiniTest.expect.equality(nvim().lua_get("vim.wo.wrap"), true)
end

return T
