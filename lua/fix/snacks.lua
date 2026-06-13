local document = require("fix.document")

local M = {}

local function append_message_items(items, message, message_idx, file)
    local msg_type = message:field(35).value_text
    local sender = message:field(49).value
    local seq_no = message:field(34).value

    for _, field in pairs(message:list_fields()) do
        local text = string.format(
            "#%s:%s:%s%s=%s:%s=%s",
            seq_no,
            msg_type,
            sender,
            field.tag,
            field.value,
            field.tag_text or "",
            field.value_text or ""
        )
        -- assuming that message won't have more than 100,000 fields
        local index = message_idx * 100000 + field.index
        table.insert(items, {
            index = index,
            text = text,
            message = message,
            field = field,
            lineno = message.lineno,
            file = file,
            pos = { message.lineno + 1, field.tag_start },
            end_pos = { message.lineno + 1, field.value_end },
        })
    end
end

function M.open()
    local ok, snacks = pcall(require, "snacks")
    if not ok then
        vim.notify("fix.nvim: snacks.nvim is not installed", vim.log.levels.WARN)
        return
    end

    local buf = vim.api.nvim_get_current_buf()
    local file = vim.api.nvim_buf_get_name(buf)
    local chunk = require("fix").opts.render.lines_per_batch

    local items = {}
    local message_idx = 0
    local lnum = 0

    local function append_chunk()
        local line_count = vim.api.nvim_buf_line_count(buf)
        local stop = math.min(lnum + chunk, line_count)
        while lnum < stop do
            local message = document.build_line(buf, lnum)
            if message then
                append_message_items(items, message, message_idx, file)
                message_idx = message_idx + 1
            end
            lnum = lnum + 1
        end
        return lnum < line_count
    end

    -- First chunk synchronously so the picker opens with content (cache hits
    -- make this near-instant on warmed buffers).
    local more = append_chunk()

    local picker = snacks.picker({
        title = "FIX fields",
        items = items,

        format = function(item, _)
            local field = item.field
            local message = item.message
            local msg_type = message:field(35)
            local sender = message:field(49).value
            local seq_no = message:field(34).value

            local ret = {}
            ret[#ret + 1] = { string.format("#%s %s => %s ", seq_no, sender, msg_type.value_text), "Comment" }

            if field.tag_text then
                ret[#ret + 1] = { string.format("%s(%d)", field.tag_text, field.tag), "Type" }
            else
                ret[#ret + 1] = { tostring(field.tag), "Type" }
            end

            ret[#ret + 1] = { "=", "Operator" }

            if field.value_text then
                ret[#ret + 1] = { string.format("%s(%s)", field.value_text, field.value), "Label" }
            else
                ret[#ret + 1] = { field.value, "Label" }
            end

            return ret
        end,

        sort = {
            fields = { "index" },
        },

        confirm = function(p, item)
            p:close()
            if item then
                local field = item.field ---@type Field
                vim.api.nvim_win_set_cursor(0, { item.lineno + 1, field.tag_start })
            end
        end,
    })

    local function stream()
        if picker.closed or not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local has_more = append_chunk()
        -- items is the live table the default finder re-reads; find() re-runs it
        picker:find({ refresh = true })
        if has_more then
            vim.defer_fn(stream, 10)
        end
    end

    if more then
        vim.defer_fn(stream, 10)
    end
end

return M
