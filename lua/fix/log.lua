local M = {}

---@param msg string
function M.warn(msg)
    -- mega.logging is an optional dependency of the runtime config; never let
    -- logging itself break plugin behavior.
    pcall(function()
        require("mega.logging").get_logger("fix.nvim"):warning(msg)
    end)
end

return M
