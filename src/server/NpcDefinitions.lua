-- Per-NPC configuration, keyed by the NPC Model's Name in Workspace. Lets
-- different tagged NPCs (a talking companion vs. a rideable vehicle) have
-- their own persona and action whitelist without a global Config/ActionConfig
-- change affecting every NPC. Any NPC name NOT listed in DEFINITIONS falls
-- back to today's global Config.NPC_PERSONA / ActionConfig.*_ACTIONS, so the
-- existing NPC's behavior is unaffected by this module's existence.

local Config = require(script.Parent.Config)
local ActionConfig = require(script.Parent.ActionConfig)

local NpcDefinitions = {}

export type VehicleDef = {
	seatName: string,
	animations: { spawn: string, move: string, idle: string },
	groundSpeed: number,
	flightSpeed: number,
	linearMaxForce: number,
	turnDegPerSec: number,
	maxFlightHeightStuds: number,
	rideApproachStuds: number,
}

export type NpcDef = {
	persona: string,
	chatActions: { [string]: boolean },
	selfActions: { [string]: boolean },
	passiveActions: { [string]: boolean },
	vehicle: VehicleDef?,
}

-- Placeholder persona -- write Eight's real personality here. Animation ids
-- are published assets (see proxy/setup docs); PlayAnim-style helpers still
-- warn-and-no-op gracefully if any of these ever go empty/invalid.
local DEFINITIONS: { [string]: NpcDef } = {
	Eight = {
		persona = "You are Eight, a rideable robot. (Placeholder persona -- customize before shipping.)",
		chatActions = ActionConfig.VEHICLE_CHAT_ACTIONS,
		selfActions = ActionConfig.VEHICLE_SELF_ACTIONS,
		passiveActions = ActionConfig.VEHICLE_PASSIVE_ACTIONS,
		vehicle = {
			seatName = "Seat",
			animations = {
				spawn = "rbxassetid://103389384347300",
				move = "rbxassetid://136151754007256",
				idle = "rbxassetid://134247433443735",
			},
			groundSpeed = 40,
			flightSpeed = 55,
			linearMaxForce = 50000,
			turnDegPerSec = 90,
			maxFlightHeightStuds = 120,
			rideApproachStuds = 8,
		},
	},
}

local function defaultDef(): NpcDef
	return {
		persona = Config.NPC_PERSONA,
		chatActions = ActionConfig.CHAT_ACTIONS,
		selfActions = ActionConfig.SELF_ACTIONS,
		passiveActions = ActionConfig.PASSIVE_ACTIONS,
		vehicle = nil,
	}
end

function NpcDefinitions.Get(npc: Model): NpcDef
	return DEFINITIONS[npc.Name] or defaultDef()
end

return NpcDefinitions
