-- Thin wrapper around HttpService for talking to the proxy server.
-- Never talks to OpenRouter directly -- the proxy holds the API key.

local HttpService = game:GetService("HttpService")

local Config = require(script.Parent.Config)

local OpenRouterClient = {}

export type ChatTurn = { role: string, content: string }
export type NpcContext = {
	turnType: "direct" | "passive_overheard" | "self_initiated",
	activity: string,
	surroundings: string,
	nearbyPlayers: string,
}
export type ChatResult = {
	reply: string,
	action: { name: string, params: { [string]: any } }?,
	complied: boolean,
}

-- A network failure isn't a personality choice -- always report compliant
-- on the fallback so a dropped connection never surfaces as an in-character
-- refusal.
local FALLBACK_RESULT: ChatResult = {
	reply = "Sorry, I can't think straight right now. Try again in a moment?",
	action = nil,
	complied = true,
}

-- HttpService:RequestAsync has no built-in per-call timeout, and a slow or
-- hung proxy (e.g. Render cold-starting) can otherwise leave the calling
-- coroutine waiting far longer than Config.HTTP_TIMEOUT_SECONDS. This races
-- the real request against a plain wait: whichever finishes first "wins",
-- and a late-arriving request result past the timeout is just ignored (the
-- underlying HTTP call itself can't be cancelled, only stopped-waiting-on).
local function requestWithTimeout(requestOptions: any, timeoutSeconds: number): (boolean, any)
	local settled = false
	local ok, result

	task.spawn(function()
		local requestOk, requestResult = pcall(function()
			return HttpService:RequestAsync(requestOptions)
		end)
		if not settled then
			settled = true
			ok, result = requestOk, requestResult
		end
	end)

	local elapsed = 0
	while not settled and elapsed < timeoutSeconds do
		task.wait(0.1)
		elapsed += 0.1
	end

	if not settled then
		return false, "timed out after " .. timeoutSeconds .. "s"
	end

	return ok, result
end

-- Fires and forgets a POST to the proxy's /npc-chat endpoint. Never throws --
-- returns a safe fallback result on any network/parse failure so the caller
-- never has to worry about propagating an error into the chat.
function OpenRouterClient.RequestChat(
	message: string,
	history: { ChatTurn },
	context: NpcContext,
	persona: string
): ChatResult
	local body = HttpService:JSONEncode({
		message = message,
		history = history,
		persona = persona,
		context = context,
	})

	local ok, result = requestWithTimeout({
		Url = Config.PROXY_URL .. "/npc-chat",
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
			["X-Npc-Secret"] = Config.SHARED_SECRET,
		},
		Body = body,
	}, Config.HTTP_TIMEOUT_SECONDS)

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
		complied = decoded.complied ~= false,
	}
end

return OpenRouterClient
