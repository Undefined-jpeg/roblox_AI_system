# NPC Proxy Server

Holds the OpenRouter API key and brokers chat requests from the Roblox NPC. Roblox never talks to
OpenRouter directly — it only ever calls this proxy over HTTPS.

## Local testing

```bash
npm install
cp .env.example .env
# edit .env: set OPENROUTER_API_KEY and SHARED_SECRET
npm start
```

Then test it:

```bash
curl -X POST http://localhost:3000/npc-chat \
  -H "Content-Type: application/json" \
  -H "X-Npc-Secret: <the SHARED_SECRET from your .env>" \
  -d '{"playerName":"Test","message":"can you follow me?","history":[]}'
```

Expect a JSON response like `{"reply":"Sure thing!","action":{"name":"follow_player","params":{}}}`.

Sending the request without the `X-Npc-Secret` header should get a `401`.

## Deploying to Render

1. Push this `proxy/` folder to a git repository (a dedicated repo, or a subfolder of a monorepo with
   Render's "Root Directory" setting pointed at `proxy/`).
2. In the Render dashboard: **New → Web Service**, connect the repo.
   - Build command: `npm install`
   - Start command: `npm start`
3. Under **Environment**, add:
   - `OPENROUTER_API_KEY` — from https://openrouter.ai/keys
   - `SHARED_SECRET` — a long random string you generate yourself (e.g. `openssl rand -hex 32`)
   - `OPENROUTER_MODEL` — optional, defaults to `anthropic/claude-haiku-4.5`
4. Deploy. Render gives you a public URL like `https://your-service.onrender.com`.
5. Put that URL and the same `SHARED_SECRET` into `src/server/Config.lua` on the Roblox side.

Note: Render's free tier spins down after inactivity, so the first request after idling will be slow
(cold start) — the Roblox-side HTTP client should tolerate a few extra seconds on that first call.
