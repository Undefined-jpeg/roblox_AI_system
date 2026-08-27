// Whitelisted actions the NPC can trigger, bundled with its spoken reply
// into a single forced tool call ("npc_response").
//
// Why one bundled tool instead of separate follow_player/play_emote/stop
// tools: real tool-calling models (this one included) frequently return
// `content: null` whenever they decide to call a tool, so a design that
// puts the chat reply in `content` and the action in a separate tool call
// silently loses the reply half of the time. Forcing every response through
// one tool whose arguments contain BOTH `reply` and `action` guarantees we
// always get both.
//
// There is deliberately NO "go to this coordinate" action here — moving to
// a specific point in the world is handled entirely by the player clicking
// a location in-game (see src/client/NpcMoveUI.client.lua), never by
// trusting LLM-generated coordinates. Keep ACTION_NAMES/EMOTE_NAMES in sync
// with src/server/ActionConfig.lua.

const ACTION_NAMES = ["none", "follow_player", "play_emote", "stop"];
const EMOTE_NAMES = ["wave", "dance", "point", "laugh"];

const RESPONSE_TOOL_NAME = "npc_response";

const TOOLS = [
  {
    type: "function",
    function: {
      name: RESPONSE_TOOL_NAME,
      description:
        "Respond to the player. Always call this exactly once per turn -- it carries both what you say out loud and any action you want to take.",
      parameters: {
        type: "object",
        properties: {
          reply: {
            type: "string",
            description: "What you say out loud in chat, 1-3 short sentences.",
          },
          action: {
            type: "string",
            enum: ACTION_NAMES,
            description:
              "An action to take alongside your reply, or 'none' if you're just talking. " +
              "'follow_player' starts following the player who's talking to you. " +
              "'play_emote' plays a short emote (requires setting `emote`). " +
              "'stop' stops following and stands still.",
          },
          emote: {
            type: "string",
            enum: EMOTE_NAMES,
            description: "Required only when action is 'play_emote'.",
          },
        },
        required: ["reply", "action"],
      },
    },
  },
];

const TOOL_CHOICE = { type: "function", function: { name: RESPONSE_TOOL_NAME } };

// Extracts { reply, action } from the forced npc_response tool call.
// Returns a safe default if the model somehow didn't call it or sent
// malformed arguments.
function extractResponse(message) {
  const toolCalls = message && message.tool_calls;
  const call = Array.isArray(toolCalls) && toolCalls.find((c) => c.function && c.function.name === RESPONSE_TOOL_NAME);

  if (!call) {
    return { reply: (message && message.content) || "...", action: null };
  }

  let args = {};
  const rawArgs = call.function.arguments;
  if (typeof rawArgs === "string" && rawArgs.length > 0) {
    try {
      args = JSON.parse(rawArgs);
    } catch (_err) {
      args = {};
    }
  }

  const reply = typeof args.reply === "string" && args.reply.length > 0 ? args.reply : "...";

  let action = null;
  if (args.action === "follow_player" || args.action === "stop") {
    action = { name: args.action, params: {} };
  } else if (args.action === "play_emote" && EMOTE_NAMES.includes(args.emote)) {
    action = { name: "play_emote", params: { emote: args.emote } };
  }

  return { reply, action };
}

module.exports = { TOOLS, TOOL_CHOICE, EMOTE_NAMES, extractResponse };
