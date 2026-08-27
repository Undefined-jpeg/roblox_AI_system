-- "Move NPC Here" button: appears when the local player is near a tagged
-- AI NPC, and lets them click a spot in the world to send the NPC there.
-- The server re-validates the clicked position independently -- this script
-- only builds the request, it never decides whether a move is allowed.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local SharedConfig = require(ReplicatedStorage:WaitForChild("SharedConfig"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local localPlayer = Players.LocalPlayer
local moveEvent = Remotes.GetMoveNpcRequestEvent()

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "NpcMoveUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

local button = Instance.new("TextButton")
button.Name = "MoveNpcButton"
button.Size = UDim2.fromOffset(160, 40)
button.Position = UDim2.new(0.5, -80, 0.85, 0)
button.Text = "Move NPC Here"
button.Visible = false
button.Parent = screenGui

local promptLabel = Instance.new("TextLabel")
promptLabel.Name = "PromptLabel"
promptLabel.Size = UDim2.fromOffset(300, 30)
promptLabel.Position = UDim2.new(0.5, -150, 0.8, -35)
promptLabel.BackgroundTransparency = 1
promptLabel.TextScaled = true
promptLabel.Text = "Click a spot on the ground to send the NPC there"
promptLabel.Visible = false
promptLabel.Parent = screenGui

local pointModeActive = false
local nearbyNpc: Model? = nil

local function findNearbyNpc(): Model?
	local character = localPlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return nil
	end

	for _, npc in ipairs(CollectionService:GetTagged(SharedConfig.NPC_TAG)) do
		if npc:IsA("Model") then
			local npcRoot = npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart") :: BasePart?
			if npcRoot and (rootPart.Position - npcRoot.Position).Magnitude <= SharedConfig.MOVE_UI_RADIUS then
				return npc
			end
		end
	end

	return nil
end

local function setPointMode(active: boolean)
	pointModeActive = active
	promptLabel.Visible = active
	button.Text = active and "Cancel" or "Move NPC Here"
end

local function sendMoveRequest(npc: Model, position: Vector3)
	moveEvent:FireServer(npc, position)
end

local function onWorldClick(inputPosition: Vector2)
	if not pointModeActive or not nearbyNpc then
		return
	end

	local camera = Workspace.CurrentCamera
	local ray = camera:ViewportPointToRay(inputPosition.X, inputPosition.Y)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { localPlayer.Character }

	local result = Workspace:Raycast(ray.Origin, ray.Direction * 1000, raycastParams)
	if result then
		sendMoveRequest(nearbyNpc, result.Position)
	end

	setPointMode(false)
end

button.MouseButton1Click:Connect(function()
	if pointModeActive then
		setPointMode(false)
	elseif nearbyNpc then
		setPointMode(true)
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		onWorldClick(Vector2.new(input.Position.X, input.Position.Y))
	end
end)

RunService.Heartbeat:Connect(function()
	nearbyNpc = findNearbyNpc()
	if not nearbyNpc and pointModeActive then
		setPointMode(false)
	end
	button.Visible = nearbyNpc ~= nil
end)
