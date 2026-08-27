-- Persists each player's recent conversation with EACH NPC separately
-- (keyed by NPC Model name), across sessions. Two NPCs with different
-- personas/purposes (e.g. a talking companion and a vehicle) must not leak
-- conversation history into each other's context -- confirmed live: without
-- this separation, a vehicle's system prompt was picking up an unrelated
-- NPC's conversation about nearby props.
--
-- Pattern: load into an in-memory cache on join, mutate the cache freely,
-- write to DataStore only on leave + periodic autosave -- never on every
-- single chat message, to stay well within per-experience DataStore quotas.
-- One DataStore key per player (not per player+NPC) keeps quota usage
-- constant regardless of how many NPCs exist.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Config = require(script.Parent.Config)

local ChatMemory = {}

local store = DataStoreService:GetDataStore("AiNpcChatMemory_v2")

type NpcHistoryEntry = { history: { any }, dirty: boolean }
-- userId -> { [npcName]: NpcHistoryEntry }
local sessionCache: { [number]: { [string]: NpcHistoryEntry } } = {}

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

	local perNpc: { [string]: NpcHistoryEntry } = {}
	if type(saved) == "table" and type(saved.perNpc) == "table" then
		for npcName, npcData in pairs(saved.perNpc) do
			if type(npcName) == "string" and type(npcData) == "table" and type(npcData.history) == "table" then
				perNpc[npcName] = { history = npcData.history, dirty = false }
			end
		end
	end

	sessionCache[player.UserId] = perNpc
end

local function getOrCreateEntry(player: Player, npc: Model): NpcHistoryEntry
	local perNpc = sessionCache[player.UserId]
	if not perNpc then
		perNpc = {}
		sessionCache[player.UserId] = perNpc
	end

	local entry = perNpc[npc.Name]
	if not entry then
		entry = { history = {}, dirty = false }
		perNpc[npc.Name] = entry
	end

	return entry
end

function ChatMemory.GetHistory(player: Player, npc: Model): { any }
	local perNpc = sessionCache[player.UserId]
	local entry = perNpc and perNpc[npc.Name]
	if not entry then
		return {}
	end
	return entry.history
end

function ChatMemory.AppendTurn(player: Player, npc: Model, role: string, content: string)
	local entry = getOrCreateEntry(player, npc)

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
	local perNpc = sessionCache[player.UserId]
	if not perNpc then
		return
	end

	local anyDirty = false
	local payload = {}
	for npcName, entry in pairs(perNpc) do
		payload[npcName] = { history = entry.history }
		if entry.dirty then
			anyDirty = true
		end
	end

	if not anyDirty then
		return
	end

	safeSetAsync(keyFor(player.UserId), { perNpc = payload })

	for _, entry in pairs(perNpc) do
		entry.dirty = false
	end
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
