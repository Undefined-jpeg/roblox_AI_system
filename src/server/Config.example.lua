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

return Config
