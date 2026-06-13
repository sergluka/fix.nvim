local Helpers = require("tests.integration.helpers")
local MiniTest = require("mini.test")

local T = Helpers.new_test_set()

-- Each case isolates persistence in a unique tmp dir inside the child.
local SETUP = [[
    _G._persist_dir = vim.fn.tempname()
    require("fix").setup({ cache = { persist = { dir = _G._persist_dir, max_files = 20 } } })
]]

local function cache_files(nvim)
    return nvim.lua_get([[vim.fn.globpath(_G._persist_dir, "*.mpack", false, true)]])
end

local function cache_names(nvim)
    return nvim.lua_get([[
        (function()
            local files = vim.fn.globpath(_G._persist_dir, "*.mpack", false, true)
            local names = {}
            for _, path in ipairs(files) do
                names[#names + 1] = vim.fn.fnamemodify(path, ":t")
            end
            table.sort(names)
            return names
        end)()
    ]])
end

T["persist"] = MiniTest.new_set()

T["persist"]["writes a cache file after warm-up"] = function()
    local nvim = Helpers.nvim()
    nvim.lua(SETUP)
    Helpers.load_fixture(nvim, "4.4.fix")
    local ok = Helpers.wait_for(nvim, [[#vim.fn.globpath(_G._persist_dir, "*.mpack", false, true) > 0]], 5000)
    MiniTest.expect.equality(ok, true)
end

T["persist"]["second session loads semantics from disk before warm-up"] = function()
    local nvim = Helpers.nvim()
    nvim.lua(SETUP)
    Helpers.load_fixture(nvim, "4.4.fix")
    Helpers.wait_for(nvim, [[#vim.fn.globpath(_G._persist_dir, "*.mpack", false, true) > 0]], 5000)
    local dir = nvim.lua_get("_G._persist_dir")
    -- fresh child sharing the persist dir
    local nvim2 = Helpers.new_nvim()
    nvim2.lua(string.format([[require("fix").setup({ cache = { persist = { dir = %q } } })]], dir))
    nvim2.cmd("edit tests/integration/fixtures/4.4.fix")
    -- load_into_cache runs synchronously inside attach: entries are present
    -- immediately after :edit, before warm-up could have computed them.
    -- Capture the result before stopping so nvim2 is never leaked on failure.
    local count_ok = nvim2.lua_get([[require("fix.cache")._count > 0]])
    nvim2.stop()
    MiniTest.expect.equality(count_ok, true)
end

T["persist"]["enabled=false writes nothing"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[
        _G._persist_dir = vim.fn.tempname()
        require("fix").setup({ cache = { persist = { enabled = false, dir = _G._persist_dir } } })
    ]])
    Helpers.load_fixture(nvim, "4.4.fix")
    Helpers.sleep(nvim, 300)
    MiniTest.expect.equality(#cache_files(nvim), 0)
end

T["persist"]["corrupt cache file is ignored silently"] = function()
    local nvim = Helpers.nvim()
    nvim.lua(SETUP)
    nvim.lua([[
        vim.fn.mkdir(_G._persist_dir, "p")
        local name = vim.fn.sha256(vim.fn.fnamemodify("tests/integration/fixtures/4.4.fix", ":p")):sub(1, 32)
        local f = io.open(_G._persist_dir .. "/" .. name .. ".mpack", "wb")
        f:write("garbage not mpack")
        f:close()
    ]])
    Helpers.load_fixture(nvim, "4.4.fix") -- still annotates fine
    Helpers.expect_no_error_notifications(nvim)
end

T["persist"]["stale dict fingerprint is discarded"] = function()
    local nvim = Helpers.nvim()
    nvim.lua(SETUP)
    nvim.lua([[
        vim.fn.mkdir(_G._persist_dir, "p")
        local name = vim.fn.sha256(vim.fn.fnamemodify("tests/integration/fixtures/4.4.fix", ":p")):sub(1, 32)
        local blob = vim.mpack.encode({
            format_version = 2,
            dict_fingerprint = "stale",
            fallback_version = "FIX.4.4",
            entries = { abc = { version = "FIX.4.4", fields = {} } },
        })
        local f = io.open(_G._persist_dir .. "/" .. name .. ".mpack", "wb")
        f:write(blob)
        f:close()
    ]])
    -- Wrap load_into_cache to capture _count right after it returns, before
    -- any warm-up tick can populate the cache.
    nvim.lua([[
        _G._count_after_load = nil
        local persist = require("fix.persist")
        local orig = persist.load_into_cache
        persist.load_into_cache = function(buf)
            orig(buf)
            _G._count_after_load = require("fix.cache")._count
        end
    ]])
    nvim.cmd("edit tests/integration/fixtures/4.4.fix")
    local ok = Helpers.wait_for(nvim, [[_G._count_after_load ~= nil]], 2000)
    MiniTest.expect.equality(ok, true)
    MiniTest.expect.equality(nvim.lua_get([[_G._count_after_load]]), 0)
    Helpers.wait_annotated(nvim)
end

T["persist"]["stale fallback version is discarded"] = function()
    local nvim = Helpers.nvim()
    nvim.lua(SETUP)
    nvim.lua([[
        vim.fn.mkdir(_G._persist_dir, "p")
        local name = vim.fn.sha256(vim.fn.fnamemodify("tests/integration/fixtures/4.4.fix", ":p")):sub(1, 32)
        local blob = vim.mpack.encode({
            format_version = 2,
            dict_fingerprint = require("fix.persist").fingerprint(),
            fallback_version = "FIX.4.0",
            entries = { abc = { version = "FIX.4.4", fields = {} } },
        })
        local f = io.open(_G._persist_dir .. "/" .. name .. ".mpack", "wb")
        f:write(blob)
        f:close()
    ]])
    nvim.lua([[
        _G._count_after_load = nil
        local persist = require("fix.persist")
        local orig = persist.load_into_cache
        persist.load_into_cache = function(buf)
            orig(buf)
            _G._count_after_load = require("fix.cache")._count
        end
    ]])
    nvim.cmd("edit tests/integration/fixtures/4.4.fix")
    local ok = Helpers.wait_for(nvim, [[_G._count_after_load ~= nil]], 2000)
    MiniTest.expect.equality(ok, true)
    MiniTest.expect.equality(nvim.lua_get([[_G._count_after_load]]), 0)
    Helpers.wait_annotated(nvim)
end

T["persist"]["unnamed buffer is not persisted"] = function()
    local nvim = Helpers.nvim()
    nvim.lua(SETUP)
    -- Read the first non-empty line from the fixture (file starts with a blank line).
    nvim.lua([[
        local f = io.open("tests/integration/fixtures/4.4.fix", "r")
        local line = ""
        while line == "" do line = f:read("*l") end
        f:close()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
        vim.bo.filetype = "fix"
    ]])
    Helpers.wait_annotated(nvim)
    Helpers.sleep(nvim, 300)
    MiniTest.expect.equality(#cache_files(nvim), 0)
end

T["persist"]["FIX cache clear removes file and re-renders"] = function()
    local nvim = Helpers.nvim()
    nvim.lua(SETUP)
    Helpers.load_fixture(nvim, "4.4.fix")
    Helpers.wait_for(nvim, [[#vim.fn.globpath(_G._persist_dir, "*.mpack", false, true) > 0]], 5000)
    nvim.cmd("FIX cache clear")
    MiniTest.expect.equality(#cache_files(nvim), 0)
    Helpers.wait_annotated(nvim)
    MiniTest.expect.equality(#Helpers.get_extmarks(nvim) > 0, true)
end

T["persist"]["rotation keeps max_files newest"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[
        _G._persist_dir = vim.fn.tempname()
        require("fix").setup({ cache = { persist = { dir = _G._persist_dir, max_files = 2, max_bytes = false } } })
        -- Read the first non-empty line (fixture starts with a blank line).
        local f = io.open("tests/integration/fixtures/4.4.fix", "r")
        local line = ""
        while line == "" do line = f:read("*l") end
        f:close()
        -- Store paths so the test can open them one at a time with waits.
        _G._fix_paths = {}
        for i = 1, 3 do
            local path = vim.fn.tempname() .. i .. ".fix"
            local out = io.open(path, "w")
            out:write(line .. "\n")
            out:close()
            _G._fix_paths[i] = path
        end
    ]])
    -- Open each file, wait for warm-up (triggers save), then wait for the async
    -- write for that file to land on disk before opening the next one so that
    -- rotation mtime ordering is stable.
    for i = 1, 3 do
        nvim.lua(string.format([[vim.cmd("edit " .. _G._fix_paths[%d])]], i))
        Helpers.wait_annotated(nvim)
        -- After the 3rd file rotation may immediately bring count back to 2,
        -- so use math.min to avoid a condition that can never be met.
        local min_expected = math.min(i, 2)
        Helpers.wait_for(
            nvim,
            string.format([[#vim.fn.globpath(_G._persist_dir, "*.mpack", false, true) >= %d]], min_expected),
            3000
        )
    end
    local ok = Helpers.wait_for(nvim, [[#vim.fn.globpath(_G._persist_dir, "*.mpack", false, true) == 2]], 5000)
    MiniTest.expect.equality(ok, true)
end

T["persist"]["rotation keeps total size under max_bytes"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[
        _G._persist_dir = vim.fn.tempname()
        require("fix").setup({ cache = { persist = { dir = _G._persist_dir, max_files = false, max_bytes = 10 } } })
        vim.fn.mkdir(_G._persist_dir, "p")

        local function write_cache(name, size, mtime)
            local path = _G._persist_dir .. "/" .. name .. ".mpack"
            local f = assert(io.open(path, "wb"))
            f:write(string.rep(name:sub(1, 1), size))
            f:close()
            local ok, err = vim.uv.fs_utime(path, mtime, mtime)
            assert(ok, err)
        end

        write_cache("old", 6, 100)
        write_cache("middle", 6, 200)
        write_cache("new", 6, 300)
        require("fix.persist").rotate()
    ]])
    local ok = Helpers.wait_for(nvim, [[#vim.fn.globpath(_G._persist_dir, "*.mpack", false, true) == 1]], 3000)
    MiniTest.expect.equality(ok, true)
    MiniTest.expect.equality(cache_names(nvim), { "new.mpack" })
end

T["persist"]["rotation deletes a single file over max_bytes"] = function()
    local nvim = Helpers.nvim()
    nvim.lua([[
        _G._persist_dir = vim.fn.tempname()
        require("fix").setup({ cache = { persist = { dir = _G._persist_dir, max_files = false, max_bytes = 5 } } })
        vim.fn.mkdir(_G._persist_dir, "p")

        local path = _G._persist_dir .. "/oversized.mpack"
        local f = assert(io.open(path, "wb"))
        f:write(string.rep("x", 6))
        f:close()
        require("fix.persist").rotate()
    ]])
    local ok = Helpers.wait_for(nvim, [[#vim.fn.globpath(_G._persist_dir, "*.mpack", false, true) == 0]], 3000)
    MiniTest.expect.equality(ok, true)
end

T["persist"]["invalid rotation limits are rejected"] = function()
    local nvim = Helpers.nvim()
    local errors = nvim.lua_get([[
        (function()
            local cases = {
                max_files_zero = { cache = { persist = { max_files = 0 } } },
                max_files_fraction = { cache = { persist = { max_files = 1.5 } } },
                max_bytes_zero = { cache = { persist = { max_bytes = 0 } } },
                both_false = { cache = { persist = { max_files = false, max_bytes = false } } },
            }
            local out = {}
            for name, opts in pairs(cases) do
                local ok, err = pcall(function()
                    require("fix").setup(opts)
                end)
                out[name] = ok and "" or tostring(err)
            end
            return out
        end)()
    ]])

    MiniTest.expect.equality(errors.max_files_zero:find("max_files", 1, true) ~= nil, true)
    MiniTest.expect.equality(errors.max_files_fraction:find("max_files", 1, true) ~= nil, true)
    MiniTest.expect.equality(errors.max_bytes_zero:find("max_bytes", 1, true) ~= nil, true)
    MiniTest.expect.equality(errors.both_false:find("cannot both be false", 1, true) ~= nil, true)
end

return T
