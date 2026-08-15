--- The cache-namespace suffix derived from content-affecting overrides, and
--- the diff between two resolutions.

local Dictionary = require("fix.dictionary")
local Spec = require("fix.overrides.spec")

local M = {}

-- Diffing ------------------------------------------------------------------

---@class FixOverrideRefreshResult
---@field changed boolean
---@field annotate boolean    an annotate.*/formatter.* key changed
---@field lsp boolean         an lsp.* key changed
---@field dictionary boolean  the dictionary override changed
---@field suffix boolean      the cache namespace suffix changed

---@param entry FixOverrideSpecEntry
---@param a any
---@param b any
---@return boolean
local function value_equal(entry, a, b)
    if entry.kind == "dictionary" then
        local ak = a and a.source and a.source.key
        local bk = b and b.source and b.source.key
        return ak == bk
    elseif entry.kind == "formatter" then
        local an, bn = a and a.name, b and b.name
        local af, bf = a and a.fn, b and b.fn
        return an == bn and af == bf
    end
    return a == b
end

---@param resolved_old table<string, FixOverrideResolved>
---@param resolved_new table<string, FixOverrideResolved>
---@return FixOverrideRefreshResult
function M.compute_diff(resolved_old, resolved_new)
    local diff = { changed = false, annotate = false, lsp = false, dictionary = false, suffix = false }
    for _, entry in ipairs(Spec.SPEC) do
        local old_e = resolved_old[entry.path]
        local new_e = resolved_new[entry.path]
        local same
        if (old_e == nil) ~= (new_e == nil) then
            same = false
        elseif old_e == nil then
            same = true
        else
            same = value_equal(entry, old_e.value, new_e.value)
        end
        if not same then
            diff.changed = true
            if entry.category == "annotate" then
                diff.annotate = true
            elseif entry.category == "lsp" then
                diff.lsp = true
            elseif entry.category == "dictionary" then
                diff.dictionary = true
            end
        end
    end
    return diff
end

-- Cache suffix ---------------------------------------------------------

---@param entry FixOverrideSpecEntry
---@param resolved FixOverrideResolved|nil
---@param dict_fp string|nil  precomputed Dictionary.source_fingerprint of the dictionary entry's source
---@return string
local function stable_part(entry, resolved, dict_fp)
    if not resolved then
        return entry.path .. ":-"
    end
    local value = resolved.value
    if entry.kind == "dictionary" then
        local source = value.source
        if source.tags then
            -- Lua tag decoders live in tostring(function): process-local identity.
            return entry.path .. ":deckey:" .. source.key
        end
        return string.format("%s:%s:%s:%s:%s", entry.path, value.name or "", source.version, source.path, dict_fp)
    elseif entry.kind == "formatter" then
        return entry.path .. ":" .. value.name
    end
    return entry.path .. ":" .. tostring(value)
end

---@param resolved table<string, FixOverrideResolved>
---@param dict_fp string|nil
---@return string|nil suffix, boolean persist_excluded
function M.compute_cache_suffix(resolved, dict_fp)
    local has_content = false
    local parts = {}
    for _, entry in ipairs(Spec.SPEC) do
        if entry.content then
            if resolved[entry.path] then
                has_content = true
            end
            parts[#parts + 1] = stable_part(entry, resolved[entry.path], dict_fp)
        end
    end
    if not has_content then
        return nil, false
    end

    local persist_excluded = false
    local dict_entry = resolved["dictionary"]
    if dict_entry and dict_entry.value.source.tags then
        persist_excluded = true
    end

    return ":" .. vim.fn.sha256(table.concat(parts, "|")):sub(1, 32), persist_excluded
end

--- `Dictionary._cache` is keyed by source.key alone and cannot see the XML
--- change on disk; evict when a live source's fingerprint moves.
---@param state FixOverrideState
---@param dict_entry FixOverrideResolved|nil
---@param fp string|nil  precomputed Dictionary.source_fingerprint of dict_entry's source
function M.check_dictionary_instance(state, dict_entry, fp)
    if not dict_entry then
        state.dictionary_fingerprint_key = nil
        state.dictionary_fingerprint = nil
        return
    end
    local source = dict_entry.value.source
    if state.dictionary_fingerprint_key == source.key and state.dictionary_fingerprint ~= fp then
        Dictionary.evict(source)
    end
    state.dictionary_fingerprint_key = source.key
    state.dictionary_fingerprint = fp
end

return M
