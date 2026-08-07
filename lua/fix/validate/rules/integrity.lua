--- BodyLength (tag 9) and CheckSum (tag 10) integrity.
---
--- Both quantities are derived from field spans rather than the raw line, so
--- whatever byte separates the fields in the log (`|`, `^` or a real SOH) is
--- counted as the single SOH the FIX specification assumes. Anything the
--- grammar left outside the fields — a log prefix, trailing noise — is ignored.

local Consts = require("fix.consts")

local FixTag = Consts.FixTag
local byte = string.byte

local M = {}

-- Every field contributes one separator to both sums.
local SEPARATOR = 1

local SEPARATORS = { ["\1"] = true, ["|"] = true, ["^"] = true }

---@param s string
---@param from number 1-based inclusive
---@param to number 1-based inclusive
---@return number
local function byte_sum(s, from, to)
    local sum = 0
    for i = from, to do
        sum = sum + byte(s, i)
    end
    return sum
end

---@param s string
---@return number
local function str_sum(s)
    return byte_sum(s, 1, #s)
end

--- The byte the log uses between fields; needed when a fix inserts one.
---@param line string
---@param fields Field[]
---@return string
local function separator_of(line, fields)
    for i = 1, #fields - 1 do
        local at = fields[i].value_end + 1
        if fields[i + 1].tag_start - fields[i].value_end == 1 and SEPARATORS[line:sub(at, at)] then
            return line:sub(at, at)
        end
    end
    local at = fields[#fields].value_end + 1
    local tail = line:sub(at, at)
    return SEPARATORS[tail] and tail or "|"
end

---@class FixIntegrityPlan
---@field fields Field[]
---@field i8? number
---@field i9? number
---@field i10? number
---@field body_length number    expected BodyLength
---@field checksum string       expected CheckSum, always three digits
---@field fix? FixFix           canonical repair, shared by both rules; nil when nothing to repair

---@param ctx FixRuleCtx
---@return FixIntegrityPlan|nil
local function build(ctx)
    local line = ctx.line
    local fields = ctx.message:list_fields()
    if #fields < 2 then
        return nil
    end

    local i8, i9, i10
    for i, field in ipairs(fields) do
        local tag = field.tag
        if tag == FixTag.BeginString then
            i8 = i8 or i
        elseif tag == FixTag.BodyLength then
            i9 = i9 or i
        elseif tag == FixTag.CheckSum then
            i10 = i10 or i
        end
    end

    -- Where the body starts: after BodyLength, or where BodyLength belongs.
    local body_first = (i9 or i8 or 0) + 1
    if not i9 and not fields[body_first] then
        -- Nothing to anchor an inserted BodyLength on; too broken to reason about.
        return nil
    end

    -- Both sums stop at the field before tag 10 (or run to the end when it is absent).
    local body_end = (i10 or (#fields + 1)) - 1

    local body_length = 0
    for i = body_first, body_end do
        local field = fields[i]
        body_length = body_length + (field.value_end - field.tag_start) + SEPARATOR
    end
    local body_text = tostring(body_length)

    -- CheckSum covers everything up to the separator before tag 10, with the
    -- corrected BodyLength substituted in: a message whose BodyLength is wrong
    -- has no meaningful checksum other than the one it will have once repaired.
    local missing_9_bytes = 0
    if not i9 then
        missing_9_bytes = str_sum("9=") + str_sum(body_text) + SEPARATOR
    end
    local sum = 0
    for i = 1, body_end do
        if i == body_first then
            sum = sum + missing_9_bytes
        end
        local field = fields[i]
        if i == i9 then
            sum = sum + byte_sum(line, field.tag_start + 1, field.value_start) + str_sum(body_text)
        else
            sum = sum + byte_sum(line, field.tag_start + 1, field.value_end)
        end
        sum = sum + SEPARATOR
    end
    if body_first > body_end then
        sum = sum + missing_9_bytes
    end
    local checksum = ("%03d"):format(sum % 256)

    local separator = separator_of(line, fields)
    local edits, repaired = {}, {}

    local field_9 = i9 and fields[i9]
    if not field_9 then
        local anchor = fields[body_first]
        edits[#edits + 1] = {
            col = anchor.tag_start,
            end_col = anchor.tag_start,
            new_text = "9=" .. body_text .. separator,
        }
        repaired[#repaired + 1] = "BodyLength"
    elseif tonumber(field_9.value) ~= body_length then
        edits[#edits + 1] = { col = field_9.value_start, end_col = field_9.value_end, new_text = body_text }
        repaired[#repaired + 1] = "BodyLength"
    end

    local field_10 = i10 and fields[i10]
    if not field_10 then
        -- Append after the trailing separator when the line has one, mirroring it,
        -- so `...|52=X|` becomes `...|52=X|10=NNN|` and `...|52=X` gains its own.
        local after_last = fields[#fields].value_end
        local trailing = line:sub(after_last + 1, after_last + 1)
        if SEPARATORS[trailing] then
            edits[#edits + 1] = {
                col = after_last + 1,
                end_col = after_last + 1,
                new_text = "10=" .. checksum .. trailing,
            }
        else
            edits[#edits + 1] = {
                col = after_last,
                end_col = after_last,
                new_text = separator .. "10=" .. checksum,
            }
        end
        repaired[#repaired + 1] = "CheckSum"
    elseif field_10.value ~= checksum then
        edits[#edits + 1] = { col = field_10.value_start, end_col = field_10.value_end, new_text = checksum }
        repaired[#repaired + 1] = "CheckSum"
    end

    return {
        fields = fields,
        i8 = i8,
        i9 = i9,
        i10 = i10,
        body_length = body_length,
        checksum = checksum,
        fix = #edits > 0 and { title = "Fix " .. table.concat(repaired, " and "), edits = edits } or nil,
    }
end

--- Both rules see the same line; the second one reuses the first one's work.
---@param ctx FixRuleCtx
---@return FixIntegrityPlan|nil
local function plan(ctx)
    local cached = ctx.scratch.integrity
    if cached == nil then
        cached = build(ctx) or false
        ctx.scratch.integrity = cached
    end
    return cached or nil
end

---@param p FixIntegrityPlan
---@return FixFix[]|nil
local function fixes_of(p)
    return p.fix and { p.fix } or nil
end

--- The shared diagnostic shape of both rules: a missing tag is anchored on
--- `anchor`, a wrong value on its own value span.
---@param p FixIntegrityPlan
---@param field Field|nil
---@param anchor Field
---@param name string
---@param tag number
---@param expected string
---@param matches boolean
---@return FixRuleDiagnostic[]|nil
local function report(p, field, anchor, name, tag, expected, matches)
    if not field then
        return {
            {
                col = anchor.tag_start,
                end_col = anchor.value_end,
                message = string.format("Missing %s (tag %d)", name, tag),
                fixes = fixes_of(p),
            },
        }
    end
    if matches then
        return nil
    end
    return {
        {
            col = field.value_start,
            end_col = field.value_end,
            message = string.format("%s is %s, expected %s", name, field.value, expected),
            fixes = fixes_of(p),
        },
    }
end

M.body_length = {
    id = "body_length",
    name = "BodyLength",
    check = function(ctx)
        local p = plan(ctx)
        if not p then
            return nil
        end
        local field = p.i9 and p.fields[p.i9] or nil
        local matches = field ~= nil and tonumber(field.value) == p.body_length
        return report(p, field, p.fields[p.i8 or 1], "BodyLength", FixTag.BodyLength, tostring(p.body_length), matches)
    end,
}

M.checksum = {
    id = "checksum",
    name = "CheckSum",
    check = function(ctx)
        local p = plan(ctx)
        if not p then
            return nil
        end
        local field = p.i10 and p.fields[p.i10] or nil
        local matches = field ~= nil and field.value == p.checksum
        return report(p, field, p.fields[#p.fields], "CheckSum", FixTag.CheckSum, p.checksum, matches)
    end,
}

return M
