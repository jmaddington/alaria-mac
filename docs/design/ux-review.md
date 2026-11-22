# Hermes for Mac: interaction and flow review

Lens: information architecture, keyboard, feedback, conversation, voice, editing flows, Mac conventions.
Read-only review of Sources/HermesMac (no GUI use) plus the screenshots in the session scratchpad `design/`.
The attachments, profile/@mention, browser fly-out and Google TTS features are not re-proposed; section 8 says how they should feel.

## Top 5 highest impact

1. **Make the transcript a first-class Mac document** (Find, copy, per-message actions, Share/Export). Today a reply can only be selected by hand; there is no Copy, Regenerate, Edit-and-resend, or Find in conversation.
2. **Keyboard-first conversation**: focus composer (⌘L / any typing), Esc to stop, ↑ to recall/edit last message, ⌘K quick switcher across chats/skills/jobs, ⌘F find. Today only ⌘N, ⌘., ⌘R, ⌘1-7 and ⌥⌘V exist.
3. **Tool activity and approvals you can trust**: expandable tool chips (input/output), approval notification + Dock badge when backgrounded, "Always Allow" scoped and undoable. Currently chips are inert and an approval in a background window is invisible.
4. **State restoration and window model**: reopen on the same section/chat/draft/column widths; per-window selection (`@SceneStorage`), real multi-window and "Open Chat in New Window". Today `model.section` is a single app-global var and all state resets at launch.
5. **Guided first run and honest empty/error states**: onboarding that tests the connection live, explains the optional Dashboard (what it unlocks), and leaves a useful disconnected state instead of "Not Now" into a dead app. Toasts become actionable (Retry / Undo / Open Settings) and errors persist until dismissed.

## 1. Information architecture

**Sidebar** (RootView.swift:62-82): Chats, Skills, Scheduled / Agent: Tools, Memory / Insight: Usage, Logs. Sound and conventional. Issues:
- Three columns are used for every section, including Usage/Logs/Tools where the middle column is a thin list and the detail is the point. That is fine; keep, but let the middle column collapse (⌥⌘S style toggle) when a section has few items, and remember per-section widths.
- The sidebar has no live status: no unread/running indicator on Chats (a streaming chat in another section), no count badge on Scheduled for failing jobs. Proposal: `.badge()` on Scheduled when any job's `lastStatus` is failed; a small spinner on Chats while any stream is active.
- The connection badge (RootView.swift:84-123) opens Settings in all states. When `.failed`, it should offer Retry in a popover (Reload exists only as ⌘R, which is not discoverable).
- Dashboard-gated sections show `NeedsDashboard` per section. Show a locked affordance in the sidebar (lock glyph + "Needs Dashboard") so the user understands why before clicking.

**Persistence**: `AppModel.section` defaults to `.chats` every launch (AppModel.swift:120). Use `@SceneStorage("section")`, `@SceneStorage("chatSelection")`, and persist `chats.draft` per session (drafts are lost on quit). Approach: a small `RestorableState` Codable in `@SceneStorage`, applied in `AppModel.start()`.

## 2. First run and discovery

- OnboardingView (RootView.swift:128-170) is one sheet of two credential pairs. "Not Now" dismisses to a window that says nothing. Proposal: three-step sheet (Connect, Optional Dashboard, Try voice/Microphone) with live validation (debounced test on field edit, green check inline), a "Find local Hermes" button that probes 127.0.0.1:8642/9119 and reads `~/.hermes/.env` via an open panel, and a disconnected main window with a single prominent "Connect to Hermes" empty state.
- Discovery of features: Greeting (ChatViews.swift:216-252) offers four prompt starters, which is lovely. Extend with a one-time "tips" row that shows the shortcuts that matter (⌥⌘V voice, ⌘K switcher, @profile when it lands) and dismisses itself after use. Add a Help menu with "Keyboard Shortcuts" (a sheet generated from the command list); currently Help is the system default.
- Starter chips only fill the draft. Return should run them on double-click or when the user clicks while holding ⌥; keep single click as fill-and-focus (and ensure focus actually moves to the composer: set `focused = true` via a `FocusedValue` request).

## 3. Keyboard-first use

