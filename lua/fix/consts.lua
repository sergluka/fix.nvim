local M = {}

---@enum FixVersion
M.FixVersion = {
    FIX_2_7 = "FIX.2.7",
    FIX_3_0 = "FIX.3.0",
    FIX_4_0 = "FIX.4.0",
    FIX_4_1 = "FIX.4.1",
    FIX_4_2 = "FIX.4.2",
    FIX_4_3 = "FIX.4.3",
    FIX_4_4 = "FIX.4.4",
    FIX_5_0 = "FIXT.1.1",
}

---@enum FixTag
M.FixTag = {
    BeginSeqNo = 7,
    BeginString = 8,
    ClOrdID = 11,
    EndSeqNo = 16,
    ExecID = 17,
    MsgSeqNum = 34,
    MsgType = 35,
    NewSeqNo = 36,
    OrderQty = 38,
    OrdType = 40,
    PossDupFlag = 43,
    Price = 44,
    SenderCompID = 49,
    SendingTime = 52,
    Side = 54,
    Symbol = 55,
    TargetCompID = 56,
    Text = 58,
    TimeInForce = 59,
    GapFillFlag = 123,
    ExecType = 150,
}

return M
