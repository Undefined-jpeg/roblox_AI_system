-- Shared accessor for the RemoteEvents used by the AI NPC system.
-- Server creates the instances on first access; clients wait for them.
-- Require this from both server and client code instead of hardcoding paths.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "AiNpcRemotes"
local MOVE_REQUEST_NAME = "MoveNpcRequest"
local CHAT_MESSAGE_NAME = "DisplayNpcChatMessage"

local Remotes = {}

local function getOrCreateFolder()
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if folder then
		return folder
	end

	if RunService:IsServer() then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
		return folder
	end

	return ReplicatedStorage:WaitForChild(FOLDER_NAME)
end

local function getOrCreateRemoteEvent(name: string): RemoteEvent
	local folder = getOrCreateFolder()

	if RunService:IsServer() then
		local event = folder:FindFirstChild(name)
		if not event then
			event = Instance.new("RemoteEvent")
			event.Name = name
			event.Parent = folder
		end
		return event
	end

	return folder:WaitForChild(name)
end

function Remotes.GetMoveNpcRequestEvent(): RemoteEvent
	return getOrCreateRemoteEvent(MOVE_REQUEST_NAME)
end

-- Server -> all clients: "please display this line in your local chat window."
-- Exists because TextChannel:DisplaySystemMessage can only be called from the
-- client (confirmed against the live API) -- the server can't call it directly.
function Remotes.GetDisplayNpcChatMessageEvent(): RemoteEvent
	return getOrCreateRemoteEvent(CHAT_MESSAGE_NAME)
end

return Remotes
