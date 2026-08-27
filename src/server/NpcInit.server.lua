-- Bootstraps the AI NPC system. Tag any NPC Model in Workspace with the
-- CollectionService tag in Config.NPC_TAG ("AiNpc" by default) to have it
-- picked up automatically -- no per-NPC code changes needed. Rideable
-- vehicle NPCs (e.g. Eight) additionally need Config.VEHICLE_TAG.

local NpcAutonomy = require(script.Parent.NpcAutonomy)
local NpcChatController = require(script.Parent.NpcChatController)
local VehicleExecutor = require(script.Parent.VehicleExecutor)

NpcChatController.Start()
NpcAutonomy.Start()
VehicleExecutor.Start()
