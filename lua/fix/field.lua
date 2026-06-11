---@class Field
---@field index number
---@field tag number
---@field tag_text string
---@field tag_start number
---@field tag_end number
---@field value string
---@field value_text string
---@field value_start number
---@field value_end number
---@field _extmark_tag_id? integer?
---@field _extmark_value_id? integer?
local M = {}

function M.new(o)
    setmetatable(o, { __index = M })
    o._extmark_tag_id = nil
    o._extmark_value_id = nil
    return o
end

---@return Field
function M.empty()
    return {
        index = nil,
        tag = nil,
        tag_text = nil,
        tag_start = nil,
        tag_end = nil,
        value = nil,
        value_text = nil,
        value_start = nil,
        value_end = nil,
    }
end

---@param bufnr number
---@param ns_id number
function M:clear(ns_id, bufnr)
    if self._extmark_tag_id then
        vim.api.nvim_buf_del_extmark(bufnr, ns_id, self._extmark_tag_id)
        self._extmark_tag_id = nil
    end
    if self._extmark_value_id then
        vim.api.nvim_buf_del_extmark(bufnr, ns_id, self._extmark_value_id)
        self._extmark_value_id = nil
    end
end

return M
