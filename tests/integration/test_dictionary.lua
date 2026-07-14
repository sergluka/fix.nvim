local MiniTest = require("mini.test")

-- Dictionary.load() calls vim.notify at DEBUG level. Stub it for the spec
-- so stdout stays clean.
local _orig_notify = vim.notify
local _orig_notify_once = vim.notify_once

local T = MiniTest.new_set({
    hooks = {
        pre_once = function()
            vim.notify = function() end
            vim.notify_once = function() end
        end,
        post_once = function()
            vim.notify = _orig_notify
            vim.notify_once = _orig_notify_once
        end,
    },
})

local Dictionary = require("fix.dictionary")

local versions =
    { "FIX.4.0", "FIX.4.1", "FIX.4.2", "FIX.4.3", "FIX.4.4", "FIX.5.0", "FIX.5.0SP1", "FIX.5.0SP2", "FIXT.1.1" }

T["load version"] = MiniTest.new_set({
    parametrize = vim.tbl_map(function(v)
        return { v }
    end, versions),
})

T["load version"]["resolves BeginString and Heartbeat"] = function(version)
    local dict = Dictionary.load(version)
    MiniTest.expect.equality(dict:field(8).name, "BeginString")
    MiniTest.expect.equality(dict:message("0").name, "Heartbeat")
end

T["load version"]["loads repository group structure"] = function(version)
    local dict = Dictionary.load(version)
    local count = 0
    for _, groups in pairs(dict._groups or {}) do
        if not vim.tbl_isempty(groups) then
            count = count + 1
        end
    end
    MiniTest.expect.equality(count > 0, true)
end

T["FIXT.1.1 resolves to FIX.5.0SP2 dictionary"] = function()
    local fixt = Dictionary.load("FIXT.1.1")
    local sp2 = Dictionary.load("FIX.5.0SP2")
    MiniTest.expect.equality(rawequal(fixt, sp2), true)
end

T["has_version checks bundled dictionaries and aliases"] = function()
    MiniTest.expect.equality(Dictionary.has_version("FIX.5.0"), true)
    MiniTest.expect.equality(Dictionary.has_version("FIX.5.0SP2"), true)
    MiniTest.expect.equality(Dictionary.has_version("FIXT.1.1"), true)
    MiniTest.expect.equality(Dictionary.has_version("FIX.9.9"), false)
end

T["second load returns same instance"] = function()
    local first = Dictionary.load("FIX.4.4")
    local second = Dictionary.load("FIX.4.4")
    MiniTest.expect.equality(rawequal(first, second), true)
end

T["unknown tag returns nil"] = function()
    local dict = Dictionary.load("FIX.4.4")
    MiniTest.expect.equality(dict:field(99999), nil)
end

T["unknown enum returns nil"] = function()
    local dict = Dictionary.load("FIX.4.4")
    MiniTest.expect.equality(dict:enum(35, "ZZZZ"), nil)
end

return T
