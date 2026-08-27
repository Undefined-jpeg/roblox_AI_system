-- Executes NPC actions. Every entry point here assumes its inputs have
-- ALREADY been validated/whitelisted by the caller (NpcChatController /
-- NpcMoveHandler) -- this module trusts its arguments.

local PathfindingService = game:GetService("PathfindingService")

local ActionConfig = require(script.Parent.ActionConfig)

local ActionExecutor = {}

-- Per-NPC behavior state, keyed by the NPC Model instance.
-- `generation` is bumped every time a new behavior starts, so a stale
-- coroutine from a previous behavior (e.g. an old Follow loop) knows to
-- stop even if it's mid-wait when interrupted.
type NpcState = {
	mode: "Idle" | "Following" | "Moving" | "Wandering" | "Examining",
	generation: number,
	followTarget: Player?,
}

local states: { [Model]: NpcState } = {}

local function getState(npc: Model): NpcState
	local state = states[npc]
	if not state then
		state = { mode = "Idle", generation = 0, followTarget = nil }
		states[npc] = state
	end
	return state
end

-- Read-only accessor so other modules (the autonomy tick, perception) can
-- check what an NPC is currently doing without reaching into this module's
-- private `states` table.
function ActionExecutor.GetMode(npc: Model): string
	return getState(npc).mode
end

-- Read-only accessor for detecting staleness: an async LLM call can capture
-- this before making its request, then compare on return to tell whether
-- something else (a player command, a newer autonomous decision) already
-- changed the NPC's behavior while the call was in flight.
function ActionExecutor.GetGeneration(npc: Model): number
	return getState(npc).generation
end

local function getHumanoid(npc: Model): Humanoid?
	return npc:FindFirstChildOfClass("Humanoid")
end

local function getRootPart(npc: Model): BasePart?
	return npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Walks the humanoid along a computed path to targetPosition. Bails out
-- early (returns false) if `generation` no longer matches the NPC's current
-- generation, meaning some other action superseded this one mid-walk.
local function walkTo(npc: Model, targetPosition: Vector3, generation: number): boolean
	local humanoid = getHumanoid(npc)
	local rootPart = getRootPart(npc)
	if not humanoid or not rootPart then
		return false
	end

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
	})

	local ok = pcall(function()
		path:ComputeAsync(rootPart.Position, targetPosition)
	end)

	if not ok or path.Status ~= Enum.PathStatus.Success then
		return false
	end

	for _, waypoint in ipairs(path:GetWaypoints()) do
		if states[npc] == nil or states[npc].generation ~= generation then
			return false -- superseded
		end

		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end

		humanoid:MoveTo(waypoint.Position)
		local reached = humanoid.MoveToFinished:Wait(2)
		if not reached then
			-- Timed out on this waypoint (e.g. stuck); recompute from here
			-- next loop rather than getting stuck forever.
			return false
		end
	end

	return true
end

function ActionExecutor.Stop(npc: Model)
	local state = getState(npc)
	state.mode = "Idle"
	state.followTarget = nil
	state.generation += 1

	local humanoid = getHumanoid(npc)
	local rootPart = getRootPart(npc)
	if humanoid and rootPart then
		humanoid:MoveTo(rootPart.Position)
	end
end

function ActionExecutor.GotoPosition(npc: Model, targetPosition: Vector3)
	local state = getState(npc)
	state.mode = "Moving"
	state.followTarget = nil
	state.generation += 1
	local myGeneration = state.generation

	task.spawn(function()
		walkTo(npc, targetPosition, myGeneration)
		-- If nothing superseded us, go back to idle when we arrive/give up.
		if states[npc] and states[npc].generation == myGeneration then
			states[npc].mode = "Idle"
		end
	end)
end

-- Identical to GotoPosition except for the mode label -- kept as a separate
-- entry point so callers (and anything inspecting GetMode) can distinguish
-- "the NPC decided to wander here on its own" from "a player clicked here".
function ActionExecutor.Wander(npc: Model, targetPosition: Vector3)
	local state = getState(npc)
	state.mode = "Wandering"
	state.followTarget = nil
	state.generation += 1
	local myGeneration = state.generation

	task.spawn(function()
		walkTo(npc, targetPosition, myGeneration)
		if states[npc] and states[npc].generation == myGeneration then
			states[npc].mode = "Idle"
		end
	end)
end

-- Pauses the NPC in place for a beat (e.g. while "looking at" something it's
-- examining). Reverts to Idle afterward unless superseded mid-pause.
function ActionExecutor.Examine(npc: Model, durationSeconds: number)
	local state = getState(npc)
	state.mode = "Examining"
	state.followTarget = nil
	state.generation += 1
	local myGeneration = state.generation

	task.spawn(function()
		task.wait(durationSeconds)
		if states[npc] and states[npc].generation == myGeneration then
			states[npc].mode = "Idle"
		end
	end)
end

function ActionExecutor.FollowPlayer(npc: Model, player: Player)
	local state = getState(npc)
	state.mode = "Following"
	state.followTarget = player
	state.generation += 1
	local myGeneration = state.generation

	local RECOMPUTE_INTERVAL = 1.5
	local STOP_DISTANCE = 6

	task.spawn(function()
		while states[npc] and states[npc].generation == myGeneration do
			local character = player.Character
			local rootPart = getRootPart(npc)
			local targetRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?

			if not character or not targetRoot or not rootPart then
				task.wait(RECOMPUTE_INTERVAL)
				continue
			end

			local distance = (rootPart.Position - targetRoot.Position).Magnitude
			if distance > STOP_DISTANCE then
				walkTo(npc, targetRoot.Position, myGeneration)
			end

			task.wait(RECOMPUTE_INTERVAL)
		end
	end)
end

function ActionExecutor.PlayEmote(npc: Model, emoteName: string)
	local assetId = ActionConfig.EMOTES[emoteName]
	if not assetId then
		warn("[ActionExecutor] Unknown emote: " .. tostring(emoteName))
		return
	end

	local humanoid = getHumanoid(npc)
	if not humanoid then
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = assetId

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	if ok and track then
		track:Play()
		track.Stopped:Once(function()
			animation:Destroy()
		end)
	else
		animation:Destroy()
	end
end

return ActionExecutor
