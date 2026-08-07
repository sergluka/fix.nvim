--- Rule registry.
---
--- A rule inspects one parsed message and returns diagnostics, each of which
--- may carry the fixes that repair it. Rules come from three places, later
--- ones overriding earlier ones by id: built-ins, `lsp.validate.rules` in setup,
--- and `require("fix.validate").register(...)` at runtime. Only registered
--- rules survive a re-setup; the configured ones are rebuilt from the options.
---
--- Rules run in tiers, lowest first, and a tier that reports anything stops the
--- ones below it: once a line turns out not to be a FIX message there is
--- nothing worth saying about its BodyLength. Tier 0 holds the built-in
--- structural checks; everything else defaults to tier 1.
---
--- Only message scope exists today. Session-level rules (the FIX Volume 2 test
--- cases: MsgSeqNum continuity, logon sequencing, resend and gap fill) need to
--- see an ordered stream instead of a single line, so they will declare
--- `scope = "session"` and supply `init`/`on_message`/`finish` in place of
--- `check`. Everything below is already bucketed by scope so that lands as an
--- addition rather than a change.

local Integrity = require("fix.validate.rules.integrity")
local Structure = require("fix.validate.rules.structure")

local M = {}

---@class FixRule
---@field id string
---@field name? string
---@field scope? "message"
---@field severity? vim.diagnostic.Severity  defaults to ERROR
---@field tier? number  lowest tier runs first; defaults to 1
---@field check fun(ctx: FixRuleCtx): FixRuleDiagnostic[]|nil

--- An `lsp.validate.rules` entry: settings for a built-in rule when `check` is
--- omitted, a rule definition when it is present (the id is the map key).
---@class FixRuleSpec
---@field enabled? boolean
---@field name? string
---@field scope? "message"
---@field severity? vim.diagnostic.Severity
---@field tier? number
---@field check? fun(ctx: FixRuleCtx): FixRuleDiagnostic[]|nil

---@class FixRuleCtx
---@field buf number
---@field lnum number             0-based
---@field line string             raw line text
---@field message Message
---@field scratch table           per-line scratch; key it by your rule id
---@field opts table              the `lsp.validate` options block

---@class FixRuleDiagnostic
---@field col number              0-based byte column
---@field end_col number          0-based, end-exclusive
---@field message string
---@field severity? vim.diagnostic.Severity
---@field code? string            defaults to the rule id
---@field fixes? FixFix[]

---@class FixFix
---@field title string
---@field edits FixEdit[]|fun(ctx: FixRuleCtx): FixEdit[]

---@class FixEdit
---@field lnum? number            defaults to the diagnostic's line
---@field col number
---@field end_col number          equal to `col` for an insertion
---@field new_text string

local SCOPES = { message = true }

local BUILTINS = { Structure.begin_string, Integrity.body_length, Integrity.checksum }

local builtin_ids = {}
for _, rule in ipairs(BUILTINS) do
    builtin_ids[rule.id] = true
end

local registered = {} ---@type FixRule[] added by M.register; survive a re-setup
local configured = {} ---@type FixRule[] built from lsp.validate.rules
local settings = {} ---@type table<string, boolean|table>
local active = nil ---@type table<string, FixRule[]>|nil

---@param id string
---@return boolean
local function is_builtin(id)
    return builtin_ids[id] == true
end

--- Describe what is wrong with a rule definition, or nil when it is fine.
---@param id string
---@param entry any
---@param where? string label used in the message; defaults to the option path
---@return string|nil
function M.problem(id, entry, where)
    where = where or ("lsp.validate.rules." .. tostring(id))
    if type(entry) == "boolean" then
        return nil
    end
    if type(entry) ~= "table" then
        return where .. " must be a boolean or a table"
    end
    if entry.enabled ~= nil and type(entry.enabled) ~= "boolean" then
        return where .. ".enabled must be a boolean"
    end
    if entry.severity ~= nil and type(entry.severity) ~= "number" then
        return where .. ".severity must be a vim.diagnostic.severity value"
    end
    if entry.check == nil then
        if not is_builtin(id) then
            return where .. " is not a built-in rule, so it must define a check function"
        end
        return nil
    end
    if type(entry.check) ~= "function" then
        return where .. ".check must be a function"
    end
    if entry.tier ~= nil and type(entry.tier) ~= "number" then
        return where .. ".tier must be a number"
    end
    if entry.scope == "session" then
        return where .. ": scope 'session' is not supported yet"
    end
    if entry.scope ~= nil and not SCOPES[entry.scope] then
        return where .. ".scope must be 'message'"
    end
    return nil
