-- Config values needed on BOTH client and server. Nothing secret goes here
-- (secrets/URLs live in src/server/Config.lua, which never syncs to clients).

return {
	-- CollectionService tag applied to AI NPC models. Must match
	-- src/server/Config.lua's NPC_TAG.
	NPC_TAG = "AiNpc",

	-- How close the local player must be to a tagged NPC before the
	-- "Move NPC Here" button appears.
	MOVE_UI_RADIUS = 20,
}
