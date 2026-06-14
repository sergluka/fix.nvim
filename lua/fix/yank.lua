local M = {}

local document = require("fix.document")

local ns = vim.api.nvim_create_namespace("blink_region")

---@class FixYankSelection
---@field start_row number
---@field start_col number 0-based, inclusive
---@field end_row number
---@field end_col number 0-based, exclusive
---@field kind? "char" | "line" | "block"

local function field_to_text(opts, field)
    local tag = opts.annotate.tag.formatter(field)
    if tag ~= nil then
        tag = tostring(field.tag) .. tag[1]
    else
        tag = tostring(field.tag)
    end

    local value = opts.annotate.value.formatter(field)
    if value ~= nil then
        value = field.value .. tostring(value[1])
    else
        value = field.value
    end

    return string.format("%s=%s", tag, value)
end

local function fields_to_text(opts, fields)
    local txt_fields = {}
    for _, field in ipairs(fields) do
        txt_fields[#txt_fields + 1] = field_to_text(opts, field)
    end
    return table.concat(txt_fields, "|")
end

local function set_register(regname, text, regtype)
    if regtype then
        vim.fn.setreg(regname or "", text, regtype)
    else
        vim.fn.setreg(regname or "", text)
    end
end

local function blink(buf, start_row, start_col, end_row, end_col)
    local timeout = 150 -- ms

    local id = vim.api.nvim_buf_set_extmark(buf, ns, start_row, start_col, {
        end_row = end_row,
        end_col = end_col,
        hl_group = "IncSearch",
        hl_mode = "combine",
    })

    vim.defer_fn(function()
        pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
    end, timeout)
end

local function blink_fields(buf, message, fields)
    if #fields == 0 then
        return
    end
    blink(buf, message.lineno, fields[1].tag_start, message.lineno, fields[#fields].value_end)
end

local function normalize_selection(selection)
    if not selection then
        return nil
    end

    local start_row = selection.start_row
    local start_col = selection.start_col
    local end_row = selection.end_row
    local end_col = selection.end_col

    if not start_row or not start_col or not end_row or not end_col then
        return nil
    end

    if start_row > end_row or (start_row == end_row and start_col > end_col) then
        start_row, end_row = end_row, start_row
        start_col, end_col = end_col, start_col
    end

    return {
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
        kind = selection.kind or "char",
    }
end

local function visual_selection()
    local mode = vim.fn.mode()
    if mode ~= "v" and mode ~= "V" and mode ~= "\022" then
        return nil
    end

    local anchor = vim.fn.getpos("v")
    if anchor[2] == 0 then
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local anchor_row = anchor[2] - 1
    local anchor_col = math.max(anchor[3] - 1, 0)
    local cursor_row = cursor[1] - 1
    local cursor_col = cursor[2]
    local kind = "char"

    if mode == "V" then
        anchor_col = 0
        cursor_col = math.huge
        kind = "line"
    elseif mode == "\022" then
        kind = "block"
    end

    if anchor_row > cursor_row or (anchor_row == cursor_row and anchor_col > cursor_col) then
        anchor_row, cursor_row = cursor_row, anchor_row
        anchor_col, cursor_col = cursor_col, anchor_col
    end

    return {
        start_row = anchor_row,
        start_col = anchor_col,
        end_row = cursor_row,
        end_col = cursor_col + 1,
        kind = kind,
    }
end

local function operator_selection(motion_type)
    local start_mark = vim.fn.getpos("'[")
    local end_mark = vim.fn.getpos("']")
    if start_mark[2] == 0 or end_mark[2] == 0 then
        return nil
    end

    local kind = motion_type == "line" and "line" or "char"
    if motion_type == "block" then
        kind = "block"
    end

    if kind == "line" then
        return normalize_selection({
            start_row = start_mark[2] - 1,
            start_col = 0,
            end_row = end_mark[2] - 1,
            end_col = math.huge,
            kind = "line",
        })
    end

    return normalize_selection({
        start_row = start_mark[2] - 1,
        start_col = math.max(start_mark[3] - 1, 0),
        end_row = end_mark[2] - 1,
        end_col = end_mark[3],
        kind = kind,
    })
end

local function operator_register()
    local register = vim.v.register
    local pending_register = vim.b.fix_yank_operator_register
    vim.b.fix_yank_operator_register = nil

    if register and register ~= '"' then
        return register
    end
    return pending_register or ""
end

local function line_columns(selection, lnum)
    if lnum < selection.start_row or lnum > selection.end_row then
        return nil, nil
    end

    local start_col = 0
    local end_col = math.huge
    if lnum == selection.start_row then
        start_col = selection.start_col
    end
    if lnum == selection.end_row then
        end_col = selection.end_col
    end
    return start_col, end_col
end

local function field_overlaps(field, start_col, end_col)
    return field.tag_start < end_col and field.value_end > start_col
end

local function selected_field_groups(buf, selection)
    selection = normalize_selection(selection)
    if not selection then
        return {}
    end

    local last_line = vim.api.nvim_buf_line_count(buf) - 1
    local start_row = math.max(selection.start_row, 0)
    local end_row = math.min(selection.end_row, last_line)
    if start_row > end_row then
        return {}
    end

    local groups = {}
    for lnum = start_row, end_row do
        local message = document.build_line(buf, lnum)
        if message then
            local start_col, end_col = line_columns(selection, lnum)
            local fields = {}
            for _, field in ipairs(message:list_fields()) do
                if field_overlaps(field, start_col, end_col) then
                    fields[#fields + 1] = field
                end
            end
            if #fields > 0 then
                groups[#groups + 1] = { message = message, fields = fields }
            end
        end
    end

    return groups
end

local function groups_to_text(opts, groups)
    local lines = {}
    for _, group in ipairs(groups) do
        lines[#lines + 1] = fields_to_text(opts, group.fields)
    end
    return table.concat(lines, "\n")
end

local function yank_characterwise(opts, regname, selection, regtype)
    local buf = vim.api.nvim_get_current_buf()
    local active_selection = selection or visual_selection()
    if active_selection then
        local groups = selected_field_groups(buf, active_selection)
        if #groups == 0 then
            return
        end
        set_register(regname, groups_to_text(opts, groups), regtype)
        for _, group in ipairs(groups) do
            blink_fields(buf, group.message, group.fields)
        end
        return
    end

    local message, field = document.get_field_under_cursor(buf)
    if message == nil or field == nil then
        return
    end

    local text = field_to_text(opts, field)
    set_register(regname, text, regtype)

    local lineno = message.lineno
    blink(buf, lineno, field.tag_start, lineno, field.value_end)
end

local function yank_linewise(opts, regname, selection, regtype)
    local buf = vim.api.nvim_get_current_buf()
    local active_selection = selection or visual_selection()
    if active_selection then
        local groups = selected_field_groups(buf, active_selection)
        if #groups == 0 then
            return
        end
        local lines = {}
        for _, group in ipairs(groups) do
            local fields = group.message:list_fields()
            lines[#lines + 1] = fields_to_text(opts, fields)
            blink_fields(buf, group.message, fields)
        end
        set_register(regname, table.concat(lines, "\n"), regtype)
        return
    end

    local message, _ = document.get_field_under_cursor(buf)
    if message == nil then
        return
    end

    local fields = message:list_fields()
    if #fields == 0 then
        return
    end
    local text = fields_to_text(opts, fields)

    set_register(regname, text, regtype)

    blink_fields(buf, message, fields)
end

---@param opts FixOpts
---@param regname string?
---@param selection? FixYankSelection
function M.yank(opts, regname, selection)
    local active_selection = selection or visual_selection()
    if not active_selection then
        yank_characterwise(opts, regname, nil, "v")
        return
    end

    active_selection = normalize_selection(active_selection)
    if not active_selection then
        return
    end

    if active_selection.kind == "line" then
        yank_linewise(opts, regname, active_selection, "V")
    else
        yank_characterwise(opts, regname, active_selection, "v")
    end
end

---@param opts FixOpts
---@param motion_type string
function M.operator_yank(opts, motion_type)
    local selection = operator_selection(motion_type)
    if not selection then
        return
    end
    M.yank(opts, operator_register(), selection)
end

return M