Present: ⌘N, ⌘. (stop), ⌘R, ⌘1-7, ⌥⌘V, ⌘S in editors, Return to send, Space/Esc in voice.
Missing (all straightforward in HermesApp.swift `.commands`):
- **⌘L / ⌘⇧L: focus composer** from anywhere; typing a printable character in the transcript should also redirect to the composer (Messages does this).
- **Esc while streaming = Stop** (composer `.onKeyPress(.escape)`); Esc in the sidebar search clears it.
- **↑ in an empty composer recalls the last user message** for editing (and resend), the single most-used chat keystroke after Return.
- **⌘K quick switcher** (palette over chats, skills, jobs, sections, commands). A `.sheet` with a text field and a ranked list reusing `chats.searchHits`; this also solves discovery.
- **⌘F find in conversation** with highlights and ⌘G/⇧⌘G; `.searchable` on the detail with scoped token, or an inline find bar above the transcript.
- **⌘[ / ⌘]** back/forward between chats; **⌥⌘↑/↓ or ⌃Tab** previous/next chat. SessionList already has selection, so this is index math.
- **⌘⌫** delete (with the existing confirm), **⌘D** duplicate, **⌘E** archive, **Return** to rename when the list is focused. Today these are context-menu only (ChatViews.swift:100-107).
- File menu: ⌘N is "New Chat" which replaces `.newItem`; add ⌘W close window, ⌘⇧N new window, Export Chat… (⌘⇧E), Print (⌘P) via `CommandGroup`.
- Composer: ⌘Return is bound on the send button but Return already sends via `onSubmit`; document the contract in a placeholder hint ("Return to send, ⌥Return for a new line") shown on first focus, and consider a Settings toggle "Return inserts newline, ⌘Return sends" for long-form writers.
- Voice overlay: Space is a hidden button; confirm it does not fire while a TextField is focused (VoiceView.swift:70-71). Add ⌘. to stop speaking (consistent with chat) and show shortcut hints under the controls.

## 4. Feedback

- **Toast** (RootView.swift:107-120): a single string, 3 s, bottom-centered over the composer region (`padding(.bottom, 90)`), tap to dismiss. Errors vanish before they can be read or acted on. Proposal: `Toast { message, kind, action }`; errors persist ~8 s with a Retry/Open Settings button, successes 2 s; queue instead of overwrite; `accessibilityAnnouncement` for VoiceOver. Place above the composer using safeAreaInset rather than a magic 90.
- **Undo for destructive actions**: archive and pin should toast with Undo (⌘Z) rather than confirm. Reserve the confirmation dialog for Delete (already present).
- **Progress**: skills/jobs saves show "Saving…" inline (SkillsViews.swift:32); also reflect in the window with `.navigationSubtitle` so it survives column changes. Long loads (skills list) use a bare ProgressView; use skeleton rows to avoid layout jump.
- **Empty states** are good (EmptyState with actions). Gaps: a chat that failed to load has Try Again (good); an offline state for lists should say "Hermes is unreachable" with Retry, not an empty list.
- **Dock/notification feedback**: when a chat finishes or an approval arrives while Hermes is not frontmost, post a `UNUserNotification` and set the Dock badge. Scheduled-job failures likewise (with "Open Job" action).

## 5. Conversation UX

