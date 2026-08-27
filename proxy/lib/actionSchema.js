// Whitelisted actions the NPC can trigger via OpenRouter's tool-calling.
// This list is intentionally small and closed. There is deliberately NO
// "go to this coordinate" tool here — moving to a specific point in the
// world is handled entirely by the player clicking a location in-game
// (see src/client/NpcMoveUI.client.lua), never by trusting LLM-generated
// coordinates. Keep this file in sync with src/server/ActionConfig.lua.

const EMOTE_NAMES = ["wave", "dance", "point", "laugh"];

const TOOLS = [
  {
    type: "function",
    function: {
      name: "follow_player",
      description: "Start following the player who is currently talking to you.",
      parameters: { type: "object", properties: {}, required: [] },
    },
  },
  {
    type: "function",
    function: {
      name: "play_emote",
      description: "Play a short emote animation.",
      parameters: {
        type: "object",
        properties: {
          emote: { type: "string", enum: EMOTE_NAMES },
        },
        required: ["emote"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "stop",
      description: "Stop following the player and stand still.",
      parameters: { type: "object", properties: {}, required: [] },
    },
  },
];

// Extracts the first tool call (if any) from an OpenRouter/OpenAI-shaped
// chat completion response and normalizes it into { name, params }.
function extractAction(message) {
  const toolCalls = message && message.tool_calls;
  if (!Array.isArray(toolCalls) || toolCalls.length === 0) {
    return null;
  }

  const call = toolCalls[0];
  const name = call && call.function && call.function.name;
  if (!name) return null;

  let params = {};
  const rawArgs = call.function.arguments;
  if (typeof rawArgs === "string" && rawArgs.length > 0) {
    try {
      params = JSON.parse(rawArgs);
    } catch (_err) {
      params = {};
    }
  }

  return { name, params };
}

module.exports = { TOOLS, EMOTE_NAMES, extractAction };
