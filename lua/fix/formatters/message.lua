local M = {}

--- @param message Message
function M.default(message)
    local msg_type_name = message:field(35).value_text or "Unknown"

    local text = string.format(
        "%s: %s: %s=>%s | %s",
        message:field(52).value or "???",
        message:field(34).value or "???",
        message:field(49).value or "???",
        message:field(56).value or "???",
        message:field(35).value_text or "???"
    )

    if message:field(43).value == "Y" then
        text = text .. " [POSS DUP]"
    end

    local details = ""
    if msg_type_name == "ExecutionReport" then
        local exec_type = message:field(150).value_text or "???"
        if exec_type == "Trade" or exec_type == "TradeCorrect" then
            local client_order_id = message:field(11).value
            local exec_id = message:field(17).value or "MISSING"
            local price = message:field(44).value or "MKT"
            local amount = message:field(38).value or "???"
            details = string.format("%s %s@%s ClOrdId=%s ExecId=%s", exec_type, amount, price, client_order_id, exec_id)
        else
            details = exec_type
        end
    elseif msg_type_name == "NewOrderSingle" then
        local ord_type = message:field(40).value_text
        local time_in_force = message:field(59).value_text
        local side = message:field(54).value_text
        local amount = message:field(38).value or "???"
        local price = message:field(44).value or "MKT"
        local symbol = message:field(55).value or "???"
        details = string.format("%s %s %s %s %s @ %s", side, time_in_force, ord_type, amount, symbol, price)
    elseif msg_type_name == "Logout" then
        details = message:field(58).value or ""
    elseif msg_type_name == "ResendRequest" then
        local begin_seq_no = message:field(7).value or "MISSING"
        local end_seq_no = message:field(16).value or "MISSING"
        details = string.format("%s - %s", begin_seq_no, end_seq_no)
    elseif msg_type_name == "SequenceReset" then
        local is_fill_gap = message:field(123).value == "Y"
        local new_seq_num = message:field(36).value or "MISSING"
        if is_fill_gap then
            details = string.format("Gap Fill to %s", new_seq_num)
        else
            details = string.format("Reset to %s", new_seq_num)
        end
    end

    return {
        { { text, "Title" }, { " | " .. details, "Repeat" } },
    }
end

return M
