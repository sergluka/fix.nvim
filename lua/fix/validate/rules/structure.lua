--- Whether the line is a FIX message at all.
---
--- The grammar parses any run of `tag=value` pairs, so a log can hold fragments
--- — a dumped repeating group, a truncated line — that the other rules can say
--- nothing useful about. Being tier 0, this one runs first and silences them.

local Consts = require("fix.consts")

local FixTag = Consts.FixTag

local M = {}

M.begin_string = {
    id = "begin_string",
    name = "BeginString",
    severity = vim.diagnostic.severity.WARN,
    tier = 0,
    check = function(ctx)
        if ctx.message:field(FixTag.BeginString).tag ~= nil then
            return nil
        end

        local fields = ctx.message:list_fields()
        if #fields == 0 then
            return nil
        end
        return {
            {
                col = fields[1].tag_start,
                end_col = fields[#fields].value_end,
                message = string.format("Not a FIX message: missing BeginString (tag %d)", FixTag.BeginString),
            },
        }
    end,
}

return M
