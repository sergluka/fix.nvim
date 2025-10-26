local M = {}

function M.open_url(url)
	local sysname = vim.loop.os_uname().sysname
	if sysname == "Linux" then
		os.execute("xdg-open " .. url)
	elseif sysname == "Windows_NT" then
		os.execute('start "" "' .. url .. '"')
	elseif sysname == "Darwin" then
		os.execute("open " .. url)
	else
		print("Unsupported OS: " .. sysname)
	end
end

return M
