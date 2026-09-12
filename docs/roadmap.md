# Kodi Reader Roadmap

## Version 2

- [ ] Explore hosted Ask AI for users who do not want to enter their own API key.
  - Use Fly Machines for a small backend service that proxies Kodi Reader requests to OpenAI.
  - Keep OpenAI keys on the server, never embedded in the Mac app.
  - Add authentication, rate limits, usage caps, logging, and abuse controls before exposing it publicly.
  - Retire visible model selection so Ask AI uses the hosted Kodi AI service by default.
