-- Shared ground-truth raycast helper. Never trust a position (from a client,
-- or from randomly-generated wander math) without re-deriving where the
-- actual walkable surface is -- this is the same technique NpcMoveHandler
-- always used for click-to-move, factored out so autonomous wandering can
-- reuse it instead of re-implementing (and potentially drifting from) it.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local GroundUtil = {}

local GROUND_CHECK_HEIGHT = 50
local GROUND_CHECK_DEPTH = 100
local GROUND_TOLERANCE_STUDS = 5

-- Re-derives the real ground position under claimedPosition via a downward
-- raycast, rather than trusting its Y coordinate. Returns nil if there's no
-- walkable surface reasonably close (e.g. claimedPosition floats in the sky,
-- or is otherwise not actually on solid ground).
function GroundUtil.ResolveGroundPosition(claimedPosition: Vector3): Vector3?
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

-- Picks a random point within radiusStuds of origin (on a flat XZ disc) and
-- validates it lands on real ground. Returns nil if the randomly-chosen spot
-- doesn't resolve to solid ground -- callers should just skip that attempt
-- rather than retry indefinitely (there will be another tick).
function GroundUtil.PickRandomPointNear(origin: Vector3, radiusStuds: number): Vector3?
	local angle = math.random() * math.pi * 2
	local distance = math.random() * radiusStuds
	local candidate = origin + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
	return GroundUtil.ResolveGroundPosition(candidate)
end

return GroundUtil
