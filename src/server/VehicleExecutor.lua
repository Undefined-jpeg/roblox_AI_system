-- Owns transform/mount/drive state for rideable vehicle NPCs (e.g. Eight).
-- Deliberately separate from ActionExecutor's NpcState: flight and manual
-- driving don't fit a Humanoid-pathfinding-oriented state machine. Ground
-- movement (Follow/MoveTo) while NOT mounted still goes through
-- ActionExecutor directly, since that part really is just normal walking.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
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
	linearVelocity: LinearVelocity?,
	alignOrientation: AlignOrientation?,
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
	if state.alignOrientation then
		state.alignOrientation.Enabled = false
	end

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
	if state.alignOrientation and rootPart then
		state.alignOrientation.CFrame = rootPart.CFrame
		state.alignOrientation.Enabled = true
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
			states[npc].mode = "Unresponsive"
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

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "VehicleAlignOrientation"
	alignOrientation.Attachment0 = attachment
	-- math.huge here (infinite corrective torque) caused visible wobbling,
	-- confirmed live: on a heavy multi-part welded assembly, an "instantly
	-- snap to goal" torque overcorrects every physics step and oscillates.
	-- A large-but-finite torque plus a moderate (not max) Responsiveness
	-- gives a stiff-but-stable hold instead.
	alignOrientation.MaxTorque = 1e7
	alignOrientation.Responsiveness = 25
	-- No RelativeTo here -- that's a LinearVelocity-only property. With no
	-- Attachment1 set, AlignOrientation.CFrame is already a world-space
	-- orientation goal (confirmed live: setting RelativeTo on this class
	-- throws "not a valid member").
	alignOrientation.CFrame = rootPart.CFrame
	alignOrientation.Enabled = false
	alignOrientation.Parent = rootPart

	states[npc] = {
		mode = "Unresponsive",
		generation = 0,
		rider = nil,
		idleTrack = nil,
		moveTrack = nil,
		linearVelocity = linearVelocity,
		alignOrientation = alignOrientation,
	}

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		onOccupantChanged(npc, seat)
	end)

	startAnimPoll(npc)
	startHeightWatcher(npc)
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
