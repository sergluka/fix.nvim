local Consts = require("fix.consts")

local M = {}

--- @param message Message
--- @return FixTreeFormatterChunk[]
function M.default(message)
    local route = message:route()
    local msg_type = message:field(Consts.FixTag.MsgType)
    local seq_no = message:field(Consts.FixTag.MsgSeqNum)
    local route_highlight = message:route_highlight()
    return {
        {
            string.format("%4s · ", seq_no.value or "?"),
            "FixTreeMeta",
        },
        { msg_type.value_text or msg_type.value or "Unknown", "FixTreeName" },
        { "  ", "Normal" },
        { route.sender, route_highlight },
        { " → ", "FixTreeOperator" },
        { route.target, route_highlight },
        {
            string.format(" · %s", msg_type.value or "?"),
            "FixTreeMeta",
        },
    }
end

return M
