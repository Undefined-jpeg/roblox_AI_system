-- Cheap local gate run BEFORE spending any proxy/LLM call on a chat message
-- that wasn't addressed to the NPC (no @mention, out of proximity range).
-- Keeps passive "read the whole server's chat" monitoring affordable: only
-- messages that look like they might actually want help get considered at
-- all, and even then NpcChatController still applies a cooldown + random
-- chance on top of this before ever calling the proxy.

local PassiveChatFilter = {}

local KEYWORDS = {
	"help",
	"how do i",
	"how do you",
	"anyone know",
	"does anyone",
	"what is",
	"where is",
	"why is",
	"can someone",
}

function PassiveChatFilter.ShouldConsider(message: string): boolean
	local lower = message:lower()

	if lower:find("?", 1, true) then
		return true
	end

	for _, keyword in ipairs(KEYWORDS) do
		if lower:find(keyword, 1, true) then
			return true
		end
	end

	return false
end

return PassiveChatFilter
