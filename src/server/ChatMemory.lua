-- Persists each player's recent conversation with the NPC across sessions.
-- Pattern: load into an in-memory cache on join, mutate the cache freely,
-- write to DataStore only on leave + periodic autosave -- never on every
-- single chat message, to stay well within per-experience DataStore quotas.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Config = require(script.Parent.Config)

local ChatMemory = {}

local store = DataStoreService:GetDataStore("AiNpcChatMemory_v1")

-- userId -> { history: {ChatTurn}, dirty: boolean }
local sessionCache: { [number]: { history: { any }, dirty: boolean } } = {}

local function safeGetAsync(key: string)
	local ok, result = pcall(function()
		return store:GetAsync(key)
	end)
	if not ok then
		warn("[ChatMemory] GetAsync failed for " .. key .. ": " .. tostring(result))
		return nil
	end
	return result
end

local function safeSetAsync(key: string, value: any)
	local ok, err = pcall(function()
		store:SetAsync(key, value)
	end)
	if not ok then
		warn("[ChatMemory] SetAsync failed for " .. key .. ": " .. tostring(err))
	end
end

local function keyFor(userId: number): string
	return "player_" .. tostring(userId)
end

function ChatMemory.Load(player: Player)
	local key = keyFor(player.UserId)
	local saved = safeGetAsync(key)

	sessionCache[player.UserId] = {
		history = (type(saved) == "table" and saved.history) or {},
		dirty = false,
	}
end

function ChatMemory.GetHistory(player: Player): { any }
	local entry = sessionCache[player.UserId]
	if not entry then
		return {}
	end
	return entry.history
end

function ChatMemory.AppendTurn(player: Player, role: string, content: string)
	local entry = sessionCache[player.UserId]
	if not entry then
		entry = { history = {}, dirty = false }
		sessionCache[player.UserId] = entry
	end

	table.insert(entry.history, { role = role, content = content })

	-- Cap stored history a bit above what we send per-request, so context
	-- doesn't grow unbounded but still has a little headroom.
	local maxStored = Config.MAX_HISTORY_TURNS * 2
	while #entry.history > maxStored do
		table.remove(entry.history, 1)
	end

	entry.dirty = true
end

function ChatMemory.Save(player: Player)
	local entry = sessionCache[player.UserId]
	if not entry or not entry.dirty then
		return
	end

	safeSetAsync(keyFor(player.UserId), { history = entry.history })
	entry.dirty = false
end

function ChatMemory.Unload(player: Player)
	ChatMemory.Save(player)
	sessionCache[player.UserId] = nil
end

-- Periodic autosave for players who stay connected a long time, so a crash
-- doesn't lose the whole session's memory.
local AUTOSAVE_INTERVAL_SECONDS = 120
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL_SECONDS)
		for _, player in ipairs(Players:GetPlayers()) do
			ChatMemory.Save(player)
		end
	end
end)

return ChatMemory
