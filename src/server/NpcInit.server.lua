-- Bootstraps the AI NPC system. Tag any NPC Model in Workspace with the
-- CollectionService tag in Config.NPC_TAG ("AiNpc" by default) to have it
-- picked up automatically -- no per-NPC code changes needed.

local NpcAutonomy = require(script.Parent.NpcAutonomy)
local NpcChatController = require(script.Parent.NpcChatController)

NpcChatController.Start()
NpcAutonomy.Start()
