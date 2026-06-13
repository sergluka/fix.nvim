-- This plugin includes data derived from the FIX Repository
-- © FIX Protocol Limited (FPL). Used under licence.
-- FPL is not responsible for any modifications or errors in this implementation.

if vim.g.loaded_fix then
    return
end
vim.g.loaded_fix = true

local ok, fix = pcall(require, "fix")
if not ok then
    vim.notify("fix.nvim: failed to load core module", vim.log.levels.ERROR)
    return
end

local function register_treesitter()
    local parsers = require("nvim-treesitter.parsers")
    local config = {
        install_info = {
            url = "https://github.com/sergluka/tree-sitter-fix",
            files = { "src/parser.c" }, -- used by master branch; ignored by main
        },
    }
    if type(parsers.get_parser_configs) == "function" then
        -- nvim-treesitter `master` branch
        parsers.get_parser_configs().fix = config
    else
        -- nvim-treesitter `main` branch: parsers is a `lang -> config` table
        ---@diagnostic disable-next-line: inject-field
        parsers.fix = config
    end
end

local function register_commands()
    local Cmdparse = require("mega.cmdparse")

    local parser = Cmdparse.ParameterParser.new({ name = "FIX", help = "FIX protocol" })
    local top_subparser = parser:add_subparsers({ destination = "commands" })

    local toggle = top_subparser:add_parser({ name = "annotations", help = "Toggle annotations" })
    toggle:add_parameter({
        name = "scope",
        required = false,
        choices = { "all", "tag", "value", "message" },
        help = "Type of annotation",
    })
    toggle:set_execute(function(data)
        fix.annotate_toggle(data.namespace.scope)
    end)

    local picker = top_subparser:add_parser({ name = "picker", help = "Open fields picker" })
    picker:set_execute(function()
        require("fix.snacks").open()
    end)

    local browse = top_subparser:add_parser({ name = "browse", help = "Open tag info online" })
    browse:set_execute(function()
        fix.browse_tag_online()
    end)

    local yank_parser = top_subparser:add_parser({ name = "yank", help = "Yank annotations" })
    yank_parser:add_parameter({
        name = "yank",
        required = false,
        choices = { "field", "message" },
        help = "Type of annotation",
        yank_parser:add_parameter({
            name = "--reg",
            required = false,
            help = "Register",
        }),
    })
    yank_parser:set_execute(function(data)
        local register = data.namespace.reg
        if data.namespace.yank == "field" then
            fix.yank_field(register)
        elseif data.namespace.yank == "message" then
            fix.yank_message(register)
        end
    end)

    local cache_parser = top_subparser:add_parser({ name = "cache", help = "Cache maintenance" })
    local cache_subparser = cache_parser:add_subparsers({ destination = "cache_command" })
    local cache_clear = cache_subparser:add_parser({ name = "clear", help = "Drop cached annotations for this file" })
    cache_clear:set_execute(function()
        fix.cache_clear()
    end)

    Cmdparse.create_user_command(parser)
end

register_treesitter()
register_commands()
