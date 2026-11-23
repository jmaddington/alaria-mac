# Hermes HTTP API: what the client uses and why

Verified with curl against hermes-agent main @52b5271 (2026.9.24). Two servers:

| Server | Default | Auth | Used for |
|---|---|---|---|
| API server (inside `hermes gateway`) | :8642 | `Authorization: Bearer $API_SERVER_KEY` | sessions CRUD, chat streaming, runs (stop/steer/approval), cron jobs CRUD, model options, health |
| Dashboard (`hermes dashboard` / `hermes serve`) | :9119 | `X-Hermes-Session-Token: $HERMES_DASHBOARD_SESSION_TOKEN` | skills list/content/edit/toggle/lock/uninstall, session search, job run history, delivery targets, toolsets, model info/set, memory, raw config, logs, analytics |

Gotchas found on the wire:
- The API server is enabled by a usable `API_SERVER_KEY` (16+ chars, not a placeholder), not `API_SERVER_ENABLED`.
- `GET /v1/skills` always 500s upstream (`include_editorial` kwarg). Use dashboard `/api/skills`. Bead hermes-mac-6eg.
- `GET /api/config/raw` returns `{yaml, path}` but `PUT` takes `{yaml_text}`.
- Error envelopes differ: `{"error":{message,code}}` (API), `{"error":"..."}` (jobs), `{"detail":...}` (dashboard). `HermesError.from` handles all three.
- Chat: `POST /api/sessions/{id}/chat/stream` SSE. Event names: run.started, message.started, assistant.delta,
  tool.progress (`tool_name:"_thinking"` = reasoning), tool.started/completed/failed (no call id; matched by name),
  assistant.commentary, approval.request, assistant.completed, run.completed|failed|cancelled, error, done.
  Long `: keepalive` gaps are normal on slow local models (95 s for "pong" on Bonsai 27B 2-bit).
- `URLSession.bytes.lines` drops blank lines, so `SSEParser` flushes a frame on the next `event:` line.
- Approvals from the session stream are answered at `POST /v1/runs/{run_id}/approval {choice, request_id}`.
- A job created with `paused:true` reports `state:"paused"`, `enabled:false`.
- Hermes refuses models with < 64K context (`MINIMUM_CONTEXT_LENGTH`).

## Session source vs chat admission (found 2026-11-22 in GUI testing)
`POST /api/sessions` accepts any `source`, but `/api/sessions/{id}/chat/stream` refuses (`permission_denied`)
sessions whose source is not `api_server` or `bot_room`. Never send `source`; the default is `api_server`.

## Attachments (read from api_server.py 2026-11-22; beads hermes-mac-ard / -6uj)
- `/api/sessions/{id}/chat/stream` body `message` (or `input`): a string or OpenAI-style parts. Accepted part types:
  `text`/`input_text`/`output_text` and `image_url`/`input_image` (`data:image/...;base64,` or http(s) URL).
  `file`/`input_file` and non-image data URLs -> 400 `unsupported_content_type`. No upload endpoint on the API server.
- Limits: 10 MB request body (413 `body_too_large`), 64 KiB text (silently truncated), 10 images/turn,
  `gateway.max_inbound_media_bytes` (default 128 MB). Image-only turns get the text "What do you see in this image?".
- Stored user rows are TEXT: each image -> `[Image attached at: <server path>]` + `[screenshot]` lines (path under
  `cache/documents/native-inputs/`); the pixels come back via dashboard `/api/media` while Hermes keeps the file. Text files are inlined client-side as `[Attached file: name]` + fenced block (ContentParts.swift).

## Profiles (verified 2026-11-22, bead hermes-mac-zc9)
- A profile = a separate HERMES_HOME (`<root>/profiles/<name>/`): own config.yaml/model, .env, skills, memory,
  SOUL.md, cron and **its own state.db, so sessions are per profile**. `default` is the root home.
- List/create/delete/describe on the dashboard: `GET/POST /api/profiles`, `DELETE /api/profiles/{name}`,
  `PUT /api/profiles/{name}/description`. `GET /api/profiles/active` -> `{active, current}`; `current` is the
  dashboard's own profile. `POST /api/profiles/active` only flips the sticky CLI default - the app never calls it.
- Every dashboard route we use takes `?profile=<name>` (skills, cron runs, toolsets, model, memory, config, logs,
  analytics, search). `HermesClient.scoped(to:)` adds it.
- API server: native routes are mirrored at `/p/<name>/...` on the same port, but only for profiles the gateway
  serves: `gateway.multiplex_profiles: true` (dashboard `/api/status` `gateway_shared_with` lists them). Unknown or
  unserved prefix -> 404 `{"error":"Unknown or unconfigured profile","code":"profile_unknown"}`. `/p/hermes/` aliases default.
- Auth on `/p/<name>/` is that profile's OWN `API_SERVER_KEY` from its .env; none -> 401 (fail closed). New profiles
  don't inherit it. `PUT /api/env?profile=<name> {key:"API_SERVER_KEY", value}` sets one; effective immediately.
  `/health` is unauthenticated, so probe with `GET /api/sessions?limit=1`.
- No per-turn routing into another profile's session: the app's `@name` mention starts a new chat in that profile.

## Images from Hermes (verified 2026-11-22 on the dev server, bead hermes-mac-p81)
- The agent delivers a host file as `MEDIA:/abs/path.png`. Only the FINAL reply (`assistant.completed.content`,
  `/chat`, `/v1/*`) rewrites image tags (png/jpg/jpeg/gif/webp/bmp, <= 5 MB) into `![image](data:image/...;base64,...)`.
  `assistant.delta` and stored history (`GET /api/sessions/{id}/messages`, `run.completed.messages`) keep raw `MEDIA:`.
- Dashboard `GET /api/media?path=<abs>` -> `{data_url}`; image extensions only (415), under
  `<HERMES_HOME>/{images,screenshots,cache}` (403 elsewhere), 404 gone, 413 > 25 MB. `/api/media/proxy?url=` fetches
  FAL/GCS hosts only. The API server has no file route.
- image_gen returns JSON `{success, image: <url or abs path>}` to the MODEL; `tool.completed` carries no result
  (`preview`/`args` null), so the picture reaches clients only if the model writes `MEDIA:` or `![](url)`.
- Client: `HermesKit/Markdown/ChatImages.swift` (parse) + `HermesMac/UI/ReplyImages.swift` (load/render). Remote
  http(s) images wait for a click unless `chat.loadRemoteImages` (tracking/exfil links); file:// is never loaded.
