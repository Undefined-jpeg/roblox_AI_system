require("dotenv").config();

const express = require("express");
const rateLimit = require("express-rate-limit");
const { getChatCompletion, FALLBACK_REPLY } = require("./lib/openrouter");

const PORT = process.env.PORT || 3000;
const SHARED_SECRET = process.env.SHARED_SECRET;
const OPENROUTER_API_KEY = process.env.OPENROUTER_API_KEY;
// Accepts either a bare model slug ("google/gemini-2.5-flash-lite") or a
// pasted-in model page URL ("https://openrouter.ai/google/gemini-2.5-flash-lite")
// and normalizes to the slug OpenRouter's API actually expects -- pasting the
// URL is an easy mistake (model pages are literally that URl) and otherwise
// causes every single request to fail with a silent-looking fallback reply.
function normalizeModelId(raw) {
  const trimmed = raw.trim();
  const prefix = "https://openrouter.ai/";
  return trimmed.startsWith(prefix) ? trimmed.slice(prefix.length) : trimmed;
}

const OPENROUTER_MODEL = normalizeModelId(process.env.OPENROUTER_MODEL || "anthropic/claude-haiku-4.5");

const MAX_MESSAGE_CHARS = 500;
const MAX_HISTORY_TURNS = 6;
const MAX_HISTORY_CONTENT_CHARS = 500;

// Default persona used when Roblox doesn't send one. Customize per-NPC by
// having Roblox include a "persona" field in the request body instead.
const DEFAULT_PERSONA =
  "You are a friendly, upbeat NPC guide in a Roblox game. You enjoy helping players and " +
  "keeping the mood light. (This is a placeholder persona — customize it for your NPC.)";

if (!OPENROUTER_API_KEY) {
  console.error("Missing OPENROUTER_API_KEY env var. Set it before starting the server.");
  process.exit(1);
}
if (!SHARED_SECRET) {
  console.error("Missing SHARED_SECRET env var. Set it before starting the server.");
  process.exit(1);
}

const app = express();
app.use(express.json({ limit: "64kb" }));

app.use(
  rateLimit({
    windowMs: 60 * 1000,
    limit: 60,
    standardHeaders: true,
    legacyHeaders: false,
  })
);

function requireSharedSecret(req, res, next) {
  const provided = req.header("X-Npc-Secret");
  if (!provided || provided !== SHARED_SECRET) {
    return res.status(401).json({ error: "unauthorized" });
  }
  next();
}

function sanitizeHistory(rawHistory) {
  if (!Array.isArray(rawHistory)) return [];
  return rawHistory
    .filter(
      (turn) =>
        turn &&
        (turn.role === "user" || turn.role === "assistant") &&
        typeof turn.content === "string"
    )
    .slice(-MAX_HISTORY_TURNS)
    .map((turn) => ({
      role: turn.role,
      content: turn.content.slice(0, MAX_HISTORY_CONTENT_CHARS),
    }));
}

app.get("/health", (_req, res) => res.json({ ok: true }));

app.post("/npc-chat", requireSharedSecret, async (req, res) => {
  const { message, history, persona } = req.body || {};

  if (typeof message !== "string" || message.trim().length === 0) {
    return res.status(400).json({ error: "message is required" });
  }

  const trimmedMessage = message.slice(0, MAX_MESSAGE_CHARS);
  const safeHistory = sanitizeHistory(history);
  const safePersona = typeof persona === "string" && persona.length > 0 ? persona : DEFAULT_PERSONA;

  try {
    const result = await getChatCompletion({
      persona: safePersona,
      message: trimmedMessage,
      history: safeHistory,
      model: OPENROUTER_MODEL,
      apiKey: OPENROUTER_API_KEY,
    });
    return res.json(result);
  } catch (err) {
    console.error("Unhandled error in /npc-chat:", err);
    return res.json({ reply: FALLBACK_REPLY, action: null });
  }
});

app.listen(PORT, () => {
  console.log(`NPC proxy listening on port ${PORT}`);
});
