-- Cheap, Luau-only world awareness for an NPC. Refreshed by NpcAutonomy's
-- tick (not on every chat message), then read by NpcChatController to build
-- the context sent to the LLM. Nothing here ever calls the proxy -- this
-- module is what keeps that call rare and cheap.

local Players = game:GetService("Players")

local Config = require(script.Parent.Config)
local ActionExecutor = require(script.Parent.ActionExecutor)

local NpcPerception = {}

type PerceptionState = {
	surroundings: { string },
	nearbyPlayersText: string,
	examinedPartName: string?,
	followTargetName: string?,
}

local perception: { [Model]: PerceptionState } = {}

local function getState(npc: Model): PerceptionState
	local state = perception[npc]
	if not state then
		state =
			{ surroundings = {}, nearbyPlayersText = "no one nearby", examinedPartName = nil, followTargetName = nil }
		perception[npc] = state
	end
	return state
end

local function getNpcRootPart(npc: Model): BasePart?
	return npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart") :: BasePart?
end

function NpcPerception.RefreshNearbyPlayers(npc: Model)
	local npcRoot = getNpcRootPart(npc)
	if not npcRoot then
		return
	end

	local names = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local playerRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if playerRoot then
			local distance = (npcRoot.Position - playerRoot.Position).Magnitude
			if distance <= Config.NEARBY_PLAYERS_RADIUS_STUDS then
				table.insert(names, ("%s (%s)"):format(player.Name, player.DisplayName))
			end
		end
	end

	local state = getState(npc)
	state.nearbyPlayersText = #names > 0 and table.concat(names, ", ") or "no one nearby"
end

function NpcPerception.RefreshSurroundings(npc: Model, examinedPart: BasePart)
	local npcRoot = getNpcRootPart(npc)
	if not npcRoot then
		return
	end

	local distance = (npcRoot.Position - examinedPart.Position).Magnitude
	local description = ("a %s %s (~%d studs away)"):format(
		tostring(examinedPart.Material.Name),
		examinedPart.Name,
		distance
	)

	local state = getState(npc)
	state.examinedPartName = examinedPart.Name
	table.insert(state.surroundings, description)
	while #state.surroundings > 3 do
		table.remove(state.surroundings, 1)
	end
end

function NpcPerception.GetActivityLabel(npc: Model): string
	local state = getState(npc)
	local mode = ActionExecutor.GetMode(npc)

	if mode == "Following" and state.followTargetName then
		return "following " .. state.followTargetName
	elseif mode == "Following" then
		return "following someone"
	elseif mode == "Wandering" then
		return "wandering nearby"
	elseif mode == "Examining" and state.examinedPartName then
		return "examining a " .. state.examinedPartName
	elseif mode == "Examining" then
		return "examining something nearby"
	elseif mode == "Moving" then
		return "walking somewhere"
	end

	return "idle"
end

function NpcPerception.SetFollowTargetName(npc: Model, name: string?)
	getState(npc).followTargetName = name
end

function NpcPerception.GetSurroundingsText(npc: Model): string
	local state = getState(npc)
	if #state.surroundings == 0 then
		return "nothing in particular"
	end

	local text = table.concat(state.surroundings, "; ")
	if #text > Config.MAX_SURROUNDINGS_CHARS then
		text = text:sub(1, Config.MAX_SURROUNDINGS_CHARS - 1) .. "…"
	end
	return text
end

function NpcPerception.GetNearbyPlayersText(npc: Model): string
	return getState(npc).nearbyPlayersText
end

return NpcPerception
