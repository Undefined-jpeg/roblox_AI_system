-- Drives all autonomous NPC behavior: wandering, examining nearby objects,
-- and (rarely, rate-limited) spontaneous unprompted comments. Everything in
-- this module's main tick is pure Luau -- no LLM call -- except the gated
-- spontaneous-comment path, which is capped by both a cooldown and a dice
-- roll so an always-idle NPC costs at most a handful of OpenRouter calls per
-- hour, not one per tick.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ActionExecutor = require(script.Parent.ActionExecutor)
local Config = require(script.Parent.Config)
local GroundUtil = require(script.Parent.GroundUtil)
local NpcPerception = require(script.Parent.NpcPerception)

local NpcAutonomy = {}

-- Model -> os.clock() of the last spontaneous-comment LLM call, for the
-- per-NPC cost-control cooldown.
local lastThoughtAt: { [Model]: number } = {}
-- Model -> os.clock() this NPC was last observed to be Idle, used as an
-- approximation of "how long has it been idle" (granularity = tick interval).
local idleSinceAt: { [Model]: number } = {}

local function getNpcRootPart(npc: Model): BasePart?
	return npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- True if `part` belongs to any character (the NPC's own rig or a player's) --
-- we don't want "examine" picking a body part, only genuine world props.
local function isCharacterPart(part: BasePart): boolean
	local model = part:FindFirstAncestorOfClass("Model")
	if not model then
		return false
	end
	if model:FindFirstChildOfClass("Humanoid") then
		return true
	end
	return false
end

local function pickNearbyExaminablePart(npc: Model): BasePart?
	local npcRoot = getNpcRootPart(npc)
	if not npcRoot then
		return nil
	end

	local candidates = {}
	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant:IsA("BasePart") and not isCharacterPart(descendant) then
			local distance = (npcRoot.Position - descendant.Position).Magnitude
			if distance <= Config.EXAMINE_RADIUS_STUDS then
				table.insert(candidates, descendant)
			end
		end
	end

	if #candidates == 0 then
		return nil
	end

	return candidates[math.random(1, #candidates)]
end

local function isAnyPlayerNearby(npc: Model): boolean
	local npcRoot = getNpcRootPart(npc)
	if not npcRoot then
		return false
	end

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local playerRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if playerRoot and (npcRoot.Position - playerRoot.Position).Magnitude <= Config.NEARBY_PLAYERS_RADIUS_STUDS then
			return true
		end
	end

	return false
end

local function maybeSpeakSpontaneously(npc: Model)
	local now = os.clock()
	local idleSince = idleSinceAt[npc]
	if not idleSince or (now - idleSince) < Config.AUTONOMY_THOUGHT_MIN_IDLE_SECONDS then
		return
	end

	local lastThought = lastThoughtAt[npc]
	if lastThought and (now - lastThought) < Config.AUTONOMY_THOUGHT_INTERVAL_SECONDS then
		return
	end

	if math.random() >= Config.AUTONOMY_THOUGHT_CHANCE then
		return
	end

	if not isAnyPlayerNearby(npc) then
		return
	end

	lastThoughtAt[npc] = now

	-- Required late so NpcAutonomy (required by NpcInit before NpcChatController
	-- in practice) never hits a require-cycle at module-load time.
	local NpcChatController = require(script.Parent.NpcChatController)
	task.spawn(function()
		NpcChatController.SpeakSpontaneously(npc)
	end)
end

local function tick(npc: Model)
	local mode = ActionExecutor.GetMode(npc)

	if mode ~= "Idle" then
		idleSinceAt[npc] = nil
		return
	end

	if not idleSinceAt[npc] then
		idleSinceAt[npc] = os.clock()
	end

	NpcPerception.RefreshNearbyPlayers(npc)
	maybeSpeakSpontaneously(npc)

	local npcRoot = getNpcRootPart(npc)
	if not npcRoot then
		return
	end

	local roll = math.random()
	if roll < Config.WANDER_CHANCE then
		local target = GroundUtil.PickRandomPointNear(npcRoot.Position, Config.WANDER_RADIUS_STUDS)
		if target then
			ActionExecutor.Wander(npc, target)
		end
	elseif roll < Config.WANDER_CHANCE + Config.EXAMINE_CHANCE then
		local part = pickNearbyExaminablePart(npc)
		if part then
			ActionExecutor.Examine(npc, Config.EXAMINE_DURATION_SECONDS)
			NpcPerception.RefreshSurroundings(npc, part)
		end
	end
	-- Remaining probability: stay idle this tick.
end

local function startLoopFor(npc: Model)
	task.spawn(function()
		while npc.Parent do
			task.wait(math.random(Config.AUTONOMY_TICK_MIN_SECONDS, Config.AUTONOMY_TICK_MAX_SECONDS))
			local ok, err = pcall(tick, npc)
			if not ok then
				warn("[NpcAutonomy] tick error for " .. npc.Name .. ": " .. tostring(err))
			end
		end
		lastThoughtAt[npc] = nil
		idleSinceAt[npc] = nil
	end)
end

function NpcAutonomy.Start()
	for _, npc in ipairs(CollectionService:GetTagged(Config.NPC_TAG)) do
		-- Vehicle NPCs never wander/examine/self-initiate chatter -- they're
		-- command-driven, and their movement/animation is owned by
		-- VehicleExecutor instead.
		if npc:IsA("Model") and not npc:HasTag(Config.VEHICLE_TAG) then
			startLoopFor(npc)
		end
	end

	CollectionService:GetInstanceAddedSignal(Config.NPC_TAG):Connect(function(npc)
		if npc:IsA("Model") and not npc:HasTag(Config.VEHICLE_TAG) then
			startLoopFor(npc)
		end
	end)
end

return NpcAutonomy
