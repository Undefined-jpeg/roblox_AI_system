-- Thin wrapper around HttpService for talking to the proxy server.
-- Never talks to OpenRouter directly -- the proxy holds the API key.

local HttpService = game:GetService("HttpService")

local Config = require(script.Parent.Config)

local OpenRouterClient = {}

export type ChatTurn = { role: string, content: string }
export type ChatResult = {
	reply: string,
	action: { name: string, params: { [string]: any } }?,
}

local FALLBACK_RESULT: ChatResult = {
	reply = "Sorry, I can't think straight right now. Try again in a moment?",
	action = nil,
}

-- Fires and forgets a POST to the proxy's /npc-chat endpoint. Never throws --
-- returns a safe fallback result on any network/parse failure so the caller
-- never has to worry about propagating an error into the chat.
function OpenRouterClient.RequestChat(message: string, history: { ChatTurn }): ChatResult
	local body = HttpService:JSONEncode({
		message = message,
		history = history,
		persona = Config.NPC_PERSONA,
	})

	local ok, result = pcall(function()
		return HttpService:RequestAsync({
			Url = Config.PROXY_URL .. "/npc-chat",
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["X-Npc-Secret"] = Config.SHARED_SECRET,
			},
			Body = body,
		})
	end)

	if not ok then
		warn("[OpenRouterClient] HTTP request failed: " .. tostring(result))
		return FALLBACK_RESULT
	end

	if not result.Success then
		warn(("[OpenRouterClient] Proxy returned status %d: %s"):format(result.StatusCode, result.Body or ""))
		return FALLBACK_RESULT
	end

	local decodeOk, decoded = pcall(function()
		return HttpService:JSONDecode(result.Body)
	end)

	if not decodeOk or type(decoded) ~= "table" or type(decoded.reply) ~= "string" then
		warn("[OpenRouterClient] Failed to decode proxy response: " .. tostring(decoded))
		return FALLBACK_RESULT
	end

	return {
		reply = decoded.reply,
		action = decoded.action,
	}
end

return OpenRouterClient
