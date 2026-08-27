const { TOOLS, TOOL_CHOICE, extractResponse } = require("./actionSchema");

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const REQUEST_TIMEOUT_MS = 8000;
const MAX_REPLY_CHARS = 300;

const FALLBACK_REPLY = "Sorry, I got distracted for a second — can you say that again?";

const DEFAULT_CONTEXT = {
  turnType: "direct",
  activity: "idle",
  surroundings: "nothing in particular",
  nearbyPlayers: "no one nearby",
};

// Base autonomy/decline permission -- applies to every turn type. This is
// what actually makes "complied: false" a real, exercised option rather
// than a schema field the model never uses: without explicit permission and
// grounding in real state, a model defaults to always being agreeable.
function buildAutonomyPreamble(context) {
  return (
    "You have your own moods, interests, and things you'd rather be doing right now -- you are not a servant " +
    "and not obligated to comply with every request. If a request doesn't interest you, conflicts with what " +
    "you're currently doing, or you're just not in the mood, set `complied` to false and say why in `reply`, " +
    "briefly and in character. Lean toward complying with simple, friendly, one-off requests; lean toward " +
    "declining when you're already mid-activity, when the request is repeated or rude, or contradicts what you " +
    "just said you wanted to do. Vary it -- don't always comply and don't always refuse.\n\n" +
    `Right now you are: ${context.activity}. Nearby: ${context.nearbyPlayers}. You notice: ${context.surroundings}.`
  );
}

const TURN_TYPE_SUFFIXES = {
  direct: "Set `action` to 'none' unless the player's request clearly calls for follow_player, play_emote, stop, or wander.",
  self_initiated:
    "No one is talking to you right now -- this is your own quiet moment. If you feel like it, set `action` to " +
    "'wander', 'play_emote', or 'stop' and say something short and in-character. Otherwise set `action` to " +
    "'none' and keep `reply` short, even '...'. Always set `complied` to true.",
  passive_overheard:
    "You overheard this -- it wasn't said to you. Only chime in if it feels natural for a bystander to. You may " +
    "only use `action` 'none' or 'play_emote' (you can't follow or stop for someone who isn't talking to you). " +
    "Always set `complied` to true.",
};

function buildSystemPrompt(persona, rawContext) {
  // Merge field-by-field (not a blind spread) so a present-but-undefined
  // field on rawContext can't silently clobber DEFAULT_CONTEXT's fallback --
  // `{...DEFAULT_CONTEXT, ...{activity: undefined}}` would otherwise leave
  // `activity` as literal `undefined`, rendering as "you are: undefined" in
  // the prompt text.
  const context = { ...DEFAULT_CONTEXT };
  if (rawContext) {
    for (const key of Object.keys(DEFAULT_CONTEXT)) {
      if (rawContext[key] !== undefined) {
        context[key] = rawContext[key];
      }
    }
  }
  const suffix = TURN_TYPE_SUFFIXES[context.turnType] || TURN_TYPE_SUFFIXES.direct;

  return (
    `${persona}\n\n` +
    "Keep replies short and conversational (1-3 sentences), suitable for a game chat window.\n\n" +
    `${buildAutonomyPreamble(context)}\n\n` +
    suffix
  );
}

function truncate(text, max) {
  if (typeof text !== "string") return "";
  if (text.length <= max) return text;
  return text.slice(0, max - 1).trimEnd() + "…";
}

// history: [{ role: "user"|"assistant", content: string }, ...]
async function getChatCompletion({ persona, message, history, model, apiKey, context }) {
  const messages = [
    { role: "system", content: buildSystemPrompt(persona, context) },
    ...history,
    { role: "user", content: message },
  ];

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  try {
    const response = await fetch(OPENROUTER_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/",
        "X-Title": "Roblox AI NPC",
      },
      body: JSON.stringify({
        model,
        messages,
        tools: TOOLS,
        tool_choice: TOOL_CHOICE,
        max_tokens: 200,
        temperature: 0.7,
      }),
      signal: controller.signal,
    });

    if (!response.ok) {
      const errText = await response.text().catch(() => "");
      console.error(`OpenRouter error ${response.status}: ${errText}`);
      return { reply: FALLBACK_REPLY, action: null, complied: true };
    }

    const data = await response.json();
    const choice = data.choices && data.choices[0];
    const assistantMessage = choice && choice.message;

    const { reply, action, complied } = extractResponse(assistantMessage);

    return { reply: truncate(reply, MAX_REPLY_CHARS), action, complied };
  } catch (err) {
    console.error("OpenRouter request failed:", err.message);
    return { reply: FALLBACK_REPLY, action: null, complied: true };
  } finally {
    clearTimeout(timeout);
  }
}

module.exports = { getChatCompletion, FALLBACK_REPLY };
