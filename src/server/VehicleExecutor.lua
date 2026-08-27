-- Owns transform/mount/drive state for rideable vehicle NPCs (e.g. Eight).
-- Deliberately separate from ActionExecutor's NpcState: flight and manual
-- driving don't fit a Humanoid-pathfinding-oriented state machine. Ground
-- movement (Follow/MoveTo) while NOT mounted still goes through
-- ActionExecutor directly, since that part really is just normal walking.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ActionExecutor = require(script.Parent.ActionExecutor)
local Config = require(script.Parent.Config)
local NpcDefinitions = require(script.Parent.NpcDefinitions)

local VehicleExecutor = {}

-- generation is bumped on every mode change so any pending async work
-- (a spawn/reverse-spawn animation chain) can detect it's been superseded,
-- mirroring the pattern already established in ActionExecutor.lua.
type VehicleState = {
	mode: "Unresponsive" | "Idle" | "AwaitingRider" | "Mounted",
	generation: number,
	rider: Player?,
	idleTrack: AnimationTrack?,
	moveTrack: AnimationTrack?,
	baseHipHeight: number,
	linearVelocity: LinearVelocity?,
	angularVelocity: AngularVelocity?,
	antiGravity: VectorForce?,
}

local states: { [Model]: VehicleState } = {}

function VehicleExecutor.GetMode(npc: Model): string?
	local state = states[npc]
	return state and state.mode
end

local function getHumanoid(npc: Model): Humanoid?
	return npc:FindFirstChildOfClass("Humanoid")
end

local function getRootPart(npc: Model): BasePart?
	return npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Loads an Animation by asset id and returns the track, or nil (with a warn)
-- if the id is missing/empty or loading fails -- mirrors
-- ActionExecutor.PlayEmote's graceful-skip behavior for an unset asset id,
-- which matters here since the vehicle's animations start out unpublished.
-- Unlike PlayEmote, the temporary Animation instance is destroyed
-- immediately after loading rather than on Stopped: a looped idle track
-- never naturally stops, and LoadAnimation copies keyframe data into the
-- track at load time, so the source Animation instance isn't needed after.
local function loadAnim(npc: Model, assetId: string): AnimationTrack?
	if assetId == "" then
		warn(("[VehicleExecutor] No animation id configured for %s -- skipping"):format(npc.Name))
		return nil
	end

	local humanoid = getHumanoid(npc)
	if not humanoid then
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = assetId

	local ok, trackOrErr = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	animation:Destroy()

	if not ok then
		warn("[VehicleExecutor] Failed to load animation for " .. npc.Name .. ": " .. tostring(trackOrErr))
		return nil
	end

	return trackOrErr :: AnimationTrack
end

-- "Stay upright ALWAYS" per explicit requirement -- not best-effort. Two
-- prior attempts (a static-goal AlignOrientation, then a continuously-
-- updated-goal AlignOrientation with tuned MaxTorque/Responsiveness) both
-- failed live -- confirmed by screenshot, the assembly ended up fully
-- upside-down under a seated rider's weight. Soft torque-based constraints
-- can lose that fight depending on mass/tuning; this instead HARD-SETS the
-- root part's rotation directly every single frame (while powered on),
-- preserving actual position/velocity but overwriting tilt unconditionally
-- -- not a negotiation with the physics solver, a guarantee. Yaw is left
-- exactly as whatever it currently is (derived from the part's own live
-- LookVector, flattened) so it never fights the Humanoid's own turning
-- while walking, nor the dedicated AngularVelocity constraint while driving
-- -- only pitch/roll ever get corrected.
local function startUprightLoop(npc: Model)
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function()
		if not npc.Parent then
			connection:Disconnect()
			return
		end

		local state = states[npc]
		if not state then
			return
		end

		local rootPart = getRootPart(npc)
		if not rootPart then
			return
		end

		if state.antiGravity and state.antiGravity.Enabled then
			state.antiGravity.Force = Vector3.new(0, rootPart.AssemblyMass * Workspace.Gravity, 0)
		end

		if state.mode == "Unresponsive" then
			return
		end

		-- Confirmed live: hard-snapping every single frame (even while
		-- already level) reset the part's velocity each time -- visible as
		-- both aggressive jitter and the vehicle failing to actually travel
		-- despite LinearVelocity being set. Only correct when genuinely
		-- tilted, lerp toward level instead of snapping, and explicitly
		-- restore velocity across the write so driving isn't interrupted.
		local upDot = rootPart.CFrame.UpVector:Dot(Vector3.new(0, 1, 0))
		if upDot < 0.999 then
			local lookVector = rootPart.CFrame.LookVector
			local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
			if flatLook.Magnitude > 0.001 then
				local targetCFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + flatLook)
				local savedLinearVelocity = rootPart.AssemblyLinearVelocity
				local savedAngularVelocity = rootPart.AssemblyAngularVelocity
				rootPart.CFrame = rootPart.CFrame:Lerp(targetCFrame, 0.35)
				rootPart.AssemblyLinearVelocity = savedLinearVelocity
				rootPart.AssemblyAngularVelocity = savedAngularVelocity
			end
		end
	end)
