rockspec_format = "3.0"
package = "fix.nvim"
version = "scm-1"

source = {
  url = "git+https://github.com/sergluka/fix.nvim",
}

description = {
  summary = "FIX protocol support for Neovim",
  homepage = "https://github.com/sergluka/fix.nvim",
  license = "MIT",
}

dependencies = {
  "lua >= 5.1",
  "xml2lua",
}

-- Lua sources are loaded by Neovim from the plugin runtimepath, not from the
-- luarocks tree. This rockspec exists solely so lazy.nvim resolves and installs
-- the non-plugin Lua dependency (xml2lua) into the plugin's rocks tree.
build = {
  type = "none",
}
