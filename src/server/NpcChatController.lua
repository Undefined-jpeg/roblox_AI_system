-- Captures player chat near/@mentioning AI NPCs, calls the proxy, displays
-- the reply in the real Roblox chat, and dispatches any whitelisted action.
--
-- Input capture uses the legacy Player.Chatted event rather than the newer
-- TextChatService message-received APIs: Chatted still fires reliably even
-- with TextChatService enabled, and its signature hasn't shifted across
-- Roblox versions the way TextChatService's has. Output (displaying the
-- NPC's reply) uses the modern TextChatService APIs.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local Config = require(script.Parent.Config)
local ActionConfig = require(script.Parent.ActionConfig)
local ActionExecutor = require(script.Parent.ActionExecutor)
local ChatMemory = require(script.Parent.ChatMemory)
local OpenRouterClient = require(script.Parent.OpenRouterClient)

local NpcChatController = {}

local MAX_DISPLAYED_REPLY_CHARS = 300

-- userId -> last request timestamp (os.clock()), for per-player cooldown.
local lastRequestAt: { [number]: number } = {}

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

local function displayNpcReply(npc: Model, replyText: string)
	local safeText = sanitizeForChat(replyText)

	local bubbleOk, bubbleErr = pcall(function()
		TextChatService:DisplayBubble(npc, safeText)
	end)
	if not bubbleOk then
		warn("[NpcChatController] DisplayBubble failed: " .. tostring(bubbleErr))
	end

	local generalChannel = TextChatService.TextChannels:FindFirstChild("RBXGeneral")
	if generalChannel then
		local channelOk, channelErr = pcall(function()
			generalChannel:DisplaySystemMessage(("[%s]: %s"):format(npc.Name, safeText))
		end)
		if not channelOk then
			warn("[NpcChatController] DisplaySystemMessage failed: " .. tostring(channelErr))
		end
	end
end

local function dispatchAction(npc: Model, player: Player, action: { name: string, params: any }?)
	if type(action) ~= "table" or type(action.name) ~= "string" then
		return
	end

	if not ActionConfig.CHAT_ACTIONS[action.name] then
		warn("[NpcChatController] Rejected non-whitelisted action: " .. tostring(action.name))
		return
	end

	if action.name == "follow_player" then
		ActionExecutor.FollowPlayer(npc, player)
	elseif action.name == "stop" then
		ActionExecutor.Stop(npc)
	elseif action.name == "play_emote" then
		local emote = type(action.params) == "table" and action.params.emote
		if type(emote) == "string" and ActionConfig.EMOTES[emote] then
			ActionExecutor.PlayEmote(npc, emote)
		else
			warn("[NpcChatController] Rejected invalid emote param: " .. tostring(emote))
		end
	end
end

local function handleChatted(player: Player, message: string)
	if type(message) ~= "string" or message == "" then
		return
	end

	local npc = findRespondingNpc(player, message)
	if not npc then
		return
	end

	local now = os.clock()
	local last = lastRequestAt[player.UserId]
	if last and (now - last) < Config.CHAT_COOLDOWN_SECONDS then
		return
	end
	lastRequestAt[player.UserId] = now

	-- RequestAsync yields, so run off the chat-event thread.
	task.spawn(function()
		local history = ChatMemory.GetHistory(player)
		local result = OpenRouterClient.RequestChat(message, history)

		displayNpcReply(npc, result.reply)
		dispatchAction(npc, player, result.action)

		ChatMemory.AppendTurn(player, "user", message)
		ChatMemory.AppendTurn(player, "assistant", result.reply)
	end)
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
