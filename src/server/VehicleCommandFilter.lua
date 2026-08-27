-- Cheap local gate run BEFORE spending any proxy/LLM call on a chat message
-- directed at a vehicle NPC that's currently Unresponsive (powered down).
-- A dormant vehicle should never burn an LLM call on ordinary chat it can't
-- act on anyway -- only a message that plausibly means "wake up" reaches
-- the proxy at all, and even then it's dispatched with a whitelist narrowed
-- to transform_up only (see NpcChatController.lua).

local VehicleCommandFilter = {}

local WAKE_PHRASES = {
	"transform up",
	"wake up",
	"power up",
	"activate",
}

function VehicleCommandFilter.IsWakePhrase(message: string): boolean
	local lower = message:lower()

	for _, phrase in ipairs(WAKE_PHRASES) do
		if lower:find(phrase, 1, true) then
			return true
		end
	end

	return false
end

return VehicleCommandFilter
