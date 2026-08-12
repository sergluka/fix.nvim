local Consts = require("fix.consts")

local M = {}
local FixTag = Consts.FixTag

local KEY_SEP = "\31"
local UNKNOWN = "???"

---@class FixRoute
---@field sender string
---@field target string

---@class FixRouteRule
---@field sender? string
---@field target? string
---@field highlight string

---@param message Message
---@return FixRoute
function M.get(message)
    return {
        sender = message:field(FixTag.SenderCompID).value or UNKNOWN,
        target = message:field(FixTag.TargetCompID).value or UNKNOWN,
    }
end

---@param route FixRoute
---@param mode? string
---@return string
function M.key(route, mode)
    if mode == "sender" then
        return route.sender
    elseif mode == "pair" then
        if route.sender <= route.target then
            return route.sender .. KEY_SEP .. route.target
        end
        return route.target .. KEY_SEP .. route.sender
    end

    return route.sender .. KEY_SEP .. route.target
end

---@param expected string|nil
---@param actual string
---@return boolean
local function match_part(expected, actual)
    return expected == nil or expected == "*" or expected == actual
end

---@param expected string|nil
---@param actual string
---@return integer
local function match_score(expected, actual)
    if expected == actual then
        return 1
    end
    return 0
end

---@param route FixRoute
---@param rules FixRouteRule[]|nil
---@return string|nil
local function match_override(route, rules)
    local best_highlight = nil
    local best_score = -1

    for _, rule in ipairs(rules or {}) do
        if match_part(rule.sender, route.sender) and match_part(rule.target, route.target) then
            local score = match_score(rule.sender, route.sender) + match_score(rule.target, route.target)
            if score > best_score then
                best_score = score
                best_highlight = rule.highlight
            end
        end
    end

    return best_highlight
end

---@param key string
---@param palette string[]
---@return string
local function hash_highlight(key, palette)
    if #palette == 0 then
        return "Title"
    end

    local hash = vim.fn.sha256(key)
    local value = tonumber(hash:sub(1, 8), 16) or 0
    return palette[(value % #palette) + 1]
end

---@param message Message
---@param opts? FixOpts
---@return string
function M.highlight(message, opts)
    opts = opts or require("fix").opts
    local route_opts = opts and opts.annotate and opts.annotate.title and opts.annotate.title.route or nil

    if not route_opts or route_opts.enabled == false then
        return "Title"
    end

    local route = M.get(message)
    local override = match_override(route, route_opts.overrides)
    if override then
        return override
    end

    if route_opts.resolver then
        local ok, resolved = pcall(route_opts.resolver, route, message)
        if ok and type(resolved) == "string" and resolved ~= "" then
            return resolved
        elseif not ok then
            vim.notify_once("fix.nvim: route highlight resolver failed: " .. resolved, vim.log.levels.ERROR)
        elseif resolved ~= nil then
            vim.notify_once("fix.nvim: route highlight resolver must return a highlight group", vim.log.levels.ERROR)
        end
    end

    return hash_highlight(M.key(route, route_opts.mode), route_opts.palette or {})
end

return M
