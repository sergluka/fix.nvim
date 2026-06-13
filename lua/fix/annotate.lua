local Cache = require("fix.cache")

local M = {}

--- Build a line-relative render payload. Always contains every annotation
--- kind; enabled flags are applied in M.apply so toggling doesn't invalidate
--- cached payloads.
---@param message Message
---@param opts FixOpts
---@return FixRenderPayload
function M.build_payload(message, opts)
    local payload = { marks = {} }

    local ok, title = pcall(opts.annotate.message.formatter, message)
    if ok then
        payload.title = title
    else
        vim.notify_once("failed to annotate message: " .. title, vim.log.levels.ERROR)
    end

    for _, field in pairs(message:fields()) do
        if field.tag_text then
            local ok_tag, tag_text = pcall(opts.annotate.tag.formatter, field)
            if not ok_tag then
                vim.notify_once("failed to annotate field: " .. tag_text, vim.log.levels.ERROR)
            elseif tag_text then
                payload.marks[#payload.marks + 1] = { col = field.tag_end, virt_text = tag_text, kind = "tag" }
            end
        end
        if field.value_text then
            local ok_value, value_text = pcall(opts.annotate.value.formatter, field)
            if not ok_value then
                vim.notify_once("failed to annotate field: " .. value_text, vim.log.levels.ERROR)
            elseif value_text then
                payload.marks[#payload.marks + 1] = { col = field.value_end, virt_text = value_text, kind = "value" }
            end
        end
    end

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

--- Apply a payload to one line: point-clear, then set extmarks filtered by
--- the enabled flags. All marks of a message (including the title for
--- position="below") anchor on the message line itself, so the point-clear
--- can never orphan anything.
---@param opts FixOpts
---@param bufnr number
---@param ns_id number
---@param lnum number 0-based
---@param payload FixRenderPayload|nil
function M.apply(opts, bufnr, ns_id, lnum, payload)
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, lnum, lnum + 1)
    if payload == nil then
        return
    end

    if opts.annotate.message.enabled and payload.title then
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum, 0, {
            virt_lines = payload.title,
            virt_lines_above = opts.annotate.message.position == "above",
        })
    end

    for _, mark in ipairs(payload.marks) do
        local enabled = (mark.kind == "tag" and opts.annotate.tag.enabled)
            or (mark.kind == "value" and opts.annotate.value.enabled)
        if enabled then
            vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum, mark.col, {
                virt_text = { mark.virt_text },
                virt_text_pos = "inline",
            })
        end
    end
end

return M
