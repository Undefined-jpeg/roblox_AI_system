const { TOOLS, TOOL_CHOICE, extractResponse } = require("./actionSchema");

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const REQUEST_TIMEOUT_MS = 8000;
const MAX_REPLY_CHARS = 300;

const FALLBACK_REPLY = "Sorry, I got distracted for a second — can you say that again?";

function buildSystemPrompt(persona) {
  return (
    `${persona}\n\n` +
    "Keep replies short and conversational (1-3 sentences), suitable for a game chat window. " +
    "Set `action` to 'none' unless the player's request clearly calls for follow_player, play_emote, or stop."
  );
}

function truncate(text, max) {
  if (typeof text !== "string") return "";
  if (text.length <= max) return text;
  return text.slice(0, max - 1).trimEnd() + "…";
}

// history: [{ role: "user"|"assistant", content: string }, ...]
async function getChatCompletion({ persona, message, history, model, apiKey }) {
  const messages = [
    { role: "system", content: buildSystemPrompt(persona) },
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
      return { reply: FALLBACK_REPLY, action: null };
    }

    const data = await response.json();
    const choice = data.choices && data.choices[0];
    const assistantMessage = choice && choice.message;

    const { reply, action } = extractResponse(assistantMessage);

    return { reply: truncate(reply, MAX_REPLY_CHARS), action };
  } catch (err) {
    console.error("OpenRouter request failed:", err.message);
    return { reply: FALLBACK_REPLY, action: null };
  } finally {
    clearTimeout(timeout);
  }
}

module.exports = { getChatCompletion, FALLBACK_REPLY };
