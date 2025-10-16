---@diagnostic disable: undefined-field

describe("load XML dictionary", function()
	local subject = require("lua.ft-fix.dictionary")

	for _, version in ipairs({ "FIX.4.0", "FIX.4.1", "FIX.4.2", "FIX.4.3", "FIX.4.4", "FIXT.1.1" }) do
		it("load " .. version, function()
			local dict = subject.load(version)

			local begin_string = dict:field(8)
			assert.are.same(8, begin_string.tag)
			assert.are.same("BeginString", begin_string.name)

			local enum = dict:enum_by_value(35, "0")
			assert.are.same("Heartbeat", enum.name)

			local message = dict:message("0")
			assert.are.same("Heartbeat", message.name)
		end)
	end
end)
