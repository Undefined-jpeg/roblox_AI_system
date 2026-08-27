-- Captures player chat near/@mentioning AI NPCs, calls the proxy, displays
-- the reply in the real Roblox chat, and dispatches any whitelisted action.
-- Also handles two turn types beyond direct addressed chat: passively
-- overheard messages elsewhere in server chat (cheap-filtered, rate-limited,
-- see PassiveChatFilter/NpcAutonomy) and self-initiated spontaneous comments
-- (triggered by NpcAutonomy's idle tick, never by a player).
--
-- Input capture uses the legacy Player.Chatted event rather than the newer
-- TextChatService message-received APIs: Chatted still fires reliably even
-- with TextChatService enabled, and its signature hasn't shifted across
-- Roblox versions the way TextChatService's has. Output (displaying the
-- NPC's reply) uses the modern TextChatService APIs.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local ActionConfig = require(script.Parent.ActionConfig)
local ActionExecutor = require(script.Parent.ActionExecutor)
local ChatMemory = require(script.Parent.ChatMemory)
local Config = require(script.Parent.Config)
local GroundUtil = require(script.Parent.GroundUtil)
local NpcDefinitions = require(script.Parent.NpcDefinitions)
local NpcPerception = require(script.Parent.NpcPerception)
local OpenRouterClient = require(script.Parent.OpenRouterClient)
local PassiveChatFilter = require(script.Parent.PassiveChatFilter)
local VehicleChatController = require(script.Parent.VehicleChatController)
local VehicleCommandFilter = require(script.Parent.VehicleCommandFilter)
local VehicleExecutor = require(script.Parent.VehicleExecutor)
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local SharedConfig = require(ReplicatedStorage:WaitForChild("SharedConfig"))

local NpcChatController = {}

local MAX_DISPLAYED_REPLY_CHARS = 300
local SELF_INITIATED_SENTINEL_MESSAGE = "(quiet moment -- no one is talking to you right now)"

-- userId -> last request timestamp (os.clock()), for the per-player direct
-- cooldown. Separate from lastPassiveReplyAt below, which is per-NPC.
local lastRequestAt: { [number]: number } = {}
-- Model -> last passive-reply timestamp (os.clock()). Per-NPC rather than
-- per-player, since passive monitoring is about not spamming from one NPC's
-- perspective across a whole server full of players, not about any single
-- player's cooldown.
local lastPassiveReplyAt: { [Model]: number } = {}

local function sanitizeForChat(text: string): string
	-- Strip characters that could be used to inject rich-text tags into the
	-- chat channel, and cap length for a clean chat-window line.
	local cleaned = text:gsub("[<>]", "")
	if #cleaned > MAX_DISPLAYED_REPLY_CHARS then
		cleaned = cleaned:sub(1, MAX_DISPLAYED_REPLY_CHARS - 1) .. "…"
	end
	return cleaned
end

local function getNpcRootPart(npc: Model): BasePart?
	return npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Picks which NPC (if any) should respond to this message: an explicit
-- "@name" mention wins outright; otherwise the nearest tagged NPC within
-- Config.CHAT_PROXIMITY_STUDS of the speaking player.
local function findRespondingNpc(player: Player, message: string): Model?
	local character = player.Character
	local playerRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local lowerMessage = message:lower()

	local nearestNpc: Model? = nil
	local nearestDistance = math.huge

	for _, npc in ipairs(CollectionService:GetTagged(Config.NPC_TAG)) do
		if npc:IsA("Model") then
			if lowerMessage:find("@" .. npc.Name:lower(), 1, true) then
				return npc
			end

			local npcRoot = getNpcRootPart(npc)
			if playerRoot and npcRoot then
				local distance = (playerRoot.Position - npcRoot.Position).Magnitude
				if distance <= Config.CHAT_PROXIMITY_STUDS and distance < nearestDistance then
					nearestDistance = distance
					nearestNpc = npc
				end
			end
		end
	end

	return nearestNpc
end

-- Nearest tagged NPC within listenRadius, for passive overhearing (doesn't
-- need an @mention -- just proximity to whoever spoke). Vehicle NPCs are
-- deliberately excluded: they're command-driven, not background
-- personalities, and shouldn't spend an LLM call reacting to chat nobody
-- addressed to them.
local function findNearestNpcWithin(player: Player, radiusStuds: number): Model?
	local character = player.Character
	local playerRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not playerRoot then
		return nil
	end

	local nearestNpc: Model? = nil
	local nearestDistance = math.huge

	for _, npc in ipairs(CollectionService:GetTagged(Config.NPC_TAG)) do
		if npc:IsA("Model") and not npc:HasTag(SharedConfig.VEHICLE_TAG) then
			local npcRoot = getNpcRootPart(npc)
			if npcRoot then
				local distance = (playerRoot.Position - npcRoot.Position).Magnitude
				if distance <= radiusStuds and distance < nearestDistance then
					nearestDistance = distance
					nearestNpc = npc
				end
			end
		end
	end

	return nearestNpc
end

local chatMessageEvent = Remotes.GetDisplayNpcChatMessageEvent()

local function displayNpcReply(npc: Model, replyText: string)
	local safeText = sanitizeForChat(replyText)

	-- DisplayBubble requires a BasePart, not a Model -- passing the Model
	-- itself fails with "partOrCharacter is not a legal character" (confirmed
	-- against the live API).
	local npcRoot = getNpcRootPart(npc)
	if npcRoot then
		local bubbleOk, bubbleErr = pcall(function()
			TextChatService:DisplayBubble(npcRoot, safeText)
		end)
		if not bubbleOk then
			warn("[NpcChatController] DisplayBubble failed: " .. tostring(bubbleErr))
		end
	end

	-- TextChannel:DisplaySystemMessage can only be called from the client
	-- (confirmed against the live API), so tell every client to display it
	-- locally rather than calling it here.
	chatMessageEvent:FireAllClients(("[%s]: %s"):format(npc.Name, safeText))
end

local function buildContext(npc: Model, turnType: string): OpenRouterClient.NpcContext
	return {
		turnType = turnType,
		activity = NpcPerception.GetActivityLabel(npc),
		surroundings = NpcPerception.GetSurroundingsText(npc),
		nearbyPlayers = NpcPerception.GetNearbyPlayersText(npc),
	}
end

-- player is nil for self-initiated turns (no one to follow/address).
-- allowedActions narrows the whitelist per turn type: a bystander NPC
-- (passive) or one talking to itself (self-initiated) can do less than one
-- directly addressed by a player.
local function dispatchAction(
	npc: Model,
	player: Player?,
	action: { name: string, params: any }?,
	complied: boolean,
	allowedActions: { [string]: boolean }
)
	-- Vehicle NPCs have a completely different command set (ride/transform/
	-- move_to) and their own state machine (VehicleExecutor) -- route there
	-- entirely instead of falling into the talking-NPC branches below.
	if NpcDefinitions.Get(npc).vehicle then
		VehicleChatController.Dispatch(npc, player, action, complied, allowedActions)
		return
	end

	if complied == false then
		return
	end

	if type(action) ~= "table" or type(action.name) ~= "string" then
		return
	end

	if not allowedActions[action.name] then
		warn("[NpcChatController] Rejected action outside this turn's whitelist: " .. tostring(action.name))
		return
	end

	if action.name == "follow_player" then
		if not player then
			return
		end
		ActionExecutor.FollowPlayer(npc, player)
		NpcPerception.SetFollowTargetName(npc, player.DisplayName)
	elseif action.name == "stop" then
		ActionExecutor.Stop(npc)
		NpcPerception.SetFollowTargetName(npc, nil)
	elseif action.name == "wander" then
		local npcRoot = getNpcRootPart(npc)
		if npcRoot then
			local target = GroundUtil.PickRandomPointNear(npcRoot.Position, Config.WANDER_RADIUS_STUDS)
			if target then
				ActionExecutor.Wander(npc, target)
			end
		end
	elseif action.name == "play_emote" then
		local emote = type(action.params) == "table" and action.params.emote
		if type(emote) == "string" and ActionConfig.EMOTES[emote] then
			ActionExecutor.PlayEmote(npc, emote)
		else
			warn("[NpcChatController] Rejected invalid emote param: " .. tostring(emote))
		end
	end
end

local function handlePassiveOverhear(player: Player, message: string)
	if not PassiveChatFilter.ShouldConsider(message) then
		return
	end

	local npc = findNearestNpcWithin(player, Config.PASSIVE_LISTEN_STUDS)
	if not npc then
		return
	end

	local now = os.clock()
	local last = lastPassiveReplyAt[npc]
	if last and (now - last) < Config.PASSIVE_CHAT_COOLDOWN_SECONDS then
		return
	end

	if math.random() >= Config.PASSIVE_RESPONSE_CHANCE then
		return
	end

	lastPassiveReplyAt[npc] = now

	-- Captured before the (yielding) proxy call so we can tell, on return,
	-- whether something else -- most importantly a player's own direct
	-- command -- has since changed what this NPC is doing. A stale
	-- overheard reaction should never clobber a fresher, more important
	-- state change.
	local generationAtRequest = ActionExecutor.GetGeneration(npc)
	local def = NpcDefinitions.Get(npc)

	task.spawn(function()
		local result = OpenRouterClient.RequestChat(message, {}, buildContext(npc, "passive_overheard"), def.persona)
		if ActionExecutor.GetGeneration(npc) ~= generationAtRequest then
			return
		end
		displayNpcReply(npc, result.reply)
		dispatchAction(npc, player, result.action, result.complied, def.passiveActions)
		-- No ChatMemory write: this wasn't a real conversation with `player`.
	end)
end

local function handleChatted(player: Player, message: string)
	if type(message) ~= "string" or message == "" then
		return
	end

	local npc = findRespondingNpc(player, message)
	if not npc then
		handlePassiveOverhear(player, message)
		return
	end

	local now = os.clock()
	local last = lastRequestAt[player.UserId]
	if last and (now - last) < Config.CHAT_COOLDOWN_SECONDS then
		return
	end

	-- A powered-down vehicle should never spend an LLM call on ordinary
	-- chat it can't act on anyway -- only a plausible "wake up" phrase
	-- reaches the proxy at all, and even then with the whitelist narrowed
	-- to transform_up only for this one call.
	local def = NpcDefinitions.Get(npc)
	local allowedActions = def.chatActions
	if VehicleExecutor.GetMode(npc) == "Unresponsive" then
		if not VehicleCommandFilter.IsWakePhrase(message) then
			return
		end
		allowedActions = { transform_up = true }
	end

	lastRequestAt[player.UserId] = now

	-- RequestAsync yields, so run off the chat-event thread.
	task.spawn(function()
		local history = ChatMemory.GetHistory(player)
		local result = OpenRouterClient.RequestChat(message, history, buildContext(npc, "direct"), def.persona)

		displayNpcReply(npc, result.reply)
		dispatchAction(npc, player, result.action, result.complied, allowedActions)

		ChatMemory.AppendTurn(player, "user", message)
		ChatMemory.AppendTurn(player, "assistant", result.reply)
	end)
end

-- Called by NpcAutonomy's idle tick (rate-limited there) when the NPC
-- decides, unprompted, to say something. No player addressed it, so no
-- ChatMemory write and a narrower action whitelist.
function NpcChatController.SpeakSpontaneously(npc: Model)
	-- Same staleness guard as handlePassiveOverhear: NpcAutonomy only calls
	-- this while genuinely Idle, but the proxy round-trip yields, and a
	-- player's direct command can arrive and change the NPC's behavior
	-- before this self-initiated decision comes back. Without this check,
	-- a late "I'll wander off" could silently cancel a fresh "follow me".
	local generationAtRequest = ActionExecutor.GetGeneration(npc)
	local def = NpcDefinitions.Get(npc)

	local result = OpenRouterClient.RequestChat(
		SELF_INITIATED_SENTINEL_MESSAGE,
		{},
		buildContext(npc, "self_initiated"),
		def.persona
	)

	if ActionExecutor.GetGeneration(npc) ~= generationAtRequest then
		return
	end

	displayNpcReply(npc, result.reply)
	dispatchAction(npc, nil, result.action, result.complied, def.selfActions)
end

function NpcChatController.Start()
	local function onPlayerAdded(player: Player)
		ChatMemory.Load(player)
		player.Chatted:Connect(function(message)
			handleChatted(player, message)
		end)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		ChatMemory.Unload(player)
		lastRequestAt[player.UserId] = nil
	end)
end

return NpcChatController
