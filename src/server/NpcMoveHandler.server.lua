-- Server-side half of the click-to-move feature. Never trusts the client's
-- claimed position outright: re-validates that it's a real walkable spot
-- (via its own downward raycast) and within range of the target NPC before
-- moving anything.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script.Parent.Config)
local ActionExecutor = require(script.Parent.ActionExecutor)
local GroundUtil = require(script.Parent.GroundUtil)
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

-- userId -> last move-request timestamp (os.clock()), for per-player cooldown.
local lastMoveRequestAt: { [number]: number } = {}

local function getNpcRootPart(npc: Model): BasePart?
	return npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function onMoveNpcRequest(player: Player, npc: Instance, claimedPosition: Vector3)
	if typeof(npc) ~= "Instance" or not npc:IsA("Model") or not npc:HasTag(Config.NPC_TAG) then
		warn(("[NpcMoveHandler] %s sent a move request for a non-NPC instance"):format(player.Name))
		return
	end

	if typeof(claimedPosition) ~= "Vector3" then
		warn(("[NpcMoveHandler] %s sent a malformed position"):format(player.Name))
		return
	end

	local now = os.clock()
	local last = lastMoveRequestAt[player.UserId]
	if last and (now - last) < Config.MOVE_COOLDOWN_SECONDS then
		return
	end
	lastMoveRequestAt[player.UserId] = now

	local npcRoot = getNpcRootPart(npc)
	if not npcRoot then
		return
	end

	local groundPosition = GroundUtil.ResolveGroundPosition(claimedPosition)
	if not groundPosition then
		warn(
			("[NpcMoveHandler] Rejected move request from %s: no walkable surface near claimed position"):format(
				player.Name
			)
		)
		return
	end

	local distance = (npcRoot.Position - groundPosition).Magnitude
	if distance > Config.MAX_MOVE_DISTANCE_STUDS then
		warn(
			("[NpcMoveHandler] Rejected move request from %s: %d studs exceeds max range"):format(player.Name, distance)
		)
		return
	end

	ActionExecutor.GotoPosition(npc, groundPosition)
end

local moveEvent = Remotes.GetMoveNpcRequestEvent()
moveEvent.OnServerEvent:Connect(onMoveNpcRequest)

local function onPlayerRemoving(player: Player)
	lastMoveRequestAt[player.UserId] = nil
end
Players.PlayerRemoving:Connect(onPlayerRemoving)
