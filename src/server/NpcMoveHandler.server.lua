-- Server-side half of the click-to-move feature. Never trusts the client's
-- claimed position outright: re-validates that it's a real walkable spot
-- (via its own downward raycast) and within range of the target NPC before
-- moving anything.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.Config)
local ActionExecutor = require(script.Parent.ActionExecutor)
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local GROUND_CHECK_HEIGHT = 50
local GROUND_CHECK_DEPTH = 100
local GROUND_TOLERANCE_STUDS = 5

-- userId -> last move-request timestamp (os.clock()), for per-player cooldown.
local lastMoveRequestAt: { [number]: number } = {}

local function getNpcRootPart(npc: Model): BasePart?
	return npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Re-derives the real ground position under the client's claimed click point,
-- rather than trusting the client's Y coordinate. Returns nil if there's no
-- walkable surface reasonably close to the claimed position (e.g. the client
-- claimed a point floating in the sky, or lied about the position entirely).
local function resolveGroundPosition(claimedPosition: Vector3): Vector3?
	local rayOrigin = claimedPosition + Vector3.new(0, GROUND_CHECK_HEIGHT, 0)
	local rayDirection = Vector3.new(0, -GROUND_CHECK_DEPTH, 0)

	-- Exclude player characters so the ground check can't be fooled by
	-- ray-hitting a player's body instead of the actual floor beneath them.
	local excludeList = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then
			table.insert(excludeList, plr.Character)
		end
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = excludeList

	local result = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
	if not result then
		return nil
	end

	if math.abs(result.Position.Y - claimedPosition.Y) > GROUND_TOLERANCE_STUDS then
		return nil
	end

	return result.Position
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

	local groundPosition = resolveGroundPosition(claimedPosition)
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
game:GetService("Players").PlayerRemoving:Connect(onPlayerRemoving)
