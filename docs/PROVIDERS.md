# Providers

## Compatible HTTPS APIs

Connection has separate opt-in API sections for text and audio on macOS. Windows has separate Connection fields and transcription/analysis switches. Existing macOS ChatGPT and Groq settings are retained. Enabling a compatible route takes precedence only for that operation; disabling it restores the existing selected route. Errors never silently choose another service.

Enter the base URL, including the version prefix required by the provider, without the operation suffix. Examples: `https://api.openai.com/v1` or `https://api.groq.com/openai/v1`. These are examples, not automatic paid activation. Enter a model available to your own account. Keys are bound to the exact base URL and to text/audio separately. Changing the base URL requires saving a key for the new endpoint, even on the same host. Old endpoint keys can be removed by restoring that endpoint and choosing Remove key.

Text requests use nonstreaming `chat/completions`, system/user messages and an explicit output-token limit. Choose `max_completion_tokens`, or `max_tokens` for services that require it. Only a completed `finish_reason: stop` response is accepted. JSON-producing editorial models must follow the requested schema and quote/reference checks. Tool-call-only, truncated, refused or incompatible output is withheld. A compatible endpoint does not guarantee every model is suitable.

Audio requests send WAV multipart data to `audio/transcriptions` with an explicit model and `response_format=json`. Auto language omits the language field; explicit ISO codes are supplied as requested. This is chunked near-live transcription, not the provider's Realtime protocol. Models that do not accept this multipart/JSON contract are unsupported.

HTTPS is required. URL credentials, query parameters and fragments are rejected. Redirects are refused to avoid forwarding credentials/audio to a different destination. The client does not display a provider's raw error body. OS trust validation remains enabled. Never paste keys or OAuth callback addresses into an issue or chat.

## Existing macOS routes

Continue with ChatGPT uses granted public-client access, a loopback callback, state/PKCE/nonce validation, Keychain storage and explicit model selection. If the browser cannot deliver the final callback, the app provides a local manual callback field. There is no localhost website. A compatible API-key route uses ordinary HTTPS and no OAuth callback.

The original Groq path retains explicit Free-plan confirmation and conservative audio/text budgets. These limits are local guards and cannot account for other clients' usage. The custom API route, including a custom Groq endpoint, does not apply that special free-budget policy. Check your provider's billing and limits separately. Windows does not claim a free-plan guarantee.

Test text inference and a short consented audio file before a real macOS session. These tests make real provider requests. CI and deterministic rehearsals use injected responses and do not establish that a new API key or live model works.

Protocol references: [OpenAI chat completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create), [OpenAI transcription](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create), [Groq speech documentation](https://console.groq.com/docs/speech-to-text).
