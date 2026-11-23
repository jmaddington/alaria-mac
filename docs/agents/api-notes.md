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
- Chat (legacy; the Mac app uses /v1/runs, see "Detached turns" below; iOS still streams): `POST /api/sessions/{id}/chat/stream` SSE. Event names: run.started, message.started, assistant.delta,
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

## Per-chat model + "/" commands (verified 2026-11-22, bead hermes-mac-ptp)
- The API server does NOT run slash commands: "/model" sent as a chat message reaches the LLM as plain text. The
  composer's "/" menu (SlashCommandsUI.swift, catalog in HermesKit/API/SlashCommands.swift) maps each command to a
  real endpoint client-side; `SlashRouter.executors` is pluggable for a future dashboard `/api/ws` backend.
- `POST /api/sessions/{id}/model {provider, model, model_options}` persists a confirmed session model lock and sets the
  session row's `model`; later turns run on it. `POST /api/sessions` takes the same fields + `require_model_lock:true`.
  `model_options`: `{reasoning:{enabled:false}}` or `{reasoning:{enabled:true, effort}}`, `service_tier:"priority"`.
- The lock replaces `model_options` wholesale and `model_config` is never returned, so the app remembers each chat's
  full choice (SessionModels, UserDefaults) and resends it. No unlock endpoint: "default" = lock to the global model.
- `GET /api/model/options` (API server) also returns top-level `model`/`provider`: the global default.
- SSE `runtime` {provider, model, route_source, model_lock}: on run.started only reflects a lock (empty otherwise);
  assistant.completed / run.completed carry the effective runtime.
- No API-server route for /compress, /undo, /rewind, /yolo (store has set_yolo, no HTTP route), /queue, /bg, /btw,
  /goal, /personality, /verbose, /rollback, /diff.

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

## Detached turns: /v1/runs (verified 2026-11-22 on the dev server, bead hermes-mac-wny)
Why: the session chat stream interrupts the agent when its SSE client disconnects (api_server.py
`_drain_session_stream_task_on_disconnect`). A run keeps going and saves its reply with no one attached.
- `POST /v1/runs {session_id, input}` -> 202 `{run_id, status:"started", replayed}`. `input` = string, or
  `[{role:"user", content:[OpenAI parts]}]` (the LAST message's content is used; images work, stored like chat/stream:
  `[Image attached at: ...]` + `[screenshot]`). Optional `Idempotency-Key` header makes retries safe (replayed:true).
  Session model locks apply (sending no `model` keeps them; "session /model wins").
- A run posted to a busy session is accepted the same way but `GET /v1/runs/{id}` says `queued` until it starts after
  the current one (no `run.queued` event on this path, and EVERY run reads `queued` for a moment after the 202).
- `GET /v1/runs/{id}` -> `{run_id, status, session_id, created_at (server clock), output, usage, runtime,
  pending_controls:[{kind:"approval", prompt_id, execution_generation, command, description, choices}], error}`.
  status: queued|running|waiting_for_approval|stopping|completed|failed|cancelled|interrupted (gateway restart).
  Unknown run -> 404 `run_not_found`. Terminal statuses are kept for a while (RUN_STATUS_TTL), durable with idempotency.
- `GET /v1/runs/{id}/events` SSE: frames are `id: <seq>` + `data: {event, run_id, timestamp, ..., seq}` with NO
  `event:` line. Replays everything after `?last_seq=N` (or `Last-Event-ID`), from a 1000-event backlog; `: open` /
  `: keepalive` / `: stream closed` comments; `replay.truncated {oldest_retained_seq}` if the backlog lost some.
  The buffer is swept 300 s after the run was CREATED unless a subscriber is attached -> events 404 while status still
  answers (poll it). Completed runs replay fully until the sweep.
- Event names (differ from chat/stream!): `message.delta {delta}`, `message.interim {text, already_streamed}`,
  `reasoning.available {text}` (no `_thinking` stream), `tool.started {tool, preview, tool_call_id}`,
  `tool.completed {tool, duration, error: bool, tool_call_id, preview}`, `approval.request {prompt_id,
  execution_generation, command, description, choices}`, `approval.settled {prompt_id}`, `run.steered`,
  `run.completed {output, usage:{input_tokens, output_tokens, total_tokens}, runtime, completed, partial, interrupted}`,
  `run.failed {error}`, `run.cancelled {interrupted, turn_exit_reason}`, `subagent.start|complete`. No run.started /
  message.started / message ids. Rows are written to the session while the run goes (user row first, then tool steps).
- runtime on this server's (session-authority) runs is `{provider:"", model:"", route_source:"global"}`: no served
  model, unlike chat/stream's assistant.completed. HermesKit ignores an empty runtime.
- Answer approvals with `POST /v1/runs/{id}/approval {request_id: <prompt_id>, execution_generation, choice}` -> 200
  `{status:"resolved"}`. `/steer {input}` -> `{accepted:true}` while running, 409 `run_not_accepting_steer` once it
  isn't. `/stop {}` -> `{status:"stopping"}`, then `run.cancelled`.
- Client: `HermesKit/API/Runs.swift` (startRun/runStatus/runEvents/RunEventMapper), `RunRegistry.swift` (persisted
  runs, history cut, busy input); `ChatStore` follows each run, resumes after relaunch, reconnects with backoff.
