-- Copy this file to Config.lua (which is gitignored) and fill in your own
-- PROXY_URL / SHARED_SECRET. Config.lua is what Rojo actually syncs into
-- Studio -- this file is just the checked-in template.

local SharedConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("SharedConfig"))

local Config = {}

-- The HTTPS URL of your deployed proxy server, e.g. "https://your-service.onrender.com".
-- Do NOT point this at OpenRouter directly -- the proxy is what holds the API key.
Config.PROXY_URL = "https://REPLACE-ME.onrender.com"

-- Must exactly match the SHARED_SECRET env var set on the proxy server.
Config.SHARED_SECRET = "REPLACE-ME"

-- CollectionService tag applied to any NPC model that should run the AI system.
-- Kept in the shared config since the client also needs to know it (to show
-- the click-to-move UI near tagged NPCs).
Config.NPC_TAG = SharedConfig.NPC_TAG

-- Placeholder persona -- replace with your NPC's real name/personality before shipping.
-- Sent to the proxy on every request as the "persona" field (falls back to the
-- proxy's own default if left blank).
Config.NPC_PERSONA = "You are a friendly, upbeat NPC guide in a Roblox game. "
	.. "You enjoy helping players and keeping the mood light. "
	.. "(This is a placeholder persona -- customize it for your NPC.)"

-- How close a player must be to the NPC for their chat to be picked up,
-- if they didn't @mention the NPC by name.
Config.CHAT_PROXIMITY_STUDS = 15

-- Minimum seconds between AI calls triggered by the same player.
Config.CHAT_COOLDOWN_SECONDS = 3

-- Number of past conversation turns (user+assistant pairs count as 2 turns)
-- kept and sent as context on each request.
Config.MAX_HISTORY_TURNS = 6

-- Timeout for the HTTP call to the proxy, in seconds.
Config.HTTP_TIMEOUT_SECONDS = 10

-- Click-to-move validation.
Config.MAX_MOVE_DISTANCE_STUDS = 150
Config.MOVE_COOLDOWN_SECONDS = 2

-- Autonomous idle behavior (NpcAutonomy.lua). Every tick, while Idle, the
-- NPC rolls WANDER_CHANCE to wander, EXAMINE_CHANCE to pause and examine a
-- nearby part, and otherwise stays put -- all pure Luau, no LLM call.
Config.AUTONOMY_TICK_MIN_SECONDS = 8
Config.AUTONOMY_TICK_MAX_SECONDS = 15
Config.WANDER_CHANCE = 0.45
Config.EXAMINE_CHANCE = 0.35
Config.WANDER_RADIUS_STUDS = 20
Config.EXAMINE_RADIUS_STUDS = 20
Config.EXAMINE_DURATION_SECONDS = 3

-- Rate-limited spontaneous self-initiated comments -- the only recurring
-- LLM cost from idle behavior. With these defaults, an always-idle NPC with
-- a player nearby calls the proxy roughly once every ~7 minutes on average
-- (interval floor / chance), never on every tick.
Config.AUTONOMY_THOUGHT_INTERVAL_SECONDS = 150
Config.AUTONOMY_THOUGHT_MIN_IDLE_SECONDS = 90
Config.AUTONOMY_THOUGHT_CHANCE = 0.35

-- How far the NPC "notices" players for context (name/display name feed
-- into what it knows) and for deciding whether anyone's around to talk to.
Config.NEARBY_PLAYERS_RADIUS_STUDS = 30

-- Passive chat monitoring: messages NOT addressed to the NPC still pass
-- through PassiveChatFilter.ShouldConsider (cheap local check) before any
-- of this even applies, then must clear a per-NPC cooldown and a dice roll
-- before actually spending a proxy call.
Config.PASSIVE_LISTEN_STUDS = 25
Config.PASSIVE_CHAT_COOLDOWN_SECONDS = 20
Config.PASSIVE_RESPONSE_CHANCE = 0.35

-- Cap on the "you notice: ..." surroundings text sent to the LLM.
Config.MAX_SURROUNDINGS_CHARS = 300

-- CollectionService tag applied to rideable vehicle NPCs, in addition to
-- NPC_TAG. See VehicleExecutor.lua / NpcDefinitions.lua.
Config.VEHICLE_TAG = SharedConfig.VEHICLE_TAG

-- How often (seconds) a mounted vehicle's height-above-ground is checked
-- and clamped back down to its configured flight ceiling.
Config.VEHICLE_MOUNT_HEIGHT_CHECK_SECONDS = 1

-- How often (seconds) a vehicle's "move" animation is checked and
-- started/stopped to match whether it's currently moving.
Config.VEHICLE_ANIM_POLL_SECONDS = 0.5

return Config
