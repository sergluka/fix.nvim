local MiniTest = require("mini.test")

local M = {}

-- Active child Neovim for the current case; set by M.new_test_set's pre_case
-- hook and read via M.nvim().
local _nvim

local nvim_ARGS = { "-u", "tests/integration/minimal_init.lua" }

local STUB_INSTALL = [[
	_G._fix_test_notifications = {}
	_G._fix_test_ui_opens = {}
	_G._fix_test_picker_opens = 0
	_G._fix_test_tree_opens = 0
	_G._fix_test_tree_refreshes = 0
	_G._fix_test_selects = {}
	_G._fix_test_select_choice = nil

	vim.notify = function(msg, level)
		table.insert(_G._fix_test_notifications, { msg, level })
	end
	vim.notify_once = vim.notify

	vim.ui.open = function(target)
		table.insert(_G._fix_test_ui_opens, target)
	end

	-- Record each menu's labels, then pick by label or index so tests can drive
	-- UI-only entry points such as vim.lsp.buf.code_action().
	vim.ui.select = function(items, opts, on_choice)
		local labels = {}
		for i, item in ipairs(items) do
			labels[i] = opts and opts.format_item and opts.format_item(item) or tostring(item)
		end
		table.insert(_G._fix_test_selects, labels)

		local choice = _G._fix_test_select_choice
		if type(choice) == "string" then
			choice = vim.fn.index(labels, choice) + 1
		end
		if type(choice) ~= "number" or choice < 1 or choice > #items then
			return on_choice(nil, nil)
		end
		return on_choice(items[choice], choice)
	end

	package.loaded["fix.snacks"] = {
		open = function()
			_G._fix_test_picker_opens = _G._fix_test_picker_opens + 1
		end,
	}
	package.loaded["fix.neo_tree"] = {
		open = function()
			_G._fix_test_tree_opens = _G._fix_test_tree_opens + 1
		end,
		refresh = function()
			_G._fix_test_tree_refreshes = _G._fix_test_tree_refreshes + 1
		end,
	}
]]

function M.new_nvim(opts)
    opts = opts or {}
    local nvim = MiniTest.new_child_neovim()
    nvim.start(nvim_ARGS)
    nvim.o.lines = 30
    nvim.o.columns = 100
    nvim.lua(STUB_INSTALL)
    if opts.real_picker then
        nvim.lua([[package.loaded["fix.snacks"] = nil]])
    end
    if opts.real_tree then
        nvim.lua([[package.loaded["fix.neo_tree"] = nil]])
    end
    if opts.inline_annotations then
        M.enable_inline_annotations(nvim)
    end
    return nvim
end

--- Turn tag/value annotations on for the rest of this child's life. The wrapper
--- keeps them on across any later `fix.setup()` a test performs, which would
--- otherwise restore the off-by-default flags.
function M.enable_inline_annotations(nvim)
    nvim.lua([[
        local fix = require("fix")
        local setup = fix.setup
        fix.setup = function(opts)
            return setup(vim.tbl_deep_extend("force", opts or {}, {
                annotate = { tag = { enabled = true }, value = { enabled = true } },
            }))
        end
        for _, opts in ipairs({ fix.opts, fix.opts_initial }) do
            opts.annotate.tag.enabled = true
            opts.annotate.value.enabled = true
        end
        require("fix.render").rerender_all()
    ]])
end

--- Returns a MiniTest set whose pre_case / post_case lifecycle spawns and
--- tears down a fresh nvim Neovim, stashed in the module-local _nvim. Use
--- together with M.nvim() inside cases.
function M.new_test_set(opts)
    return MiniTest.new_set({
        hooks = {
            pre_case = function()
                _nvim = M.new_nvim(opts)
            end,
            post_case = function()
                _nvim.stop()
                _nvim = nil
            end,
        },
    })
end

--- Accessor for the nvim Neovim spawned by the pre_case hook.
function M.nvim()
    return _nvim
end

--- Block until `cond_lua` evaluates truthy in the nvim or `timeout_ms` elapses.
--- Returns true on success, false on timeout — callers can fail the test loudly.
function M.wait_for(nvim, cond_lua, timeout_ms)
    return nvim.lua_get(string.format([[vim.wait(%d, function() return %s end, 25)]], timeout_ms, cond_lua))
end

--- Sleep `ms` inside the nvim (no condition).
function M.sleep(nvim, ms)
    nvim.lua(string.format([[vim.wait(%d, function() return false end, 25)]], ms))
end

--- Wait until the render scheduler is idle (warm-up done, no pending edits).
function M.wait_annotated(nvim, timeout_ms)
    local ok = M.wait_for(nvim, [[require("fix.render").is_idle(vim.api.nvim_get_current_buf())]], timeout_ms or 5000)
    MiniTest.expect.equality(ok, true)
end