Problems (ChatViews.swift:261-300 EntryView, 380-440 Composer):
- **No message actions.** Add a hover toolbar on assistant messages (Copy, Copy as Markdown, Regenerate, Share) and user messages (Edit & Resend, Copy), plus a context menu with the same items, and a "Copy" on code blocks (MarkdownView). `ShareLink`/`NSSharingServicePicker` for the whole chat; Export as Markdown via `fileExporter`.
- **Streaming**: followTail logic is good. Add a floating "Jump to latest" pill when the reader has scrolled up during streaming; show elapsed time / token rate subtly on the active entry; keep Stop in place of Send (already done) and also expose it in the toolbar.
- **Stop** leaves "Stopped" label and trims a dangling marker; add "Continue" and "Regenerate" buttons on that stopped entry.
- **Queueing**: if the user types while streaming, Return currently is ambiguous. Define: Return queues the message ("Queued, sends when Hermes finishes" chip with an x), ⌘Return interrupts and sends now.
- **Thinking**: the DisclosureGroup is collapsed and the label alternates "Thinking…"/"Thought process" (good). Add duration ("Thought for 8s") and auto-expand while streaming if the user has expanded one before (remember preference).
- **Tool activity** (ToolChips, 336-356): chips show name and a one-line preview and are inert. Make each chip clickable to a popover with arguments and result (monospaced, copyable, truncated with "Show all"); group consecutive calls ("5 tool calls") with a roll-up that shows the currently running one; failed chips should carry the error text.
- **Approvals** (ApprovalCard): the no-shortcut decision is correct and must stay. Improve: show which chat/profile the request comes from, a risk hint (command contains rm/sudo/curl|sh), keep "Always Allow" visually secondary and require a confirm that names the scope, and notify when the app is backgrounded. Disable the composer's Send hint while an approval is pending ("Waiting for your approval").
- **Composer**: grows 1-10 lines (good). Add a placeholder hint row for attachments/@profile (when they land), a character-free design; draft persists per chat; ⌘V of an image is handled by the attachments work.
- **User bubble** has no timestamp or status; show a hover timestamp and a "Sending…/Failed, Retry" state.

## 6. Voice mode flow

VoiceView.swift is the best-designed flow in the app. Refinements:
- Entry: waveform button appears both in the toolbar and in the composer when the draft is empty; fine. Add a one-time mic-permission pre-explainer before the system prompt rather than after a failure.
- Error state ("Voice mode couldn't start") only has OK; add "Open System Settings" for TCC denial and "Try Again".
- Show a compact transcript peek: swipe/scroll up (or press ↑) reveals the last few turns so the user can verify what was heard; Caption already shows `heard`.
- Show a barge-in hint on first use ("Just start talking to interrupt") and keep Esc/Space hints visible under controls for the first three sessions.
- When voice ends, land in the same chat with the voice turns as normal messages, and a toast "Voice session saved to <title>".
- Provide a minimized/mini orb mode (small floating window or the toolbar) so voice can run while the user looks at another section.

## 7. Skills and jobs editing

- Skill editor (SkillsViews.swift:140-240): edit/preview segmented control, ⌘S, Revert, orange draft dot in list (excellent). Add: ⌘⇧P toggle preview, split view (edit left, preview right), Quick Look-style preview on Space in the list, syntax highlighting for frontmatter, a "Duplicate" and "Reveal path / Copy path". Warn on section switch only if dirty drafts exist (drafts are already kept, so just rely on the dot and add a Window document-edited indicator via `NSWindow.isDocumentEdited`).
- Skills list: filter field replaces `.searchable` for layout reasons (note x0h); give it ⌘⌥F focus and Esc to clear. Add an enable/disable toggle in the row context menu and drag-to-reorder nothing; keep simple.
- Jobs (JobsViews.swift): the schedule field is free text with a caption of formats. Add live "Next run: Mon 9:00 AM" preview parsed server-side (or client heuristic), a run history list with output Quick Look, "Run now" with a result toast linking to the run, and ⌘⏎ to save-and-run. Unsaved-changes dot in the list like skills.
- Create flows: New Skill/New Job use `.sheet`; ensure Return = default action and Esc cancels (NewSkillSheet has defaultAction; verify cancelAction).

## 8. How incoming features should feel

- **Attachments / screenshot paste**: attachments appear as removable thumbnails/file chips above the text field inside the glass composer, drag-over highlights the whole composer with a dashed ring and "Drop to attach", ⌘V with an image attaches without stealing the text paste, Quick Look (Space) on a chip, and chips remain in the transcript user bubble. Also accept drops anywhere on the window and drops onto the Dock icon.
- **Profile switching / @profile**: `@` opens an inline completion popover (↑↓, Return/Tab to accept) anchored to the caret; the selected profile becomes a colored token in the field, and the toolbar shows the active profile as a quiet pill menu. Switching never loses the draft. Per-profile accent subtly tints the orb and send button.
- **Right-side browser fly-out**: slide in with `.inspector` (standard Mac chrome, toggled by ⌥⌘B and a toolbar button), width persisted, auto-opens when Hermes starts driving but never steals keyboard focus; a clear "Hermes is controlling this page" banner with a Take Over/Pause button; Esc returns control; page screenshots appear as thumbnails in the transcript. Provide a visible agent cursor.
- **Google TTS**: voice choice with audition (play sample) button and per-voice preview in Settings; voice-mode latency feedback (orb "Thinking" until first audio); fall back gracefully to system voice with a one-time toast.

