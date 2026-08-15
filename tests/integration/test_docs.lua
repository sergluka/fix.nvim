local MiniTest = require("mini.test")

local T = MiniTest.new_set()

local function read_file(path)
    local file = assert(io.open(path, "r"))
    local content = file:read("*a")
    file:close()
    return content
end

local function read_readme_configuration_block()
    local readme = read_file("README.md")
    local section_start = assert(readme:find("\n## Configuration\n", 1, true), "README configuration section missing")
    local fence_start = assert(readme:find("```lua\n", section_start, true), "README configuration lua fence missing")
    local code_start = fence_start + #"```lua\n"
    local fence_end = assert(readme:find("\n```", code_start, true), "README configuration lua fence not closed")
    return readme:sub(code_start, fence_end - 1)
end

--- The vimdoc sample is a full `require("fix").setup({...})` statement, not
--- a bare table like the README's, so it is executed rather than parsed.
local function read_vimdoc_configuration_block()
    local doc = read_file("doc/fix.nvim.txt")
    local tag_start = assert(doc:find("*fix.nvim-configuration*", 1, true), "vimdoc configuration tag missing")
    local fence_start = assert(doc:find("\n>\n", tag_start, true), "vimdoc configuration fence missing")
    local code_start = fence_start + #"\n>\n"
    local fence_end = assert(doc:find("\n<\n", code_start, true), "vimdoc configuration fence not closed")
    return doc:sub(code_start, fence_end - 1)
end

T["README configuration sample evaluates as setup opts"] = function()
    local block = read_readme_configuration_block()
    local chunk = assert(loadstring("return " .. block))
    local opts = chunk()

    MiniTest.expect.equality(type(opts), "table")
    MiniTest.expect.no_error(function()
        require("fix").setup(opts)
    end)
end

T["README configuration sample does not require formatter modules while building opts"] = function()
    local block = read_readme_configuration_block()
    local forbidden = "formatter%s*=%s*require%s*%(%s*[\"']fix%.formatters%."

    MiniTest.expect.equality(block:find(forbidden) == nil, true)
end

T["README configuration sample declares the overrides and formatters registry options"] = function()
    local block = read_readme_configuration_block()
    local chunk = assert(loadstring("return " .. block))
    local opts = chunk()

    MiniTest.expect.equality(opts.overrides.modeline.enabled, true)
    MiniTest.expect.equality(opts.overrides.modeline.allow_paths, false)
    MiniTest.expect.equality(type(opts.formatters.tag), "table")
    MiniTest.expect.equality(type(opts.formatters.value), "table")
    MiniTest.expect.equality(type(opts.formatters.title), "table")
end

T["doc/fix.nvim.txt configuration sample evaluates and calls setup()"] = function()
    local block = read_vimdoc_configuration_block()
    MiniTest.expect.equality(block:find('require("fix").setup(', 1, true) ~= nil, true)

    local chunk = assert(loadstring(block))
    MiniTest.expect.no_error(chunk)
end

return T
