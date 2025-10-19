vim.bo.commentstring = "# %s"
vim.bo.iskeyword = "33-60,62-123,125-255" -- all characters, except | and =

vim.opt_local.breakat:prepend("|")
vim.opt_local.wrap = true

vim.opt_local.conceallevel = 1
vim.opt_local.concealcursor = "nc"
