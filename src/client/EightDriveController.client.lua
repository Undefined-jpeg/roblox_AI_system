-- Reads WASD (omnidirectional ground move) + E/Q (vertical flight) while the
-- local player is seated in a vehicle NPC's Seat, and writes it into that
-- vehicle's drive constraints (created server-side in VehicleExecutor.lua).
-- This only works because mounting transfers physics network ownership of
-- the vehicle's assembly to the rider (VehicleExecutor.lua's mountRider):
-- writing constraint goals from the owning client is the standard Roblox
-- custom-vehicle pattern -- the resulting motion replicates via that
-- ownership, there's no RemoteEvent involved in driving itself.
--
-- Yaw (turning) is driven by AngularVelocity, kept deliberately separate
-- from VehicleExecutor's always-on "stay upright" AlignOrientation -- that
-- constraint uses PrimaryAxisOnly and never resists yaw, so there's nothing
-- to fight here; forward/vertical movement reads the vehicle's own live
-- facing direction each frame rather than tracking a separately-integrated
-- goal orientation.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local SharedConfig = require(ReplicatedStorage:WaitForChild("SharedConfig"))

local localPlayer = Players.LocalPlayer

local function getRootPart(npc: Model): BasePart?
	return npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function isLocalPlayerSeated(seat: Seat): boolean
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and seat.Occupant == humanoid
end

local function driveVehicle(npc: Model)
	local rootPart = getRootPart(npc)
	if not rootPart then
		return
	end

	local linearVelocity = rootPart:FindFirstChild("VehicleLinearVelocity") :: LinearVelocity?
	local angularVelocity = rootPart:FindFirstChild("VehicleAngularVelocity") :: AngularVelocity?
	if not linearVelocity or not angularVelocity or not linearVelocity.Enabled then
		return
	end

	local groundSpeed = (npc:GetAttribute("VehicleGroundSpeed") :: number?) or 40
	local flightSpeed = (npc:GetAttribute("VehicleFlightSpeed") :: number?) or 40
	local turnDegPerSec = (npc:GetAttribute("VehicleTurnDegPerSec") :: number?) or 90

	local forward = (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0)
		- (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
	local turn = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0)
		- (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
	local vertical = (UserInputService:IsKeyDown(Enum.KeyCode.E) and 1 or 0)
		- (UserInputService:IsKeyDown(Enum.KeyCode.Q) and 1 or 0)

	angularVelocity.AngularVelocity = Vector3.new(0, math.rad(turn * turnDegPerSec), 0)

	local lookVector = rootPart.CFrame.LookVector
	linearVelocity.VectorVelocity = (lookVector * forward * groundSpeed) + Vector3.new(0, vertical * flightSpeed, 0)
end

RunService.Heartbeat:Connect(function()
	for _, npc in ipairs(CollectionService:GetTagged(SharedConfig.VEHICLE_TAG)) do
		if npc:IsA("Model") then
			local seat = npc:FindFirstChildWhichIsA("Seat")
			if seat and isLocalPlayerSeated(seat) then
				driveVehicle(npc)
			end
		end
	end
end)
