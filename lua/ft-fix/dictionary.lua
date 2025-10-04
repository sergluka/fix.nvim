M = {}

---@alias FixMessageType integer

---@enum FixVersion
FIX_VERSION = {
	FIX_4_0 = "FIX.4.0",
	FIX_4_1 = "FIX.4.1",
	FIX_4_2 = "FIX.4.2",
	FIX_4_3 = "FIX.4.3",
	FIX_4_4 = "FIX.4.4",
	FIXT_1_1 = "FIXT.1.1",
}

---@class Message
---@field type FixMessageType
---@field name string
---@field category string
---@field description string

---@param version FixVersion
---@return { [FixMessageType]: Message }
function M.load(version)
	local xml2lua = require("xml2lua")

	local path = "docs/xml/" .. version .. "/Base/Messages.xml"
	local xml = xml2lua.loadFile(path)

	local handler = require("xmlhandler.tree"):new()
	local parser = xml2lua.parser(handler)
	parser:parse(xml)

	local dict = {}
	for _, value in ipairs(handler.root.Messages.Message) do
		dict[value.MsgType] = {
			type = value.MsgType,
			name = value.Name,
			category = value.Category,
			description = value.Description,
		}
	end
	return dict
end

return M
