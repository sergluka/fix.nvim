local Consts = require("fix.consts")

local M = {}
local FixTag = Consts.FixTag

--- @param message Message
function M.default(message)
    local msg_type_name = message:field(FixTag.MsgType).value_text or "Unknown"
    local route = message:route()

    local text = string.format(
        "%s: %s: %s=>%s | %s",
        message:field(FixTag.SendingTime).value or "???",
        message:field(FixTag.MsgSeqNum).value or "???",
        route.sender,
        route.target,
        message:field(FixTag.MsgType).value_text or "???"
    )

    if message:field(FixTag.PossDupFlag).value == "Y" then
        text = text .. " [POSS DUP]"
    end

    local details = ""
    if msg_type_name == "ExecutionReport" then
        local exec_type = message:field(FixTag.ExecType).value_text or "???"
        if exec_type == "Trade" or exec_type == "TradeCorrect" then
            local client_order_id = message:field(FixTag.ClOrdID).value
            local exec_id = message:field(FixTag.ExecID).value or "MISSING"
            local price = message:field(FixTag.Price).value or "MKT"
            local amount = message:field(FixTag.OrderQty).value or "???"
            details = string.format("%s %s@%s ClOrdId=%s ExecId=%s", exec_type, amount, price, client_order_id, exec_id)
        else
            details = exec_type
        end
    elseif msg_type_name == "NewOrderSingle" then
        local ord_type = message:field(FixTag.OrdType).value_text
        local time_in_force = message:field(FixTag.TimeInForce).value_text
        local side = message:field(FixTag.Side).value_text
        local amount = message:field(FixTag.OrderQty).value or "???"
        local price = message:field(FixTag.Price).value or "MKT"
        local symbol = message:field(FixTag.Symbol).value or "???"
        details = string.format("%s %s %s %s %s @ %s", side, time_in_force, ord_type, amount, symbol, price)
    elseif msg_type_name == "Logout" then
        details = message:field(FixTag.Text).value or ""
    elseif msg_type_name == "ResendRequest" then
        local begin_seq_no = message:field(FixTag.BeginSeqNo).value or "MISSING"
        local end_seq_no = message:field(FixTag.EndSeqNo).value or "MISSING"
        details = string.format("%s - %s", begin_seq_no, end_seq_no)
    elseif msg_type_name == "SequenceReset" then
        local is_fill_gap = message:field(FixTag.GapFillFlag).value == "Y"
        local new_seq_num = message:field(FixTag.NewSeqNo).value or "MISSING"
        if is_fill_gap then
            details = string.format("Gap Fill to %s", new_seq_num)
        else
            details = string.format("Reset to %s", new_seq_num)
        end
    end

    local title = { { text .. " | ", message:route_highlight() } }
    if details ~= "" then
        title[#title + 1] = { details .. " | ", "Repeat" }
    end

    return { title }
end

return M
