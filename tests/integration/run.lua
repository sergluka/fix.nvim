return function(filter)
    local MiniTest = require("mini.test")

    local ok, err = pcall(function()
        if filter and filter ~= "" then
            MiniTest.run_file("tests/integration/test_" .. filter .. ".lua")
        else
            MiniTest.run({
                collect = {
                    find_files = function()
                        return vim.fn.globpath("tests/integration", "test_*.lua", true, true)
                    end,
                },
                execute = {
                    reporter = MiniTest.gen_reporter.stdout({ group_depth = 2 }),
                },
            })
        end
    end)

    if not ok then
        io.stderr:write("fix.nvim test runner: " .. tostring(err) .. "\n")
        vim.cmd("cquit 2")
        return
    end

    -- MiniTest.execute schedules per-case work via vim.schedule. Wait for
    -- every collected case to have a non-nil exec state before counting,
    -- otherwise n_fail races with the scheduled callbacks and fails open.
    local function all_done()
        local cases = MiniTest.current.all_cases or {}
        if #cases == 0 then
            return true
        end
        for _, case in ipairs(cases) do
            if case.exec == nil then
                return false
            end
        end
        return true
    end

    if not vim.wait(60000, all_done, 25) then
        io.stderr:write("fix.nvim test runner: timed out waiting for cases to finish\n")
        vim.cmd("cquit 3")
        return
    end

    local cases = MiniTest.current.all_cases or {}
    if #cases == 0 then
        io.stderr:write("fix.nvim test runner: no cases collected (check --filter)\n")
        vim.cmd("cquit 4")
        return
    end

    local n_fail = 0
    for _, case in ipairs(cases) do
        if case.exec.state == "Fail" then
            n_fail = n_fail + 1
        end
    end

    if n_fail > 0 then
        vim.cmd("cquit " .. math.min(n_fail, 255))
    else
        vim.cmd("qall!")
    end
end