end

-- Raises/lowers standing height via Humanoid.HipHeight -- Roblox's own
-- ground-clearance mechanic, so it naturally applies while walking/
-- pathfinding (Idle/Following/Moving/AwaitingRider) with no extra physics
-- needed. Has no effect while Mounted (PlatformStand disables normal
-- Humanoid ground-tracking there; altitude is fully player-controlled via
-- E/Q instead).
local function setHovering(npc: Model, state: VehicleState, hovering: boolean, hoverHeightStuds: number)
	local humanoid = getHumanoid(npc)
	if not humanoid then
		return
	end
	humanoid.HipHeight = hovering and (state.baseHipHeight + hoverHeightStuds) or state.baseHipHeight
end

local function dismountRider(npc: Model)
	local state = states[npc]
	if not state or state.mode ~= "Mounted" then
		return
	end

	local humanoid = getHumanoid(npc)
	local rootPart = getRootPart(npc)

	if humanoid then
		humanoid.PlatformStand = false
	end
	if rootPart then
		pcall(function()
			rootPart:SetNetworkOwner(nil)
		end)
	end
	if state.linearVelocity then
		state.linearVelocity.VectorVelocity = Vector3.zero
		state.linearVelocity.Enabled = false
	end
	if state.angularVelocity then
		state.angularVelocity.AngularVelocity = Vector3.zero
		state.angularVelocity.Enabled = false
	end
	if state.antiGravity then
		state.antiGravity.Enabled = false
	end
	-- The upright-correction Heartbeat loop (startUprightLoop) is intentionally
	-- untouched here -- it stays active continuously through Idle/
	-- AwaitingRider/Mounted purely by checking state.mode itself each frame,
	-- only stopping once mode reaches "Unresponsive" via transform down.

	state.mode = "Idle"
	state.rider = nil
	state.generation += 1
end

