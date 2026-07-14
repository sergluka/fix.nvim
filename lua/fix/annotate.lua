local Cache = require("fix.cache")
local Field = require("fix.field")

local M = {}

local function resolve_group_highlight(instance, palette)
    if not instance or #palette == 0 then
        return nil
    end
    local offset = ((instance.depth - 1) * 2 + instance.index - 1) % #palette
    return palette[offset + 1]
end

local function with_group_highlight(virt_text, highlight)
    if not highlight then
        return virt_text
    end

    local base_highlight = virt_text[2]
    if base_highlight then
        return { virt_text[1], { base_highlight, highlight } }
    end
    return { virt_text[1], highlight }
end

--- Build a line-relative render payload. Always contains every annotation
--- kind; enabled flags are applied in M.apply so toggling doesn't invalidate
--- cached payloads.
---@param message Message
---@param opts FixOpts
---@return FixRenderPayload
function M.build_payload(message, opts)
    local payload = { marks = {}, group_ranges = {} }
    local palette = opts.annotate.group.highlight.palette

    local ok, title = pcall(opts.annotate.title.formatter, message)
    if ok then
        payload.title = title
    else
        vim.notify_once("failed to annotate message: " .. title, vim.log.levels.ERROR)
    end

    local group_ranges = {}
    for _, field in pairs(message:fields()) do
        for _, instance in ipairs(field.group_instances or {}) do
            local range = group_ranges[instance.key]
            if range then
                range.start_col = math.min(range.start_col, field.tag_start)
                range.end_col = math.max(range.end_col, field.value_end)
            else
                group_ranges[instance.key] = {
                    start_col = field.tag_start,
                    end_col = field.value_end,
                    depth = instance.depth,
                    index = instance.index,
                }
            end
        end

        local group_highlight
        local group_instances = field.group_instances or {}
        local group_instance = group_instances[#group_instances]
        group_highlight = resolve_group_highlight(group_instance, palette)

        local format_field = field
        if not opts.annotate.group.path.enabled and field.group_path_text then
            format_field = Field.copy(field)
            format_field.group_path_text = nil
        end
        if field.tag_text then
            local ok_tag, tag_text = pcall(opts.annotate.tag.formatter, format_field)
            if not ok_tag then
                vim.notify_once("failed to annotate field: " .. tag_text, vim.log.levels.ERROR)
            elseif tag_text then
                payload.marks[#payload.marks + 1] =
                    { col = field.tag_end, virt_text = tag_text, kind = "tag", group_highlight = group_highlight }
            end
        end
        if field.value_text then
            local ok_value, value_text = pcall(opts.annotate.value.formatter, format_field)
            if not ok_value then
                vim.notify_once("failed to annotate field: " .. value_text, vim.log.levels.ERROR)
            elseif value_text then
                payload.marks[#payload.marks + 1] =
                    { col = field.value_end, virt_text = value_text, kind = "value", group_highlight = group_highlight }
            end
        end
    end

    for _, range in pairs(group_ranges) do
        payload.group_ranges[#payload.group_ranges + 1] = range
    end
    table.sort(payload.group_ranges, function(lhs, rhs)
        if lhs.depth == rhs.depth then
            return lhs.start_col < rhs.start_col
        end
        return lhs.depth < rhs.depth
    end)

    return payload
end

--- Cached payload for a message keyed by its line hash.
---@param message Message
---@param key string
---@param opts FixOpts
---@return FixRenderPayload
function M.payload_for(message, key, opts)
    local payload = Cache.get_render(key)
    if payload == nil then
        payload = M.build_payload(message, opts)
        Cache.put_render(key, payload)
    end
    return payload
end

local function apply_title(bufnr, ns_id, lnum, title, position)
    if position == "front" then
        local virt_text = title[1]
        if virt_text then
            vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum, 0, {
                virt_text = virt_text,
                virt_text_pos = "inline",
            })
        end
    else
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum, 0, {
            virt_lines = title,
            virt_lines_above = position == "above",
        })
    end
end

--- Apply a payload to one line: point-clear, then set extmarks filtered by
--- the enabled flags. All marks of a message anchor on the message line
--- itself, so the point-clear can never orphan anything.
---@param opts FixOpts
---@param bufnr number
---@param ns_id number
---@param lnum number 0-based
---@param line_text string
---@param payload FixRenderPayload|nil
---@param front_line? boolean
function M.apply(opts, bufnr, ns_id, lnum, line_text, payload, front_line)
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, lnum, lnum + 1)
    if payload == nil then
        return
    end

    if opts.annotate.title.enabled and payload.title then
        if opts.annotate.title.position == "replace" or opts.annotate.title.position == "replace_front" then
            if not front_line then
                local virt_text = payload.title[1]
                if virt_text then
                    vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum, 0, {
                        end_col = #line_text,
                        conceal = "",
                    })
                    vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum, 0, {
                        virt_text = virt_text,
                        virt_text_pos = "overlay",
                    })
                end
                return
            end
            apply_title(bufnr, ns_id, lnum, payload.title, "front")
        else
            apply_title(bufnr, ns_id, lnum, payload.title, opts.annotate.title.position)
        end
    end

    if opts.annotate.group.highlight.enabled then
        local palette = opts.annotate.group.highlight.palette
        local target = opts.annotate.group.highlight.target
        if target == "raw" or target == "both" then
            for _, range in ipairs(payload.group_ranges or {}) do
                vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum, range.start_col, {
                    end_col = range.end_col,
                    hl_group = resolve_group_highlight(range, palette),
                    priority = 80 + range.depth,
                })
            end
        end
    end

    for _, mark in ipairs(payload.marks) do
        local enabled = (mark.kind == "tag" and opts.annotate.tag.enabled)
            or (mark.kind == "value" and opts.annotate.value.enabled)
        if enabled then
            local virt_text = mark.virt_text
            if
                opts.annotate.group.highlight.enabled
                and mark.group_highlight
                and (
                    opts.annotate.group.highlight.target == "annotation"
                    or opts.annotate.group.highlight.target == "both"
                )
            then
                virt_text = with_group_highlight(mark.virt_text, mark.group_highlight)
            end
            vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum, mark.col, {
                virt_text = { virt_text },
                virt_text_pos = "inline",
            })
        end
    end
end

return M
