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

T["load version"]["loads message defs from Messages.xml"] = function(version)
    local dict = Dictionary.load(version)
    -- Older repositories name MsgType D "OrderSingle", newer "NewOrderSingle".
    local def = dict:message_def("D")
    MiniTest.expect.equality(def.name:find("OrderSingle", 1, true) ~= nil, true)
    MiniTest.expect.equality(#def.description > 0, true)
    MiniTest.expect.equality(dict:message_def("ZZZZ"), nil)
    -- The enum sugar keeps working alongside the new accessor.
    MiniTest.expect.equality(dict:message("0").name, "Heartbeat")
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

-- These tests mutate the module-level custom-dictionary registry via
-- Dictionary.apply(); restore it afterwards so later cases keep seeing
-- bundled defaults.
local function with_clean_registry(fn)
    local saved_custom, saved_names = Dictionary._custom, Dictionary._names
    local ok, err = pcall(fn)
    Dictionary._custom, Dictionary._names = saved_custom, saved_names
    Dictionary.clear_cache()
    Dictionary._fingerprint = nil
    if not ok then
        error(err, 0)
    end
end

T["named dictionaries: two names share one FIX version"] = function()
    with_clean_registry(function()
        local registries = Dictionary.prepare({
            {
                path = "xml/custom/binance/spot-fix-oe.xml",
                mode = "quickfix",
                name = "binance-oe",
                version = "FIX.9.1",
            },
            {
                path = "xml/custom/coinbase/order-entry/FIX42-prod-sand.xml",
                mode = "quickfix",
                name = "coinbase-oe",
                version = "FIX.9.1",
            },
        })
        MiniTest.expect.equality(registries.by_version["FIX.9.1"], nil)
        Dictionary.apply(registries)

        local binance = Dictionary.named("binance-oe")
        local coinbase = Dictionary.named("coinbase-oe")
        MiniTest.expect.equality(binance.version, "FIX.9.1")
        MiniTest.expect.equality(coinbase.version, "FIX.9.1")
        MiniTest.expect.equality(binance.key ~= coinbase.key, true)

        local binance_dict = Dictionary.load_from(binance)
        local coinbase_dict = Dictionary.load_from(coinbase)
        MiniTest.expect.equality(binance_dict:field(25035).name, "MessageHandling")
        MiniTest.expect.equality(coinbase_dict:field(7928).name, "SelfTradePrevention")
    end)
end

T["named dictionaries: name-only entry does not become the default"] = function()
    with_clean_registry(function()
        local registries = Dictionary.prepare({
            "xml/custom/binance/spot-fix-oe.xml",
            { path = "xml/custom/binance/spot-fix-md.xml", name = "binance-md" },
        })
        MiniTest.expect.equality(registries.by_version["FIX.4.4"] ~= nil, true)
        MiniTest.expect.equality(registries.by_name["binance-md"] ~= nil, true)
        Dictionary.apply(registries)

        MiniTest.expect.equality(Dictionary.has_version("FIX.4.4"), true)
        local default_dict = Dictionary.load("FIX.4.4")
        MiniTest.expect.equality(default_dict:field(11).name, "ClOrdID")

        local named_dict = Dictionary.load_from(Dictionary.named("binance-md"))
        MiniTest.expect.equality(rawequal(default_dict, named_dict), false)
        MiniTest.expect.equality(named_dict:field(11), nil)
    end)
end

T["named dictionaries: duplicate name errors"] = function()
    local ok, err = pcall(Dictionary.prepare, {
        {
            path = "xml/custom/binance/spot-fix-oe.xml",
            mode = "quickfix",
            name = "dup",
            version = "FIX.9.1",
        },
        {
            path = "xml/custom/coinbase/order-entry/FIX42-prod-sand.xml",
            mode = "quickfix",
            name = "dup",
            version = "FIX.9.2",
        },
    })
    MiniTest.expect.equality(ok, false)
    MiniTest.expect.equality(err:find("duplicate dictionary name", 1, true) ~= nil, true)
end

T["named dictionaries: name equal to a FIX version string errors"] = function()
    local ok, err = pcall(Dictionary.prepare, {
        { path = "xml/custom/binance/spot-fix-oe.xml", mode = "quickfix", name = "FIX.4.4" },
    })
    MiniTest.expect.equality(ok, false)
    MiniTest.expect.equality(err:find("collides with a FIX version", 1, true) ~= nil, true)
end

T["named dictionaries: name equal to a bundled-only version string errors"] = function()
    local ok, err = pcall(Dictionary.prepare, {
        { path = "xml/custom/binance/spot-fix-oe.xml", mode = "quickfix", name = "FIX.5.0SP1" },
    })
    MiniTest.expect.equality(ok, false)
    MiniTest.expect.equality(err:find("collides with a FIX version", 1, true) ~= nil, true)
end

T["apply: reapplying an identical two-index registry returns false"] = function()
    with_clean_registry(function()
        local spec = {
            "xml/custom/binance/spot-fix-oe.xml",
            { path = "xml/custom/binance/spot-fix-md.xml", name = "binance-md" },
        }
        MiniTest.expect.equality(Dictionary.apply(Dictionary.prepare(spec)), true)
        MiniTest.expect.equality(Dictionary.apply(Dictionary.prepare(spec)), false)
    end)
end

T["apply: a change confined to by_name returns true"] = function()
    with_clean_registry(function()
        local base = Dictionary.prepare({
            {
                path = "xml/custom/binance/spot-fix-oe.xml",
                mode = "quickfix",
                name = "binance-oe",
                version = "FIX.9.1",
            },
        })
        Dictionary.apply(base)

        local with_extra_name = Dictionary.prepare({
            {
                path = "xml/custom/binance/spot-fix-oe.xml",
                mode = "quickfix",
                name = "binance-oe",
                version = "FIX.9.1",
            },
            {
                path = "xml/custom/coinbase/order-entry/FIX42-prod-sand.xml",
                mode = "quickfix",
                name = "coinbase-oe",
                version = "FIX.9.1",
            },
        })
        -- by_version is untouched by this change; only by_name gains an entry.
        MiniTest.expect.equality(vim.deep_equal(base.by_version, with_extra_name.by_version), true)
        MiniTest.expect.equality(Dictionary.apply(with_extra_name), true)
    end)
end

T["apply: a change confined to by_version returns true"] = function()
    with_clean_registry(function()
        local base = Dictionary.prepare({
            ["FIX.9.1"] = { path = "xml/custom/binance/spot-fix-oe.xml", mode = "quickfix" },
        })
        Dictionary.apply(base)

        local with_different_default = Dictionary.prepare({
            ["FIX.9.1"] = { path = "xml/custom/coinbase/order-entry/FIX42-prod-sand.xml", mode = "quickfix" },
        })
        -- by_name is empty in both; only by_version's default source changes.
        MiniTest.expect.equality(vim.deep_equal(base.by_name, with_different_default.by_name), true)
        MiniTest.expect.equality(Dictionary.apply(with_different_default), true)
    end)
end

return T