## 9. Settings organization

SettingsView.swift:7-14: Connection, Voice, Model, Config tabs, fixed width 600. Connection and Voice are local app preferences; Model and Config edit the Hermes server's state. Mixing them hides a boundary the user should see.
- Rename/regroup: General (launch, Return behavior, notifications), Connection, Voice, and a separate "Hermes Server" area (Model, Config) that shows which host it affects; consider opening it from Tools/Agent in the sidebar instead.
- Add Profiles (when profiles land), Keyboard Shortcuts (read-only reference at first), and Privacy (clear local drafts/cache).
- Make tab content height adapt (currently only width is fixed); Voice pane has many AppStorage fields: group into "Listening", "Speaking" with a Test button.
- Add the standard ⌘, from every window and an app-level "Hermes > Settings…" (SwiftUI does this); also add Check Connection to the Connection pane header.

## 10. Missing Mac conventions

| Convention | State | Proposal |
|---|---|---|
| Find (⌘F) | missing | in-conversation find bar; Skills/Logs find |
| Copy actions | only text selection | message/code copy buttons, ⌘C on selected message row |
| Context menus | session list only | transcript messages, tool chips, skills, jobs, logs lines |
| Drag and drop | none (grep: no onDrop/dropDestination) | drag chat out as Markdown/text; drop files/images into composer (attachments agent); drop skill folders into Skills |
| Quick Look | none | Space on attachment, skill, run output |
| Toolbar | static: voice button; per-section items | contextual: model pill, share, profile pill, inspector toggle; customizable toolbar via `.toolbar(id:)` |
| State restoration | none | `@SceneStorage`, per-window selection, `NSWindow` frame already automatic |
| Multiple windows | WindowGroup exists but one shared AppModel (`@ViewState private var model`, HermesApp.swift:6) so windows mirror each other | per-window selection state, "Open in New Window" (context menu and ⌘⇧N), `openWindow(value: sessionID)` |
| Menu bar extra | none | `MenuBarExtra` with quick prompt field, running jobs, voice toggle, global hotkey (⌃⌥Space) |
| Services / Share | none | Services menu "Ask Hermes about Selection", Share extension and `ShareLink` of a chat; `NSApp.servicesProvider` |
| Dock menu / Handoff | none | Dock menu: New Chat, Start Voice; `NSUserActivity` per chat |
| App Intents / Shortcuts | none | "Ask Hermes" intent (also unlocks Siri and Spotlight) |
| Notifications | none | completions, approvals, job failures |
| Undo | none | undo archive/pin/rename via `UndoManager` |
| Help menu | default | shortcuts sheet, "Report an issue", link to docs |

## 11. Delightful touches

- Orb as identity: tint the toolbar waveform button with a faint breathing orb while Hermes is working in any chat.
- Sound and haptics: a soft tick on send, a two-note chime on completion (muted by default when frontmost), trackpad haptic on approval buttons.
- "Hermes is thinking" shimmer on the chat row in the sidebar for background streams.
- Greeting that uses the user's name and context (time of day exists; add "You have 2 jobs running today").
- Chat titles that animate in as Hermes auto-names them; drag a chat row to the Scheduled section to turn it into a job.
- Smooth "send" animation: the user bubble flies up from the composer into the transcript.
- Easter egg: typing `/` in the composer opens a slash-command menu (skills, profiles, /voice, /clear) with live fuzzy search; teaches the skills library by use.
- Voice: when ending a session, the orb collapses into the toolbar waveform button.

## Priority order (maps to beads)

P1: message actions and Find; keyboard model + ⌘K; tool-chip detail and approval notifications; state restoration and window model.
P2: onboarding rewrite; actionable toasts/undo; settings regrouping; voice error/permission flow; menu bar extra and Services.
P3: skills/jobs editor polish; delight pass; Dock menu/App Intents.
