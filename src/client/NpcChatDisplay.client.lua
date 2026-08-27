-- TextChannel:DisplaySystemMessage can only be called from the client, so
-- the server fires this RemoteEvent with a pre-formatted line and every
-- client displays it locally in their own chat window.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local chatMessageEvent = Remotes.GetDisplayNpcChatMessageEvent()

chatMessageEvent.OnClientEvent:Connect(function(formattedText: string)
	local generalChannel = TextChatService.TextChannels:FindFirstChild("RBXGeneral")
	if generalChannel then
		generalChannel:DisplaySystemMessage(formattedText)
	end
end)