--- Wait until the validation engine is idle (whole buffer walked, nothing pending).
function M.wait_validated(nvim, timeout_ms)
    local ok = M.wait_for(nvim, [[require("fix.validate").is_idle(vim.api.nvim_get_current_buf())]], timeout_ms or 5000)
    MiniTest.expect.equality(ok, true)
end

--- The stock virtual_text marks the diagnostic handler placed for our own
--- namespace. Switches to `buf` first when given.
function M.stock_virt_text(nvim, buf)
    if buf then
        nvim.cmd("buffer " .. buf)
    end
    return nvim.lua_get([[(function()
		local client = vim.lsp.get_clients({ bufnr = 0, name = "fix-validate" })[1]
		local ns = vim.diagnostic.get_namespace(vim.lsp.diagnostic.get_namespace(client.id, false))
		local virt_text_ns = ns.user_data.virt_text_ns
		local out = {}
		if not virt_text_ns then return out end
		for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, virt_text_ns, 0, -1, { details = true })) do
			local parts = {}
			for _, chunk in ipairs(m[4].virt_text or {}) do parts[#parts + 1] = chunk[1] end
			out[#out + 1] = { lnum = m[2], text = table.concat(parts) }
		end
		return out
	end)()]])
end

--- Diagnostics of the current buffer, ordered by position then rule.
function M.get_diagnostics(nvim)
    return nvim.lua_get([[(function()
		local out = {}
		for _, d in ipairs(vim.diagnostic.get(0)) do
			out[#out + 1] = {
				lnum = d.lnum,
				col = d.col,
				end_col = d.end_col,
				severity = d.severity,
				message = d.message,
				code = d.code,
				source = d.source,
			}
		end
		table.sort(out, function(a, b)
			if a.lnum ~= b.lnum then return a.lnum < b.lnum end
			if a.col ~= b.col then return a.col < b.col end
			return tostring(a.code) < tostring(b.code)
		end)
		return out
	end)()]])
end

--- One snippet for every codeAction request: resolves the fix-validate client,
--- issues the request, then runs `body` with `client` and `response` in scope.
local function code_action_request(first, last, only, no_client, body)
    return string.format(
        [[(function()
		local buf = vim.api.nvim_get_current_buf()
		local client = vim.lsp.get_clients({ bufnr = buf, name = "fix-validate" })[1]
		if not client then return %s end
		local response = client:request_sync("textDocument/codeAction", {
			textDocument = { uri = vim.uri_from_bufnr(buf) },
			range = {
				start = { line = %d, character = 0 },
				["end"] = { line = %d, character = 0 },
			},
			context = { diagnostics = {}, only = %s },
		}, 5000, buf)
		%s
	end)()]],
        no_client,
        first,
        last or first,
        only and vim.inspect(only) or "nil",
        body
    )
end

