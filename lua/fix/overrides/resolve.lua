--- Layer reads and value resolution: turns a raw layer value into a typed,
--- validated override, warning on the way if it can't.

local Dictionary = require("fix.dictionary")
local Spec = require("fix.overrides.spec")

local M = {}

local function fix()
    return require("fix")
end

---@class FixOverrideResolved
---@field value any
---@field layer "modeline"|"vim.b"|"editorconfig"|"vim.g"
---@field kind? "boolean"|"enum"|"dictionary"|"formatter"  set only on M.describe's output

-- Warnings ---------------------------------------------------------------

---@param warnings table[]
---@param buf number
---@param layer string
---@param key string
---@param value any
---@param reason string
function M.record_warning(warnings, buf, layer, key, value, reason)
    local text = string.format(
        "fix.nvim: buffer %d %s override %s%s: %s",
        buf,
        layer,
        key,
        value ~= nil and ("=" .. tostring(value)) or "",
        reason
    )
    vim.notify_once(text, vim.log.levels.WARN)
    warnings[#warnings + 1] = { layer = layer, key = key, value = value, message = reason, text = text }
end

-- Layer reads --------------------------------------------------------------

---@param entry FixOverrideSpecEntry
---@param layer string
---@param buf number
---@param state FixOverrideState
---@return any raw, boolean present
local function layer_raw(entry, layer, buf, state)
    if layer == "modeline" then
        local raw = state.modeline_pairs[entry.path]
        return raw, raw ~= nil
    elseif layer == "vim.b" then
        local flat = vim.b[buf][entry.var]
        if flat ~= nil then
            return flat, true
        end
        local nested = vim.tbl_get(vim.b[buf].fix or {}, unpack(entry.parts))
        return nested, nested ~= nil
    elseif layer == "editorconfig" then
        local ec = vim.b[buf].editorconfig
        if type(ec) == "table" then
            local raw = ec[entry.var]
            return raw, raw ~= nil
        end
        return nil, false
    elseif layer == "vim.g" then
        local flat = vim.g[entry.var]
        if flat ~= nil then
            return flat, true
        end
        local nested = vim.tbl_get(vim.g.fix or {}, unpack(entry.parts))
        return nested, nested ~= nil
    end
    return nil, false
end

--- "true"/"false" -> boolean, "unset" -> absent, anything else passes through
--- for kind-specific validation. Nvim lowercases editorconfig values, so a
--- mixed-case formatter or dictionary name simply won't match.
---@param raw string
---@return any value, boolean present
local function text_coerce(raw)
    if raw == "true" then
        return true, true
    end
    if raw == "false" then
        return false, true
    end
    if raw == "unset" then
        return nil, false
    end
    return raw, true
end

-- Kind resolution ------------------------------------------------------

---@param layer string
---@return boolean
local function file_borne(layer)
    return layer == "modeline" or layer == "editorconfig"
end

---@param raw any
---@param layer string
---@return boolean ok, any value_or_reason
local function resolve_dictionary_value(raw, layer)
    if type(raw) ~= "string" or raw == "" then
        return false, "must be a non-empty string"
    end

    local named = Dictionary.named(raw)
    if named then
        return true, { source = named, name = raw }
    end

    -- A path from a file-borne layer is chosen by whoever wrote the log, and
    -- resolving it parses whatever it names, synchronously: a huge file or a
    -- FIFO hangs the editor, an automount path reaches the network, and a
    -- dictionary shipped beside the log can redefine tag and enum semantics.
    -- Hence opt-in; names resolve against the user's own setup() instead.
    if file_borne(layer) and not fix().opts.overrides.modeline.allow_paths then
        return false,
            string.format(
                "not a registered dictionary name; set overrides.modeline.allow_paths=true to use a path from %s",
                layer
            )
    end

    local ok, result = pcall(Dictionary.prepare_source, raw)
    if not ok then
        return false, string.format("could not load %q: %s", raw, tostring(result))
    end
    return true, { source = result, name = nil }
end

---@param entry FixOverrideSpecEntry
---@param raw any
---@return boolean ok, any value_or_reason
local function resolve_formatter_value(entry, raw)
    if type(raw) ~= "string" or raw == "" then
        return false, "must be a formatter name"
    end
    local resolved_fn = fix().resolve_formatter(entry.namespace, raw)
    if not resolved_fn then
        return false, string.format("unknown formatter %q", raw)
    end
    return true, { name = raw, fn = resolved_fn }
end

---@param entry FixOverrideSpecEntry
---@param value any
---@param layer string
---@return boolean ok, any value_or_reason
function M.resolve_value(entry, value, layer)
    if entry.kind == "boolean" then
        if type(value) ~= "boolean" then
            return false, string.format("must be true/false, got %s", vim.inspect(value))
        end
        return true, value
    elseif entry.kind == "enum" then
        if type(value) ~= "string" or not vim.tbl_contains(entry.values, value) then
            return false,
                string.format("must be one of %s, got %s", table.concat(entry.values, "|"), vim.inspect(value))
        end
        return true, value
    elseif entry.kind == "dictionary" then
        return resolve_dictionary_value(value, layer)
    elseif entry.kind == "formatter" then
        return resolve_formatter_value(entry, value)
    end
    return false, "unsupported kind"
end

--- Early rejection for the editorconfig property callbacks. `nil` accepts; a
--- string is the reason to `error(reason, 0)` with, matching how Nvim's own
--- properties surface bad values.
---
--- A dictionary value gets only a type check, never `resolve_value`: Nvim
--- invokes the callback for every buffer matching the glob regardless of
--- filetype, so a path under `[*]` would otherwise parse its XML for each
--- one. The authoritative read in `resolve_entry` still validates fully.
---@param var string
---@param raw string
---@return string? reason
function M.validate_editorconfig(var, raw)
    local entry = Spec.SPEC_BY_VAR[var]
    if not entry then
        return nil
    end
    local value, present = text_coerce(raw)
    if not present then
        return nil
    end
    if entry.kind == "dictionary" then
        if type(value) ~= "string" or value == "" then
            return "must be a non-empty string"
        end
        return nil
    end
    local ok, reason = M.resolve_value(entry, value, "editorconfig")
    if ok then
        return nil
    end
    return reason
end

---@param entry FixOverrideSpecEntry
---@param buf number
---@param state FixOverrideState
---@param warnings table[]
---@param layers string[]
---@return FixOverrideResolved|nil
function M.resolve_entry(entry, buf, state, warnings, layers)
    for _, layer in ipairs(layers) do
        local raw, present = layer_raw(entry, layer, buf, state)
        if present then
            local value = raw
            local usable = true
            if layer == "modeline" or layer == "editorconfig" then
                local coerced, is_present = text_coerce(raw)
                if is_present then
                    value = coerced
                else
                    usable = false -- "unset": treat as absent, fall through
                end
            end
            if usable then
                local ok, result = M.resolve_value(entry, value, layer)
                if ok then
                    return { value = result, layer = layer }
                end
                M.record_warning(warnings, buf, layer, entry.path, raw, result)
            end
        end
    end
    return nil
end

return M
