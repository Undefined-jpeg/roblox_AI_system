-- Dispatch for vehicle-NPC chat actions (follow_player/stop/ride/
-- transform_up/transform_back/move_to). NpcChatController.dispatchAction
-- delegates here whenever the target NPC has a vehicle definition, keeping
-- the existing talking-NPC dispatch path (ActionExecutor's four actions)
-- completely untouched.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionExecutor = require(script.Parent.ActionExecutor)
local VehicleExecutor = require(script.Parent.VehicleExecutor)
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local VehicleChatController = {}

function VehicleChatController.Dispatch(
	npc: Model,
	player: Player?,
	action: { name: string, params: any }?,
	complied: boolean,
	allowedActions: { [string]: boolean }
)
	-- Defense-in-depth: NpcChatController already gates on both of these
	-- before ever calling the proxy, but never trust a single enforcement
	-- point for "a dormant vehicle must not act."
	if complied == false then
		return
	end
	if VehicleExecutor.GetMode(npc) == "Unresponsive" and (not action or action.name ~= "transform_up") then
		return
	end

	if type(action) ~= "table" or type(action.name) ~= "string" then
		return
	end

	if not allowedActions[action.name] then
		warn("[VehicleChatController] Rejected action outside this turn's whitelist: " .. tostring(action.name))
		return
	end

	if action.name == "follow_player" then
		if not player then
			return
		end
		ActionExecutor.FollowPlayer(npc, player)
	elseif action.name == "stop" then
		ActionExecutor.Stop(npc)
	elseif action.name == "ride" then
		if not player then
			return
		end
		VehicleExecutor.Ride(npc, player)
	elseif action.name == "transform_up" then
		VehicleExecutor.TransformUp(npc)
	elseif action.name == "transform_back" then
		VehicleExecutor.TransformBack(npc)
	elseif action.name == "move_to" then
		if not player then
			return
		end
		-- Never let the LLM supply coordinates -- prompt that specific
		-- player's client to enter the existing click-to-move point mode
		-- for this NPC, same trust boundary as the manual "Move NPC Here"
		-- button (NpcMoveHandler.server.lua still does the real validation
		-- once they click).
		Remotes.GetPromptMoveClickEvent():FireClient(player, npc)
	end
end

return VehicleChatController
