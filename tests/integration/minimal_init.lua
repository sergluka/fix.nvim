-- Bootstrap shared by controller and every nvim nvim.
-- All dependencies are baked into the image at /opt/deps. No network I/O.

-- Plugin under test (cwd is enforced by Containerfile WORKDIR /plugin).
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Pre-built tree-sitter-fix grammar (parser/fix.so under this prefix).
vim.opt.runtimepath:prepend("/opt/fix-parser")

-- Standard nvim-plugin-layout dependencies: prepend to runtimepath.
for _, name in ipairs({
    "nvim-treesitter",
    "mega.cmdparse",
    "mega.logging",
    "snacks.nvim",
    "neo-tree.nvim",
    "nui.nvim",
    "plenary.nvim",
    "mini.nvim",
}) do
    vim.opt.runtimepath:prepend("/opt/deps/" .. name)
end

-- xml2lua ships a luarocks-style layout (xml2lua.lua + xmlhandler/ at repo
-- root, not under lua/), so it must go on package.path, not runtimepath.
package.path = package.path .. ";/opt/deps/xml2lua/?.lua" .. ";/opt/deps/xml2lua/?/init.lua"

require("nvim-treesitter.configs").setup({
    ensure_installed = {},
    highlight = { enable = true },
})

require("fix").setup({})

require("mini.test").setup()
