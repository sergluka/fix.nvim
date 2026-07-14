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

local function command_selection(options)
    if not options or not options.range or options.range == 0 then
        return nil
    end

    local line1 = options.line1
    local line2 = options.line2
    if not line1 or not line2 then
        return nil
    end
    local start_mark = vim.fn.getpos("'<")
    local end_mark = vim.fn.getpos("'>")
    local is_visual_range = start_mark[2] == line1 and end_mark[2] == line2

    if is_visual_range and vim.fn.visualmode() == "v" then
        return {
            start_row = start_mark[2] - 1,
            start_col = math.max(start_mark[3] - 1, 0),
            end_row = end_mark[2] - 1,
            end_col = end_mark[3],
            kind = "char",
        }
    end

    return {
        start_row = line1 - 1,
        start_col = 0,
        end_row = line2 - 1,
        end_col = math.huge,
        kind = "line",
    }
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
        choices = { "all", "tag", "value", "title", "message", "group" },
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

    local dictionary = top_subparser:add_parser({ name = "dictionary", help = "Use custom FIX dictionary" })
    dictionary:add_parameter({
        name = "path",
        required = true,
        help = "Dictionary XML file or directory",
    })
    dictionary:set_execute(function(data)
        fix.use_dictionary(data.namespace.path)
    end)

    local yank_parser = top_subparser:add_parser({ name = "yank", help = "Yank annotations" })
    yank_parser:add_parameter({
        name = "--reg",
        required = false,
        help = "Register",
    })
    yank_parser:set_execute(function(data)
        local register = data.namespace.reg
        local selection = command_selection(data.options)
        fix.yank(register, selection)
    end)

    local cache_parser = top_subparser:add_parser({ name = "cache", help = "Cache maintenance" })
    local cache_subparser = cache_parser:add_subparsers({ destination = "cache_command" })
    local cache_clear = cache_subparser:add_parser({ name = "clear", help = "Drop cached annotations for this file" })
    cache_clear:set_execute(function()
        fix.cache_clear()
    end)

    Cmdparse.create_user_command(parser, nil, { range = true })
end

register_treesitter()
register_commands()
