# Kodi Reader Ask AI Proxy

Small Fly Machines service that gives Kodi Reader one hosted Ask AI endpoint while keeping the OpenAI API key off the Mac app.

## Endpoints

- `GET /health`
- `POST /v1/chat/completions`

The chat endpoint accepts an OpenAI-compatible chat completions payload and always forwards to the OpenAI model configured by `OPENAI_MODEL`. Kodi Reader currently defaults to `gpt-5.6-terra`.

## Deploy to Fly.io

```bash
cd server/ask-ai-proxy
fly launch --copy-config --no-deploy
fly secrets set OPENAI_API_KEY="sk-..."
fly deploy
```

If `kodi-reader-ai` is unavailable, rename `app` in `fly.toml`, deploy, then update `AIModelConfig.kodiHosted.baseURL` in the Mac app.

## Cost Guardrails

- The default machine is `shared-cpu-1x` with `256mb`.
- One machine stays running to avoid cold starts.
- Per-IP rate limit defaults to 60 requests per hour.
- Request bodies are capped at 256 KB.
- The proxy logs failures, not book text.