local function mountRider(npc: Model, player: Player)
	local state = states[npc]
	if not state then
		return
	end

	local humanoid = getHumanoid(npc)
	local rootPart = getRootPart(npc)

	ActionExecutor.Stop(npc)

	if humanoid then
		humanoid.PlatformStand = true
	end
	if rootPart then
		rootPart:SetNetworkOwner(player)
	end
	if state.linearVelocity then
		state.linearVelocity.VectorVelocity = Vector3.zero
		state.linearVelocity.Enabled = true
	end
	if state.angularVelocity then
		state.angularVelocity.AngularVelocity = Vector3.zero
		state.angularVelocity.Enabled = true
	end
	if state.antiGravity and rootPart then
		-- Seed an immediate correct value rather than waiting for the next
		-- Heartbeat tick (which also keeps it updated as mass changes, e.g.
		-- the rider's own character joining this physics assembly).
		state.antiGravity.Force = Vector3.new(0, rootPart.AssemblyMass * Workspace.Gravity, 0)
		state.antiGravity.Enabled = true
	end

	state.mode = "Mounted"
	state.rider = player
	state.generation += 1
end

local function onOccupantChanged(npc: Model, seat: Seat)
	local state = states[npc]
	if not state then
		return
	end

	local occupant = seat.Occupant
	if occupant then
		local player = occupant.Parent and Players:GetPlayerFromCharacter(occupant.Parent)
		-- Refuse: not a real player's Humanoid, powered down, or already
		-- has a rider. The seat itself is the enforcement point for
		-- "unresponsive blocks manual riding too."
		if not player or state.mode == "Unresponsive" or state.mode == "Mounted" then
			occupant.Sit = false
			return
		end
		mountRider(npc, player)
	else
		dismountRider(npc)
	end
end

function VehicleExecutor.TransformUp(npc: Model)
	local state = states[npc]
	local def = NpcDefinitions.Get(npc).vehicle
	if not state or not def then
		return
	end
	if state.mode ~= "Unresponsive" then
		return
	end

	state.generation += 1
	local myGeneration = state.generation
	state.mode = "Idle"

	-- Engage immediately (not after the animation finishes) -- transforming
	-- up is what makes it responsive/active at all. (Upright correction
	-- itself needs no explicit "enable" call -- startUprightLoop checks
	-- state.mode directly every frame, and mode is already "Idle" here.)
	setHovering(npc, state, true, def.hoverHeightStuds)

	task.spawn(function()
		local track = loadAnim(npc, def.animations.spawn)
		if track then
			track:Play()
			-- AnimationTrack has no "Completed" event (that's Tween-only) --
			-- "Stopped" is what fires when a non-looped track finishes
			-- playing, confirmed live. Using the wrong event name here threw
			-- inside this task.spawn'd coroutine and silently killed it
			-- before the idle animation below ever ran.
			track.Stopped:Wait()
		end

		if not (states[npc] and states[npc].generation == myGeneration) then
			return
		end

		if def.animations.idle ~= "" then
			-- Defensive: don't accumulate duplicate looped idle tracks if
			-- TransformUp ever ends up triggered twice in close succession.
			if states[npc].idleTrack then
				states[npc].idleTrack:Stop()
			end

			local idleTrack = loadAnim(npc, def.animations.idle)
			if idleTrack then
				idleTrack.Looped = true
				idleTrack:Play()
				states[npc].idleTrack = idleTrack
			end
		end
	end)
end

function VehicleExecutor.TransformBack(npc: Model)
	local state = states[npc]
	local def = NpcDefinitions.Get(npc).vehicle
	if not state or not def then
		return
	end
	if state.mode == "Unresponsive" then
		return
	end

	local seat = npc:FindFirstChildWhichIsA("Seat")
	if seat and seat.Occupant then
		-- Dismount synchronously here rather than relying solely on the
		-- Occupant-changed signal (which fires asynchronously) -- this
		-- function needs cleanup done before it proceeds, not "eventually."
		-- The signal will also fire and call dismountRider again, which is
		-- a safe no-op by then (mode is no longer "Mounted").
		seat.Occupant.Sit = false
		dismountRider(npc)
	end

	ActionExecutor.Stop(npc)

	if state.idleTrack then
		state.idleTrack:Stop()
		state.idleTrack = nil
	end

	state.generation += 1
	local myGeneration = state.generation
	state.mode = "Idle" -- stays non-Unresponsive until the reverse animation actually finishes

	task.spawn(function()
		local track = loadAnim(npc, def.animations.spawn)
		if track then
			track:Play()
			track.TimePosition = track.Length
			track:AdjustSpeed(-1)
			track.Stopped:Wait()
		end

		if states[npc] and states[npc].generation == myGeneration then
			local currentState = states[npc]
			currentState.mode = "Unresponsive"
			-- Only now does it actually "fall down as usual" -- mode
			-- becoming "Unresponsive" is what stops startUprightLoop's
			-- correction (it checks state.mode directly), and losing the
			-- hover height at the same moment, right as the transform-down
			-- animation finishes, so it settles/topples via normal gravity
			-- instead of visibly fighting the animation.
			setHovering(npc, currentState, false, def.hoverHeightStuds)
		end
	end)
end

function VehicleExecutor.Ride(npc: Model, player: Player)
	local state = states[npc]
	local def = NpcDefinitions.Get(npc).vehicle
	if not state or not def then
		return
	end
	if state.mode == "Unresponsive" or state.mode == "Mounted" then
		return
	end

	state.mode = "AwaitingRider"
	ActionExecutor.FollowPlayer(npc, player, def.rideApproachStuds)
end

local function startAnimPoll(npc: Model)
	task.spawn(function()
		while npc.Parent do
			task.wait(Config.VEHICLE_ANIM_POLL_SECONDS)

			local state = states[npc]
			if not state then
				return
			end

			local def = NpcDefinitions.Get(npc).vehicle
			if not def then
				return
			end

			local actionMode = ActionExecutor.GetMode(npc)
			local shouldMove = state.mode == "Mounted" or actionMode == "Following" or actionMode == "Moving"

			if shouldMove and not state.moveTrack then
				local track = loadAnim(npc, def.animations.move)
				if track then
					track.Looped = true
					track:Play()
					state.moveTrack = track
				end
			elseif not shouldMove and state.moveTrack then
				state.moveTrack:Stop()
				state.moveTrack = nil
			end
		end
	end)
end

local function startHeightWatcher(npc: Model)
	task.spawn(function()
		while npc.Parent do
			task.wait(Config.VEHICLE_MOUNT_HEIGHT_CHECK_SECONDS)

			local state = states[npc]
			if not state or state.mode ~= "Mounted" then
				continue
			end

			local def = NpcDefinitions.Get(npc).vehicle
			local rootPart = getRootPart(npc)
			if not def or not rootPart then
				continue
			end

			local raycastParams = RaycastParams.new()
			raycastParams.FilterType = Enum.RaycastFilterType.Exclude
			raycastParams.FilterDescendantsInstances = { npc }

			local result = Workspace:Raycast(rootPart.Position, Vector3.new(0, -500, 0), raycastParams)
			if result then
				local height = rootPart.Position.Y - result.Position.Y
				if height > def.maxFlightHeightStuds then
					local clampedPosition = Vector3.new(
						rootPart.Position.X,
						result.Position.Y + def.maxFlightHeightStuds,
						rootPart.Position.Z
					)
					rootPart.CFrame = (rootPart.CFrame - rootPart.Position) + clampedPosition
				end
			end
		end
	end)
end

function VehicleExecutor.Init(npc: Model)
	local def = NpcDefinitions.Get(npc).vehicle
	if not def then
		return
	end

	local humanoid = getHumanoid(npc)
	local rootPart = getRootPart(npc)
	if not humanoid or not rootPart then
		warn(("[VehicleExecutor] %s is missing a Humanoid/root part -- cannot manage as a vehicle"):format(npc.Name))
		return
	end

	local seat = npc:FindFirstChildWhichIsA("Seat")
	if not seat then
		warn(("[VehicleExecutor] %s has no Seat -- cannot be ridden"):format(npc.Name))
		return
	end

	-- Replicated to clients so EightDriveController.client.lua can scale
	-- input without needing access to this server-only module's config.
	npc:SetAttribute("VehicleGroundSpeed", def.groundSpeed)
	npc:SetAttribute("VehicleFlightSpeed", def.flightSpeed)
	npc:SetAttribute("VehicleTurnDegPerSec", def.turnDegPerSec)

	local attachment = Instance.new("Attachment")
	attachment.Name = "VehicleDriveAttachment"
	attachment.Parent = rootPart

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "VehicleLinearVelocity"
	linearVelocity.Attachment0 = attachment
	linearVelocity.MaxForce = def.linearMaxForce
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.Enabled = false
	linearVelocity.Parent = rootPart

	-- Yaw control while driving, kept entirely separate from the hard
	-- upright correction in startUprightLoop so the two never fight: this
	-- one ONLY spins around the vehicle's own up axis, expressed in its
	-- local frame so "turn right" means the same thing regardless of
	-- current heading.
	local angularVelocity = Instance.new("AngularVelocity")
	angularVelocity.Name = "VehicleAngularVelocity"
	angularVelocity.Attachment0 = attachment
	angularVelocity.RelativeTo = Enum.ActuatorRelativeTo.Attachment0
	angularVelocity.MaxTorque = Vector3.new(1e7, 1e7, 1e7)
	angularVelocity.AngularVelocity = Vector3.zero
	angularVelocity.Enabled = false
	angularVelocity.Parent = rootPart

	-- Cancels gravity outright while Mounted (see startUprightLoop's comment
	-- for why) -- Force is recomputed continuously from the assembly's real
	-- current mass, this starting value is just a placeholder.
	local antiGravity = Instance.new("VectorForce")
	antiGravity.Name = "VehicleAntiGravity"
	antiGravity.Attachment0 = attachment
	antiGravity.RelativeTo = Enum.ActuatorRelativeTo.World
	antiGravity.Force = Vector3.zero
	antiGravity.Enabled = false
	antiGravity.Parent = rootPart

	states[npc] = {
		mode = "Unresponsive",
		generation = 0,
		rider = nil,
		idleTrack = nil,
		moveTrack = nil,
		baseHipHeight = humanoid.HipHeight,
		linearVelocity = linearVelocity,
		angularVelocity = angularVelocity,
		antiGravity = antiGravity,
	}

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		onOccupantChanged(npc, seat)
	end)

	startAnimPoll(npc)
	startHeightWatcher(npc)
	startUprightLoop(npc)
end

function VehicleExecutor.Start()
	for _, npc in ipairs(CollectionService:GetTagged(Config.VEHICLE_TAG)) do
		if npc:IsA("Model") then
			VehicleExecutor.Init(npc)
		end
	end

	CollectionService:GetInstanceAddedSignal(Config.VEHICLE_TAG):Connect(function(npc)
		if npc:IsA("Model") then
			VehicleExecutor.Init(npc)
		end
	end)
end

return VehicleExecutor
