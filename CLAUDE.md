# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


## Build & Test

```bash
./scripts/build.sh                      # -> build/Hermes.app, signed with Developer ID if present
swift run hermes-checks                 # unit checks + live API checks (if dev/hermes-home/.env exists)
HERMES_CHECK_CHAT=1 swift run hermes-checks   # + one real streamed chat turn (slow on local models)
HERMES_CHECK_VOICE=1 swift run hermes-checks  # + offline TTS -> VAD -> on-device STT round trip
HERMES_SRC=/path/to/hermes-agent ./scripts/dev-hermes.sh   # local Hermes (:8642 + :9119) on LM Studio
./scripts/dev-tts.sh                    # local Kokoro TTS (mlx-audio) on :8880; Settings > Voice > Local server
```

GUI testing (see docs/agents/gui-testing.md): launch with `open` (not the binary directly) so Hermes owns its
mic/TCC prompts; capture only the Hermes window (`screencapture -l <id>`), never the full screen (user's
other windows). Voice harness: `open --env HERMES_VOICE_TEST=1 build/Hermes.app`, enter voice mode (Opt-Cmd-V),
then `swift scripts/voice-inject.swift q.aiff` feeds a file in place of the mic; verify via
`/usr/bin/log show --predicate 'subsystem == "net.jmaddington.hermes"'` grep `VOX-HEARD` / `VOX-SPEAK`.

Launch the built app against the dev server (seeds the Keychain on first run):
`set -a; source dev/hermes-home/.env; set +a; HERMES_API_KEY=$API_SERVER_KEY HERMES_DASHBOARD_TOKEN=$HERMES_DASHBOARD_SESSION_TOKEN build/Hermes.app/Contents/MacOS/Hermes`

## Toolchain constraints (Command Line Tools only, no Xcode)

- No XCTest and no Swift Testing macros: checks are the `hermes-checks` executable.
- No SwiftUI macro plugin: write `@ViewState` (typealias for classic `SwiftUI.State`), never `@State`;
  no `#Preview`, no `@Entry`. `@Observable` works (Observation macros ship with CLT).
- Check runners must not block main (AVSpeechSynthesizer calls back on main): use `waitPumpingRunLoop`.

## Architecture Overview

- `HermesKit` (library): `API/` HTTP + SSE client for both Hermes servers (see docs/agents/api-notes.md);
  `Voice/` drive-mode port: VAD, sentence splitter, STT (Apple on-device / OpenAI), TTS (system / OpenAI),
  `VoiceAudio` (one AVAudioEngine for mic + playback so voice-processing AEC enables barge-in), earcons.
- `HermesMac` (app): `AppModel` (connection, Keychain), `ChatStore` (sessions + streaming), `VoiceController`
  (voice state machine), `LibraryStore` (skills/jobs/tools/memory), SwiftUI views per section.
- Browser panel + Hermes browser tool: `Features/Browser/` (WKWebView inspector) served to Hermes as MCP tools by
  `HermesMCPServer` (loopback listener) over `HermesKit/MCP` (pure-Foundation protocol). See docs/agents/browser-tool.md.
- Voice mode reference implementation: github.com/jmaddington/drive-mode (VAD thresholds, earcon vocabulary).

## Conventions & Patterns

- Logging: `Logger` with a unique grep code suffix, e.g. `[VOX-STT-ERR]`. No emoji.
- Every user-facing failure goes through `AppModel.run`/`flash` - never swallow errors silently.
