local subject = require("lua.ft-fix.dictionary")

describe("load XML dictionary", function()
	for _, version in ipairs({ "FIX.4.0", "FIX.4.1", "FIX.4.2", "FIX.4.3", "FIX.4.4", "FIXT.1.1" }) do
		it("load " .. version, function()
			local xml = subject.load(version)
			-- print(dump(type(xml)))
			-- print(xml.root.Messages.Message[2].MsgType)
		end)
	end
end)
