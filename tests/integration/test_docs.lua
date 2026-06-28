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

return T