end

---@param rule FixRule
---@return FixRule
local function resolve(rule)
    local entry = settings[rule.id]
    local severity = rule.severity
    if type(entry) == "table" and entry.severity ~= nil then
        severity = entry.severity
    end
    return {
        id = rule.id,
        name = rule.name or rule.id,
        check = rule.check,
        scope = rule.scope or "message",
        severity = severity or vim.diagnostic.severity.ERROR,
        tier = rule.tier or 1,
    }
end

---@param id string
---@return boolean
local function is_enabled(id)
    local entry = settings[id]
    if entry == false then
        return false
    end
    if type(entry) == "table" and entry.enabled == false then
        return false
    end
    return true
end

local function rebuild()
    active = { message = {} }
    local seen = {}
    local ordered = {}
    for _, source in ipairs({ BUILTINS, configured, registered }) do
        for _, rule in ipairs(source) do
            local at = seen[rule.id]
            if at then
                ordered[at] = rule
            else
                ordered[#ordered + 1] = rule
                seen[rule.id] = #ordered
            end
        end
    end
    -- table.sort is not stable, so registration order breaks ties explicitly;
    -- `seen` already maps each id to its position in `ordered`.
    table.sort(ordered, function(lhs, rhs)
        local lhs_tier, rhs_tier = lhs.tier or 1, rhs.tier or 1
        if lhs_tier ~= rhs_tier then
            return lhs_tier < rhs_tier
        end
        return seen[lhs.id] < seen[rhs.id]
    end)

    for _, rule in ipairs(ordered) do
        if is_enabled(rule.id) then
            local resolved = resolve(rule)
            local bucket = active[resolved.scope]
            if bucket then
                bucket[#bucket + 1] = resolved
            end
        end
    end
end

--- Rebuild the registry from the `lsp.validate.rules` option block.
---@param config? table<string, boolean|table>
function M.reset(config)
    settings = {}
    configured = {}
    local ids = {}
    for id, entry in pairs(config or {}) do
        settings[id] = entry
        ids[#ids + 1] = id
    end
    -- pairs() order is arbitrary; diagnostics should not reshuffle between runs.
    table.sort(ids)
    for _, id in ipairs(ids) do
        local entry = settings[id]
        if type(entry) == "table" and type(entry.check) == "function" then
            configured[#configured + 1] = vim.tbl_extend("force", entry, { id = id })
        end
    end
    active = nil
end

--- Add or replace a rule at runtime. Registered rules outlive `setup()`.
---@param rule FixRule
---@return FixRule
function M.register(rule)
    if type(rule) ~= "table" or type(rule.id) ~= "string" or rule.id == "" then
        error("fix.nvim: a validation rule needs a non-empty string id", 2)
    end
    if type(rule.check) ~= "function" then
        error("fix.nvim: rule '" .. rule.id .. "' must define a check function", 2)
    end
    local problem = M.problem(rule.id, rule, "rule '" .. rule.id .. "'")
    if problem then
        error("fix.nvim: " .. problem, 2)
    end

    for i, existing in ipairs(registered) do
        if existing.id == rule.id then
            registered[i] = rule
            active = nil
            return rule
        end
    end
    registered[#registered + 1] = rule
    active = nil
    return rule
end

--- Enabled rules of a scope, lowest tier first.
---@param scope "message"
---@return FixRule[]
function M.active(scope)
    if not active then
        rebuild()
    end
    return active[scope] or {}
end

return M
