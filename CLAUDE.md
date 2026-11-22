# Project Instructions for AI Agents

**Talaria** is a native macOS client for NousResearch Hermes Agent (repo/module names still say Hermes;
the app, bundle and process are "Talaria"; bundle id stays net.jmaddington.hermes so Keychain/defaults carry over).

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:1105d646 -->
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

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->


## Build & Test

```bash
./scripts/build.sh                      # -> build/Talaria.app, signed with Developer ID if present
swift run hermes-checks                 # unit checks + live API checks (if dev/hermes-home/.env exists)
HERMES_CHECK_CHAT=1 swift run hermes-checks   # + one real streamed chat turn (slow on local models)
HERMES_CHECK_VOICE=1 swift run hermes-checks  # + offline TTS -> VAD -> on-device STT round trip
HERMES_SRC=/path/to/hermes-agent ./scripts/dev-hermes.sh   # local Hermes (:8642 + :9119) on LM Studio
./scripts/dev-tts.sh                    # local Kokoro TTS (mlx-audio) on :8880; Settings > Voice > Local server
DMG_NO_FINDER=1 ./scripts/package.sh   # signed DMG + SHA256SUMS in build/dist (release flow: docs/agents/release.md)
git tag v0.2.0 && git push --tags     # CI builds, signs, notarizes and publishes a GitHub Release
```

GUI testing (see docs/agents/gui-testing.md): launch with `open` (not the binary directly) so Hermes owns its
mic/TCC prompts; capture only the Hermes window (`screencapture -l <id>`), never the full screen (user's
other windows). Voice harness: `open --env HERMES_VOICE_TEST=1 build/Talaria.app`, enter voice mode (Opt-Cmd-V),
then `swift scripts/voice-inject.swift q.aiff` feeds a file in place of the mic; verify via
`/usr/bin/log show --predicate 'subsystem == "net.jmaddington.hermes"'` grep `VOX-HEARD` / `VOX-SPEAK`.

Launch the built app against the dev server (seeds the Keychain on first run):
`set -a; source dev/hermes-home/.env; set +a; HERMES_API_KEY=$API_SERVER_KEY HERMES_DASHBOARD_TOKEN=$HERMES_DASHBOARD_SESSION_TOKEN build/Talaria.app/Contents/MacOS/Talaria`

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
