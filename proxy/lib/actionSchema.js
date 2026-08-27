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
// trusting LLM-generated coordinates. `move_to` below follows the same
// rule: it only prompts a specific player's client to enter that same
// click-to-move flow, it never carries a location itself. Keep
// ACTION_NAMES/EMOTE_NAMES in sync with src/server/ActionConfig.lua.

const ACTION_NAMES = [
  "none",
  "follow_player",
  "play_emote",
  "stop",
  "wander",
  "ride",
  "move_to",
  "transform_up",
  "transform_back",
];
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
              "'stop' stops following/moving and stands still. " +
              "'wander' walks off to a spot of your own choosing nearby. " +
              "'ride' walks toward the player and waits nearby so they can get on. " +
              "'move_to' prompts the player to click where they want you to go. " +
              "'transform_up' powers on / transforms up. " +
              "'transform_back' transforms back down and powers off.",
          },
          emote: {
            type: "string",
            enum: EMOTE_NAMES,
            description: "Required only when action is 'play_emote'.",
          },
          complied: {
            type: "boolean",
            description:
              "False if you are declining or pushing back on what was asked, instead of going along with it. " +
              "When false, any `action` you set is ignored -- your `reply` text is what communicates the refusal.",
          },
        },
        required: ["reply", "action", "complied"],
      },
    },
  },
];

const TOOL_CHOICE = { type: "function", function: { name: RESPONSE_TOOL_NAME } };

// Extracts { reply, action, complied } from the forced npc_response tool
// call. Returns a safe default if the model somehow didn't call it or sent
// malformed arguments.
function extractResponse(message) {
  const toolCalls = message && message.tool_calls;
  const call = Array.isArray(toolCalls) && toolCalls.find((c) => c.function && c.function.name === RESPONSE_TOOL_NAME);

  if (!call) {
    return { reply: (message && message.content) || "...", action: null, complied: true };
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
  const complied = args.complied !== false;

  const NO_PARAM_ACTIONS = ["follow_player", "stop", "wander", "ride", "move_to", "transform_up", "transform_back"];

  let action = null;
  if (NO_PARAM_ACTIONS.includes(args.action)) {
    action = { name: args.action, params: {} };
  } else if (args.action === "play_emote" && EMOTE_NAMES.includes(args.emote)) {
    action = { name: "play_emote", params: { emote: args.emote } };
  }

  // Defense-in-depth: a decline can never also execute the declined action,
  // even if the model's own arguments were internally inconsistent (e.g. it
  // somehow set complied=false but still filled in an action).
  if (!complied) {
    action = null;
  }

  return { reply, action, complied };
}

module.exports = { TOOLS, TOOL_CHOICE, EMOTE_NAMES, extractResponse };