--- Ask the in-process server for code actions over a 0-based line range.
--- `only` restricts the kinds, e.g. { "source.fixAll" }.
function M.code_actions(nvim, first, last, only)
    return nvim.lua_get(code_action_request(
        first,
        last,
        only,
        "nil",
        [[local out = {}
		for _, action in ipairs(response and response.result or {}) do
			out[#out + 1] = { title = action.title, kind = action.kind }
		end
		return out]]
    ))
end

--- Ask the in-process server for hover at a 0-based position.
--- Returns { value = <markdown>, range = <lsp range> } or nil.
function M.hover(nvim, line, character)
    local result = nvim.lua_get(string.format(
        [[(function()
		local buf = vim.api.nvim_get_current_buf()
		local client = vim.lsp.get_clients({ bufnr = buf, name = "fix-validate" })[1]
		if not client then return nil end
		local response = client:request_sync("textDocument/hover", {
			textDocument = { uri = vim.uri_from_bufnr(buf) },
			position = { line = %d, character = %d },
		}, 5000, buf)
		local result = response and response.result
		if result == nil or result == vim.NIL then return nil end
		return { value = result.contents.value, range = result.range }
	end)()]],
        line,
        character
    ))
    if result == vim.NIL then
        return nil
    end
    return result
end

--- Apply the first code action with the given title, the way a client would.
function M.apply_code_action(nvim, title, first, last, only)
    local applied = nvim.lua_get(
        code_action_request(
            first,
            last,
            only,
            "false",
            string.format(
                [[for _, action in ipairs(response and response.result or {}) do
			if action.title == %s then
				vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
				return true
			end
		end
		return false]],
                vim.inspect(title)
            )
        )
    )
    MiniTest.expect.equality(applied, true)
end

--- Edit a fixture file. Behaviour depends on opts.expect_extmarks:
---   true  (default): wait for the render scheduler to go idle, then assert
---          at least one extmark exists.
---   false: still wait for idle (or `timeout_ms` for non-fix buffers) for any
---          deferred side-effects (vim.notify, ftplugin settings) to flush.
function M.load_fixture(nvim, name, opts)
    opts = opts or {}
    local expect = opts.expect_extmarks
    if expect == nil then
        expect = true
    end
    nvim.cmd("edit tests/integration/fixtures/" .. name)
    if nvim.lua_get("vim.bo.filetype") == "fix" then
        M.wait_annotated(nvim, opts.timeout_ms or 5000)
    else
        M.sleep(nvim, opts.timeout_ms or 500)
    end
    if expect then
        MiniTest.expect.equality(#M.get_extmarks(nvim) > 0, true)
    end
end

function M.get_extmarks(nvim)
    return nvim.lua_get([[(function()
		local ns = vim.api.nvim_create_namespace("fix-protocol")
		local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
		local out = {}
		for _, m in ipairs(marks) do
			out[#out + 1] = { row = m[2], col = m[3], details = m[4] }
		end
		table.sort(out, function(a, b)
			if a.row == b.row then return a.col < b.col end
			return a.row < b.row
		end)
		return out
	end)()]])
end

function M.get_notifications(nvim)
    return nvim.lua_get("_G._fix_test_notifications")
end

function M.get_ui_opens(nvim)
    return nvim.lua_get("_G._fix_test_ui_opens")
end

function M.get_picker_opens(nvim)
    return nvim.lua_get("_G._fix_test_picker_opens")
end

function M.get_tree_opens(nvim)
    return nvim.lua_get("_G._fix_test_tree_opens")
end

function M.get_tree_refreshes(nvim)
    return nvim.lua_get("_G._fix_test_tree_refreshes")
end

--- Labels of every vim.ui.select menu shown so far, newest last.
function M.get_selects(nvim)
    return nvim.lua_get("_G._fix_test_selects")
end

-- Default tag/value formatters wrap text as "(Name)". Strip parens and
-- surrounding whitespace to recover the semantic label.
local function strip_label(raw)
    return raw:gsub("^%s*%(", ""):gsub("%)%s*$", "")
end

--- Count inline extmarks whose virt_text label (parens stripped) equals `label`.
function M.inline_label_count(nvim, label)
    local n = 0
    for _, m in ipairs(M.get_extmarks(nvim)) do
        local vt = m.details.virt_text
        if vt and m.details.virt_text_pos == "inline" and strip_label(vt[1][1]) == label then
            n = n + 1
        end
    end
    return n
end

--- Count extmarks with virt_lines (message titles).
function M.virt_lines_count(nvim)
    local n = 0
    for _, m in ipairs(M.get_extmarks(nvim)) do
        if m.details.virt_lines then
            n = n + 1
        end
    end
    return n
end

-- Custom expectations -------------------------------------------------------

local function inline_labels_dump(nvim)
    local seen = {}
    for _, m in ipairs(M.get_extmarks(nvim)) do
        local vt = m.details.virt_text
        if vt and m.details.virt_text_pos == "inline" then
            seen[#seen + 1] = strip_label(vt[1][1])
        end
    end
    return seen
end

--- Assert at least one inline extmark with the given label (parens stripped).
M.expect_inline_label = MiniTest.new_expectation(function(_, label)
    return string.format("inline extmark with label %q", label)
end, function(nvim, label)
    return M.inline_label_count(nvim, label) > 0
end, function(nvim, _)
    return "observed labels: " .. vim.inspect(inline_labels_dump(nvim))
end)

--- Assert there is no inline extmark with the given label.
M.expect_no_inline_label = MiniTest.new_expectation(function(_, label)
    return string.format("no inline extmark with label %q", label)
end, function(nvim, label)
    return M.inline_label_count(nvim, label) == 0
end, function(nvim, _)
    return "observed labels: " .. vim.inspect(inline_labels_dump(nvim))
end)

--- Assert the count of virt_lines extmarks (message titles) equals `n`.
M.expect_virt_lines_count = MiniTest.new_expectation(function(_, n)
    return string.format("%d virt_lines extmark(s)", n)
end, function(nvim, n)
    return M.virt_lines_count(nvim) == n
end, function(nvim, _)
    return "got: " .. tostring(M.virt_lines_count(nvim))
end)

--- Assert a notification matches the Lua pattern.
M.expect_notified = MiniTest.new_expectation(function(_, pattern)
    return string.format("notification matching %q", pattern)
end, function(nvim, pattern)
    for _, n in ipairs(M.get_notifications(nvim)) do
        if n[1]:find(pattern) then
            return true
        end
    end
    return false
end, function(nvim, _)
    return "captured: " .. vim.inspect(M.get_notifications(nvim))
end)

--- Assert no ERROR-level notification was captured.
M.expect_no_error_notifications = MiniTest.new_expectation("no ERROR-level notifications", function(nvim)
    for _, n in ipairs(M.get_notifications(nvim)) do
        if n[2] == vim.log.levels.ERROR then
            return false
        end
    end
    return true
end, function(nvim)
    return "captured: " .. vim.inspect(M.get_notifications(nvim))
end)

return M
