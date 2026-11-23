# GUI testing notes (verified 2026-11-22)

- Screenshots: `screencapture -x -o -l <windowID>`; get the ID from `CGWindowListCopyWindowInfo` filtered on owner  "Alaria" (the app process name), layer 0 (first entry = frontmost, e.g. the Settings window when open). The terminal needs Screen Recording.
- Clicks: CGEvent posting (needs Accessibility for the terminal); `cliclick` for modifier-held clicks (ctrl-click
  context menus). Menu items: `osascript ... click menu item "X" of menu 1 of menu bar item "Y"`.
- Keyboard shortcuts via System Events: Shift-Cmd-V never reached the app on the dev Mac (a global hotkey grabs it),
  which is why voice mode is Opt-Cmd-V.
- Launch with `open build/Alaria.app`: starting the binary from a terminal makes the terminal the TCC-responsible
  process, so the mic permission request hangs at STARTING.
- Voice with AEC ON cancels audio played through the same Mac's speakers (`say` won't be heard); use the
  HERMES_VOICE_TEST=1 + scripts/voice-inject.swift harness instead. AEC OFF + `say` works but also hears the room.
- Plain `Text` with `.monospaced` design renders SF Mono; `TextEditor` (NSTextView) needs
  `Font(NSFont.monospacedSystemFont(...))` or it falls back to Courier.
- KEYSTROKE SAFETY (incident 2026-11-22): System Events `keystroke` goes to whatever app is FRONTMOST, not the
  process named in `tell process`. A click on an inactive window may not activate it. Always `tell application
  "Alaria" to activate`, then verify `name of first process whose frontmost is true` == "Alaria" immediately before
  typing, and abort otherwise. Other Claude sessions run in iTerm on this Mac; stray text there becomes a prompt.
