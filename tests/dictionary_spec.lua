---@diagnostic disable: undefined-field

describe("load XML dictionary", function()
	local subject = require("lua.ft-fix.dictionary")

	for _, version in ipairs({ "FIX.4.0", "FIX.4.1", "FIX.4.2", "FIX.4.3", "FIX.4.4", "FIXT.1.1" }) do
		it("load " .. version, function()
			local dict = subject.load(version)

			local begin_string = dict.fields[8]
			assert.are.same(8, begin_string.tag)
			assert.are.same("BeginString", begin_string.name)

			local heartbeat = dict.messages["0"]
			assert.are.same("0", heartbeat.type)
			assert.are.same("Heartbeat", heartbeat.name)
		end)
	end
end)
