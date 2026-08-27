-- Single source of truth for what the AI NPC is allowed to do.
-- Keep the action *names* here in sync with proxy/lib/actionSchema.js --
-- anything the LLM returns that isn't listed here is silently dropped.

local ActionConfig = {}

-- Chat-triggered actions the LLM may call via OpenRouter tool-calling.
-- Three whitelists exist because a bystander NPC (passive) or one talking to
-- itself (self-initiated) can do less than an NPC directly addressed by a
-- player -- e.g. it can't "follow" or "stop" for someone not talking to it.
ActionConfig.CHAT_ACTIONS = {
	follow_player = true,
	play_emote = true,
	stop = true,
	wander = true,
}

-- "none" is deliberately absent from every whitelist below: the proxy never
-- returns action = {name = "none", ...} -- a "none" choice comes back as
-- action = nil, which dispatchAction already treats as a no-op before it
-- even reaches the whitelist check.
ActionConfig.SELF_ACTIONS = {
	play_emote = true,
	wander = true,
	stop = true,
}

ActionConfig.PASSIVE_ACTIONS = {
	play_emote = true,
}

-- Emote name -> Roblox default-character emote animation asset id.
-- These are Roblox's standard built-in R15 emote animations, so no custom
-- animation upload is required to use them. Swap in your own asset ids later
-- if you want custom emotes.
ActionConfig.EMOTES = {
	wave = "rbxassetid://507770239",
	dance = "rbxassetid://507771019",
	point = "rbxassetid://507770453",
	laugh = "rbxassetid://507770818",
}

return ActionConfig
