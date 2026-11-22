# Hermes for Mac: visual craft review

Reviewed 2026-11-22 against the light-mode screenshots in the session scratchpad `design/` folder
(`01-chats-home.png` ... `14-chat-small-window.png`), a few older rich-state captures (`12-done.png`,
`28-kokoro.png`, `v12-draft.png`), and the SwiftUI source. Dark mode was assessed by reading code only;
nothing here was verified in a running dark-mode build. Line numbers are as of this date.

## Overall impression

The bones are right. It is a real three-column Mac app, it uses system list/form/toolbar chrome instead of
reinventing it, the empty states have a voice, and the voice-mode orb is the one screen that already feels
like a product someone would show on stage.

What keeps it from "ship it" is not any single screen. It is that the app has not decided on a few things,
so every screen decides for itself:

- **Two accent colors.** `Theme.accent` is indigo, but nothing applies it as the app tint, so selection,
  toggles, sidebar icons, Save buttons and the Logs follow toggle are system blue while the user bubble,
  idea icons, chart and send button are indigo. In `14-chat-small-window.png` a saturated blue selected row
  sits 40 pt from a lavender bubble. It reads as two apps.
- **Glass is decoration, not a layer.** The composer and the connection badge wear `glassEffect`, but
  nothing ever passes behind them, so the material has nothing to do. Meanwhile the one place content does
  scroll under chrome (Logs) smears.
- **The detail column has no identity.** You cannot see the name of the chat, job, or toolset you are in
  anywhere but the list selection. The detail toolbar holds an orphaned waveform button and a search field
  that filters a different column.
- **Ad hoc scale.** Seven corner radii (7, 8, 10, 12, 14, 18, 22), one-off font sizes (30, 26 rounded, 21,
  17, 11.5), three different search/filter treatments, three different "on/off" treatments.

Fix those four and most of the nitpicks disappear with them.

## Top 5, highest impact

1. **One accent, applied everywhere, adaptive for dark mode.** (P1)
2. **Give the detail column a title, and move chat search to the list it filters.** (P1)
3. **Make the composer real glass: transcript scrolls underneath it; drop glass-on-glass in the sidebar.** (P1)
4. **Transcript typography and code blocks: a reading scale, visible code surfaces, a stronger user bubble.** (P1)
5. **Rework the Chats home (greeting) so the first screen looks designed, not defaulted.** (P2)

Details follow, then the remaining proposals in priority order, then a polish list and the dark-mode audit.

---

## 1. One accent, applied everywhere

**What's wrong.** `Theme.swift:11` defines indigo `Color(red: 0.36, green: 0.39, blue: 0.96)` with the
comment "used sparingly: selection, the user's bubble, the orb". Selection is not actually indigo: there is
no `.tint(...)` anywhere in `Sources/` and no accent color in the bundle. Evidence:
`04-skill-editor.png` (blue selected row, blue switch), `06-job-detail.png` (blue row), `10-logs.png` (large
blue follow button), `07-tools.png` (15 blue switches), sidebar glyphs in every screenshot, versus
`02-chat-transcript.png` (lavender bubble, indigo composer button) and `09-usage.png` (indigo chart).

**Change.**

- `Theme.swift:11-12`: make the accent adaptive rather than a fixed sRGB triple.
  ```swift
  static let accent = Color(nsColor: NSColor(name: nil) { a in
      a.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
          ? NSColor(srgbRed: 0.55, green: 0.58, blue: 1.00, alpha: 1)   // dark: lifted for contrast on #1E1E1E
          : NSColor(srgbRed: 0.33, green: 0.34, blue: 0.90, alpha: 1)   // light: slightly deeper than today
  })
  static let accentSoft = accent.opacity(0.14)   // see item 4 for the dark-mode bubble value
  ```
- `HermesApp.swift:11` and `:41`: `.tint(Theme.accent)` on `RootView()` and on `SettingsView()`. That
  recolors switches, prominent buttons, sidebar symbols, the segmented picker, sliders, focus rings.
- List selection on macOS follows the system accent, not `.tint`. Two options, pick one:
  (a) add `NSAccentColorName` to `Resources/Info.plist` plus a compiled asset catalog (needs `actool`;
  check `xcrun --find actool` under CLT before committing to this), or
  (b) leave selection on the user's system accent and accept it. Option (a) is the right answer for a
  branded app; if `actool` is unavailable, do (b) and do not fake selection with `listRowBackground`, which
  loses the focused/unfocused states visible in `02` versus `14`.
- Replace the remaining hardcoded uses: `HermesMark` shadow (`RootView.swift:183`) already uses the token;
  chart scale (`AgentViews.swift:251`) is fine once the token adapts.

**Why.** An accent is a promise that "this color means Hermes / means active". Right now the promise is
broken on every screen. This is the single cheapest change with the widest visible effect.

## 2. Give the detail column a title; put search where it filters

**What's wrong.** In `02-chat-transcript.png` the detail toolbar shows a lone waveform button on the left
and "Search all chats" on the right. The conversation title and the `model · N messages` subtitle set at
`ChatViews.swift:205-206` never appear: the window title slot is taken by the content column's "Chats".
Same in `06-job-detail.png` (no job name), `08-memory.png` and `09-usage.png` (a blank 70 pt band above the
form). The search field (`ChatViews.swift:81`, `placement: .sidebar`) lands in the detail toolbar, far from
the list it filters; Skills uses a custom inline field (`SkillsViews.swift:28-40`), Logs uses a toolbar
field (`AgentViews.swift:363`). Three patterns for one job. The waveform toolbar button
(`ChatViews.swift:208-211`) duplicates the composer's voice button 600 pt below it.

**Change.**

- Extract the Skills inline filter field into a shared `FilterField(prompt:text:)` in `Theme.swift` and use
  it at the top of `SessionList` (via the same `safeAreaInset(edge: .top)`), replacing `.searchable`. Height
  28, corner radius 8, `.quaternary.opacity(0.6)` fill, `magnifyingglass` in `.secondary`.
- In each detail view add a leading toolbar title:
  ```swift
  ToolbarItem(placement: .navigation) {
      VStack(alignment: .leading, spacing: 0) {
          Text(title).font(.headline).lineLimit(1)
          Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
  }
  ```
  Chat: title + `model · 12 messages`. Job: name + schedule text. Tool: label + `N tools`. Memory/Usage: the
  selected row's name + period.
- Remove the toolbar waveform button (`ChatViews.swift:207-212`). The composer button and the menu command
  (Opt-Cmd-V) are enough; keeping one prominent entry point makes it feel intentional.

**Why.** Mail, Notes and Messages all tell you what you are looking at in the detail toolbar. Without it the
right two thirds of the window is anonymous, and the toolbar looks unfinished rather than minimal.

## 3. Composer as real glass; no glass on glass

**What's wrong.** `ChatViews.swift:166-203` stacks `ScrollView` then `Composer()` in a `VStack`. The composer
has `.glassEffect(.regular, in: .rect(cornerRadius: 22))` (`:439`) but sits on a flat
`textBackgroundColor`; nothing ever passes behind it, so in `02-chat-transcript.png` it is a faint grey
outline. In `12-done.png` it renders as a flat grey pill. The sidebar `ConnectionBadge`
(`RootView.swift:93`) puts a glass card on the already-glass Tahoe sidebar, which Apple's guidance
explicitly discourages, and it is the heaviest object in the sidebar for the least important information.

**Change.**

- Move the composer into the scroll view's safe area so the transcript runs beneath it:
  `ScrollView { ... }.safeAreaInset(edge: .bottom, spacing: 0) { Composer() }` and delete it from the
  `VStack`. Keep the `"bottom"` anchor; `scrollTo` respects the inset. Add
  `.scrollEdgeEffectStyle(.soft, for: .bottom)` so text fades as it goes under.
- Use `.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))` and bump the composer's minimum
  height to 44 (vertical padding 9, `ChatViews.swift:438`) so a one-line composer is a true capsule
  concentric with the 26 pt send button (8 pt inset all round).
- Greeting screen: same inset, so the composer does not jump between empty and populated chats.
- `ConnectionBadge`: remove `.glassEffect` (`RootView.swift:93`). Make it a plain single-line row:
  `StatusDot` + `Text("Connected").font(.caption.weight(.medium))` + host in `.caption` `.tertiary`,
  horizontal padding 16, bottom padding 10, with the standard hover wash (`hoverRow()`). Only when the state
  is `.failed` or `.unconfigured` promote it to a tinted capsule (`.orange.opacity(0.14)` fill) so trouble
  is the only time it draws the eye.
- Logs (`10-logs.png`): the first lines smear under the toolbar. Add
  `.scrollEdgeEffectStyle(.hard, for: .top)` to the log `ScrollView` (`AgentViews.swift:335`).

**Why.** Liquid Glass earns its place when content moves behind it. This one structural change is what makes
the chat screen feel like Tahoe instead of a Sonoma app with a rounded text field.

## 4. Transcript typography and code blocks

**What's wrong.**

- The reply is system body (13 pt) with 3.5 pt line spacing (`Markdown.swift:63`), fine for UI labels, tight
  for paragraphs of generated prose at a 720 pt measure (about 110 characters per line, see `12-done.png`).
- `CodeBlock` fills with `textBackgroundColor.opacity(0.6)` on a `textBackgroundColor` pane
  (`Markdown.swift:145`): white on white, held together only by a hairline. In `12-done.png` the block reads
  as a table outline, not as code. When there is no language it prints the word "code" (`:129`).
- User bubble is `accentSoft` at 12 % (`ChatViews.swift:287`): pale lavender in light mode, and by the math
  nearly invisible in dark mode.
- "Thought process" uses `brain`, the same glyph as the Memory section in the sidebar.
- Tables fill with `.quaternary.opacity(0.35)` and code does not: two surface treatments for sibling blocks.

**Change.**

- Add tokens in `Theme.swift`:
  ```swift
  static let prose = Font.system(size: 14)            // transcript + skill preview only
  static let proseLineSpacing: CGFloat = 5
  static let code = Font.system(size: 12.5, design: .monospaced)
  static let surface = Color.primary.opacity(0.045)   // code, tables, cards, idea chips
  static let hairline = Color.primary.opacity(0.08)
  ```
- `Markdown.swift`: paragraphs, list items and quotes use `Theme.prose` + `proseLineSpacing`; block spacing
  12 -> 14; headings `.title2/.title3/.headline` stay but get `.padding(.top, 10)` (was 4) so a heading
  owns the space above it. Narrow `Theme.readingWidth` 720 -> 680 to keep the measure near 85 characters.
- `CodeBlock`: fill `Theme.surface`, stroke `Theme.hairline`, radius 10; header row fill
  `Color.primary.opacity(0.03)` on top; hide the language label entirely when empty; code font `Theme.code`;
  copy button icon-only (`doc.on.doc` -> `checkmark` with `.contentTransition(.symbolEffect(.replace))`),
  shown at 60 % opacity until the block is hovered. Tables: same `surface`/`hairline`/radius 10, header row
  in `.caption.weight(.semibold)` `.secondary`.
- User bubble: fill `Theme.accent.opacity(colorScheme == .dark ? 0.30 : 0.14)`, radius 18, text in
  `Theme.prose`, max width 520 so long prompts do not become a wall.
- "Thought process": `sparkle` while streaming ("Thinking…" with `.symbolEffect(.pulse)`), `lightbulb` when
  done; leave `brain` to Memory.
- Inline code (`Markdown.swift:36-38`): keep, but size 12.5 to match blocks.

**Why.** The transcript is where people spend 95 % of their time. One size up with real leading and code that
visibly sits on a surface is the difference between "renders markdown" and "pleasant to read".

## 5. Chats home (greeting)

**What's wrong** (`01-chats-home.png`, `ChatViews.swift:221-260`). The greeting is 30 pt semibold with a full
stop, heavier than anything else in the app. The four ideas are grey slabs (`.quaternary.opacity(0.45)`,
radius 12) in a single column at the default window width, because `GridItem(.adaptive(minimum: 220))` only
fits one column in a 450 pt detail pane; they look like disabled form rows and have no hover state. The app
mark carries a 35 % indigo drop shadow that reads muddy on white.

**Change.**

- Greeting: `.font(.system(size: 28, weight: .semibold))`, no full stop, plus one secondary line under it:
  `Text("What should Hermes take on?").font(.title3).foregroundStyle(.secondary)`. Spacing mark -> greeting
  18, greeting -> subtitle 6, subtitle -> grid 28 (replace the single `spacing: 26`).
- Grid: two fixed columns, `[GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]`,
  `maxWidth: 460`, so it is 2 x 2 at every window size (minimum detail width fits two 190 pt chips).
- Chips: `Theme.surface` fill, radius 12, padding H 14 / V 12, icon in `Theme.accent` at
  `.font(.system(size: 15, weight: .medium))`, title `.callout.weight(.medium)`. Hover: fill
  `Color.primary.opacity(0.08)` with `.easeOut(0.12)`; pressed: `scaleEffect(0.98)`.
- `HermesMark` on this screen: size 52, shadow `Theme.accent.opacity(0.22)`, radius 10, y 5.
- Symbol swap: `magnifyingglass` -> `text.magnifyingglass` (plain magnifier reads as "search this app"),
  `clock.arrow.circlepath` -> `calendar.badge.clock` (the current one means "history / Time Machine").

**Why.** This is the first screen on every launch and in every screenshot of the product. It should look
composed at the default size, and the chips should look tappable.

---

## 6. List rhythm in the content column (P2)

**What's wrong** (`01`, `03`, `07`, `08`). Section headers get a full-bleed rule that runs to the column's
left edge while row separators are inset 16 pt; the gap from that rule to the first row is ~22 pt in Chats
and Skills but ~6 pt in Memory; a row can show separator + hover wash + selection at once
(`03-skills-list.png`, "apple-reminders"). Tools has no header and starts 20 pt lower than the others.
Row vertical padding is 3 in Chats and Jobs, 2 in Skills, 0 in Tools.

**Change.**

- One shared row modifier in `Theme.swift`, applied in all seven lists:
  `.listRowSeparator(.hidden)`, `.listRowInsets(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))`,
  and delete the per-row `.padding(.vertical, N)` (`ChatViews.swift:147`, `SkillsViews.swift:94`,
  `JobsViews.swift:40`). Separator-free rows with hover + selection are how Messages and Notes look on
  Tahoe and remove the triple-indicator problem.
- Section headers: `.listSectionSeparator(.hidden)`, text in `.subheadline.weight(.semibold)`
  `.foregroundStyle(.secondary)`, 14 pt above, 4 pt below.
- `HoverRow` (`Theme.swift:100-102`): with insets handled by the row, drop the negative padding and match
  the system selection radius (8, continuous).
- Session row title `.body.weight(.medium)` -> `.headline` is too much; keep medium but make the preview
  `.subheadline` (was `.callout`) so the two lines differ by size as well as color.

## 7. Library detail panes: Jobs, Memory, Tools (P2)

**What's wrong.**

- `06-job-detail.png`: the toolbar shows `play.fill` next to `play.circle` (Run Now beside Resume,
  `JobsViews.swift:169-173`). Two play glyphs, different meanings. Enable/disable is a switch in Skills and
  Tools but an icon button here.
- `08-memory.png`: three stacked grey bordered buttons in a form section (`AgentViews.swift:155-157`).
  `role: .destructive` does not color bordered buttons on macOS, so the most dangerous actions in the app
  look like the most ordinary ones.
- `07-tools.png`: descriptions are raw tool ids ("web_search, web_extract") in proportional `.callout`;
  15 switches at `.mini` in a navigation list; the detail pane is an empty state until you click, unlike
  Memory which auto-selects (`AgentViews.swift:110`).
- Run history rows print `Date.description` (`JobsViews.swift:156`): "2026-11-22 17:14:10 +0000".

**Change.**

- Jobs: replace the pause/resume toolbar button with a `Toggle("Enabled", ...)` `.toggleStyle(.switch)` as
  the first row of the Status section. Toolbar becomes Run Now (`play.fill`,
  `.labelStyle(.titleAndIcon)`), then a `ToolbarSpacer`, Delete (`trash`), Revert, Save.
  History rows: `startedAt.formatted(date: .abbreviated, time: .shortened)` and a relative time in
  `.secondary`.
- Memory: one section titled "Reset" with three plain rows, each
  `Button("Forget Memories…") { }.buttonStyle(.plain).foregroundStyle(.red)` and a `.caption` `.secondary`
  line under each saying what it erases. Full-row hit target.
- Tools: description in `.system(.caption, design: .monospaced)` `.secondary`; switches `.controlSize(.small)`
  to match the Skills header; auto-select the first toolset on load.
- Hide Revert until dirty in Skills and Jobs (`SkillsViews.swift:168`, `JobsViews.swift:178`) instead of
  showing a permanently disabled capsule (`04-skill-editor.png`).
- Skills mode picker (`SkillsViews.swift:162-165`): text segments "Edit" / "Preview" rather than
  `chevron.left.forwardslash.chevron.right` / `doc.richtext`; the icons need a tooltip to decode.

## 8. Usage and Logs (P2)

**What's wrong.**

- `09-usage.png`: stat values use `.rounded` design at 26 pt (`AgentViews.swift:295`), the only rounded type
  in the app. Y-axis prints "200,000" while the tiles print "173.8K". Bars are square. Both series are the
  same indigo at two opacities, so the legend dots are hard to tell apart. A trailing `Divider` hangs under
  the last model row (`:265`). The content column is spent on four identical `calendar` rows.
- `10-logs.png`: 11.5 pt mono lines wrap to three lines each with no hanging indent, so timestamps do not
  form a column and the eye cannot scan levels. The Follow toggle is the most saturated object on screen.

**Change.**

- `Stat`: value `.system(size: 24, weight: .semibold)` default design + `.monospacedDigit()`; fill
  `Theme.surface`; radius 12.
- Chart: `.cornerRadius(3)` on `BarMark`; `.chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text((v.as(Int.self) ?? 0).compact) } } }`;
  scale `["Input": Theme.accent.opacity(0.35), "Output": Theme.accent]`.
- "By model": drop the divider after the last row; put rows on a `Theme.surface` card, radius 12, to match
  the tiles.
- Usage periods: remove the `calendar` icons (`AgentViews.swift:201`); plain text rows. (Longer term this
  column wants to be a segmented control in the detail toolbar, which is an information-architecture change
  for the IA reviewer.)
- Logs: split each line into timestamp / level / message. Timestamp `.tertiary`; level as a fixed-width
  token colored `.secondary` (INFO), `.orange` (WARNING), `.red` (ERROR); message `.primary`. Font 11 pt
  mono, line spacing 2, row spacing 3, and indent wrapped lines under the message column with a
  two-column `Grid`. Keep the Follow toggle but as `arrow.down.to.line` with the tint from item 1 so it is
  indigo-on-glass rather than a blue disc.

## 9. Voice mode (P2, polish on the best screen)

**What's wrong** (`12-voice-listening.png`, `13-voice-muted.png`, `28-kokoro.png`).

- The specular highlight is a hard-edged white ellipse (`VoiceView.swift:180-182`). It is the one piece of
  2008 "gel button" in an otherwise modern screen, and in the muted state (`13`) it turns the orb into a
  grey ball bearing.
- The rim is a uniform 1 pt white stroke at 14 % (`:183`), so the sphere looks outlined rather than lit.
- The disabled Stop button stays visible at 35 % (`:92`): a dead grey square in the middle of the controls.
- Close is a plain `xmark` with the same weight as mute; nothing says "this ends the session".
- No hint that Space mutes and Esc ends; the controls sit 300 pt below the orb with nothing between.
- Muted state says "MUTED" in the same 70 % white as "LISTENING".

**Change.**

- Highlight: draw it inside a layer with `l.addFilter(.blur(radius: r * 0.10))`, peak opacity 0.32 -> 0.20
  (0.08 when muted), and shrink it to `width: r * 0.75, height: r * 0.36`.
- Rim: stroke with a top-lit gradient,
  `.linearGradient(Gradient(colors: [.white.opacity(0.35), .white.opacity(0.04)]), startPoint: top, endPoint: bottom)`.
- Muted: draw `mic.slash.fill` at `r * 0.38`, `.white.opacity(0.55)`, centered in the orb, and color the
  label `Color(red: 1, green: 0.45, blue: 0.42)` to match the red mic button.
- Controls: Stop only exists while speaking (`.transition(.scale(0.6).combined(with: .opacity))`, animate the
  `HStack` with `.smooth(duration: 0.25)`); End becomes a red-tinted glass button
  (`.glassEffect(.regular.tint(.red.opacity(0.55)).interactive(), in: .circle)`), still `xmark`.
- Add a hint line 14 pt under the controls: `Text("Space to mute  ·  Esc to end")`,
  `.font(.caption)`, `.white.opacity(0.35)`; fade it out after 6 seconds.
- Status label: 12 pt semibold, tracking 2.0 (`:41`), and cross-fade with
  `.contentTransition(.interpolate)`.
- Entering voice mode: scale the orb from 0.85 with the existing 0.35 s opacity transition
  (`RootView.swift:20-21`) so it arrives rather than appears.

## 10. Settings (P3)

**What's wrong** (`11-settings-*.png`). The panes are native and mostly right. Four things:

- Test results are strings prefixed with "✓" and colored by `hasPrefix` (`SettingsViews.swift:76`,
  `RootView.swift:148`): a text glyph, not a symbol, and it shifts baseline.
- "Preview" (`11-settings-Voice.png`) and "Switch Model" (`11-settings-Model.png`) are left-aligned buttons
  occupying a whole form row; every other value in the forms is right-aligned.
- Config (`11-settings-Config.png`) abandons the grouped look: editor directly on the window background at
  12 pt while the Skills editor is 13 pt, and the path is a bare absolute path.
- Pane height changes per tab (Model leaves a third of the window empty).

**Change.**

- Results: `Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")`
  with `.foregroundStyle(ok ? .green : .red)`, `.font(.callout)`; carry a Bool rather than a prefix.
- Preview: put it on the Speed row's trailing edge as a borderless `play.circle` /
  `speaker.wave.2.fill` (while playing) button. Switch Model:
  `.frame(maxWidth: .infinity, alignment: .trailing)` and `.buttonStyle(.borderedProminent)` only when the
  selection differs from Current.
- Config: wrap the editor in the same grouped surface as the forms (fill `Theme.surface`, radius 10, 1 pt
  `Theme.hairline`), 13 pt mono, path abbreviated with `~` and `.truncationMode(.middle)`.
- Tab symbols: `network` -> `point.3.connected.trianglepath.dotted` is too fussy; keep `network`, but
  `cpu` (Model) -> `sparkles` or `brain.filled.head.profile` is closer to what it is, and `doc.text`
  (Config) -> `slider.horizontal.3`.

## 11. Design tokens (P2, enables everything above)

Add to `Theme.swift` and migrate call sites. This is mostly a mechanical pass.

```swift
enum Radius { static let small: CGFloat = 8      // filter fields, inline surfaces, hover rows
              static let card: CGFloat = 12       // code, tables, stat tiles, idea chips, approval card
              static let bubble: CGFloat = 18     // user bubble
              static let composer: CGFloat = 22 } // composer only
```

Current strays: 7 (`Theme.swift:100`), 8 (`ChatViews.swift:368`, `SettingsViews.swift:252`,
`SkillsViews.swift:38`), 10 (`RootView.swift:93`, `Markdown.swift:104`), 12 (`ChatViews.swift:243`,
`Markdown.swift:145`), 14 (`Theme.corner`), several without `style: .continuous`
(`ChatViews.swift:368`, `SettingsViews.swift:252`, `Markdown.swift:84`).

Fills: `.quaternary.opacity(0.45)`, `.quaternary.opacity(0.6)`, `.quaternary.opacity(0.35)`,
`.black.opacity(0.06)`, `Color.primary.opacity(0.07)` all become `Theme.surface`.

Type: system text styles for all chrome; `Theme.prose` / `Theme.code` for reading surfaces; exactly one
display size (28 semibold) for the greeting and onboarding title; no `.rounded`.

---

## Polish list

- **Error empty states detach their button.** `VStack { EmptyState(...); Button("Try Again") }`
  (`ChatViews.swift:168-171`, `SkillsViews.swift:129-132`, `SettingsViews.swift:241-244`,
  `AgentViews.swift:353-357`): `EmptyState` expands to fill, so the button is pushed to the bottom edge of
  the pane instead of sitting under the message. Pass it through `EmptyState`'s existing `action:`
  parameter. This is a layout bug, not just taste.
- **EmptyState** (`Theme.swift:32-41`): symbol 40 pt ultraLight is elegant but thin strokes vanish on
  non-Retina displays; use `.light`. Title `.title3.weight(.semibold)` is right. Add 60 pt of optical lift
  (`.offset(y: -30)`) so it centers in the visible pane rather than under the toolbar-less area.
- **Sidebar symbols** (`AppModel.swift:103-105`): `bubble.left.and.text.bubble.right` is busy at 16 pt, use
  `bubble.left.and.bubble.right`; `clock.badge.checkmark` renders a two-tone badge that none of its
  neighbours have, use `calendar.badge.clock` or plain `clock`; `chart.bar.xaxis` -> `chart.bar`;
  `text.alignleft` reads as a formatting control, use `list.bullet.rectangle`.
- **Pill** (`Theme.swift:50`): uppercase `caption2` semibold with 0.4 tracking at 10 pt is shouty next to
  13 pt titles ("BUNDLED", "UNAVAILABLE" in `04`, `08`). Use sentence case, `.caption2.weight(.medium)`, no
  tracking, padding H 6 / V 2.
- **Tool chips** (`ChatViews.swift:339-342`): swap `ProgressView` -> `checkmark` with
  `.contentTransition(.symbolEffect(.replace))`; fill `Theme.surface`.
- **Approval card** (`ChatViews.swift:363-384`): "Deny" on the far left with `role: .destructive` renders as
  an ordinary button on macOS. Order: `Deny` (left, plain), spacer, `Always Allow`, `Allow for Chat`,
  `Allow Once` (prominent). Title icon `hand.raised.fill` in orange is good; use `.orange` at 10 % fill and
  25 % stroke, radius `Radius.card`.
- **Composer buttons** (`ChatViews.swift:421-436`): three `if/else` branches hard-cut between stop, voice and
  send. Use one `Image(systemName: symbol)` with `.contentTransition(.symbolEffect(.replace.downUp))`, 26 pt.
  The stop glyph inherits `.primary`; give it `Theme.accent` like the other two.
- **Typing indicator** (`ChatViews.swift:393-397`): dots at `.secondary` 7 pt are fine; add a 2 pt vertical
  bob in phase with the opacity so it feels alive rather than blinking.
- **New message entrance**: `.transition(.opacity.combined(with: .offset(y: 8)))` on `EntryView` with the
  existing `.smooth` scroll animation (`ChatViews.swift:198`).
- **Toast** (`RootView.swift:119-125`): 90 pt bottom padding is tuned to the old composer; anchor it 12 pt
  above the composer instead. `.animation` inside the `if` never animates removal; move it to the overlay
  container.
- **Onboarding** (`RootView.swift:142`): `.largeTitle.weight(.semibold)` -> the 28 pt display token;
  `HermesMark(size: 64)`; result label per item 10.
- **Skill header** (`SkillsViews.swift:186-213`): two stacked labelled switches form a ragged right column
  ("Enabled" and "Locked" labels right-align to different x positions in `04`). Use a two-row `Grid` with
  trailing-aligned labels, or move Locked into a `lock` / `lock.open` toolbar toggle.
- **Session row** (`ChatViews.swift:134`): pin in `.orange` is the only orange in the list; use
  `.secondary`. Relative time `.caption` `.tertiary` is right.
- **HermesMark** (`RootView.swift:176`): `paperplane.fill` on a blue-violet squircle is very close to
  Telegram and to Mail's send glyph. Worth a custom mark before launch; flagged for the owner, not a code
  change.
- **Voice overlay hides the window controls** (`RootView.swift:23`): with the toolbar hidden there is no
  visible way to drag or close the window (`12-voice-listening.png`). Keep the traffic lights.

## Dark mode audit (from code, unverified)

| Where | Problem | Fix |
| --- | --- | --- |
| `Theme.swift:11` | Fixed sRGB indigo; as text/icon on `#1E1E1E` it is about 4:1, dull | Adaptive accent, item 1 |
| `Theme.swift:12`, `ChatViews.swift:287` | `accentSoft` 12 % over a dark pane: user bubble nearly invisible | 0.30 in dark, item 4 |
| `ChatViews.swift:368` | Approval command box `.black.opacity(0.06)`: invisible on dark | `Theme.surface` |
| `Markdown.swift:145` | Code block fill = pane color at 60 %: no surface in either mode | `Theme.surface` |
| `Markdown.swift:37-38` | Inline code `primary` 7 % fill is fine; foreground 85 % fine | none |
| `ChatViews.swift:204`, `SkillsViews.swift:151`, `AgentViews.swift:350` | `textBackgroundColor` panes next to default-background list column: in dark these differ (`#1E1E1E` vs window background) and may show a seam | Verify in a dark build; if so use one background for both columns |
| `RootView.swift:174` | `HermesMark` gradient is fixed: fine (brand), but the 35 % accent shadow glows on dark | Drop shadow opacity to 0.2 in dark |
| `VoiceView.swift:17-19, 168` | Fixed dark palette: intentional, overlay forces `.dark` | none |
| `AgentViews.swift:339` | Log `.red` / `.orange` are semantic | none |
| `Theme.swift:101` | Hover wash `primary` 5.5 %: adapts | none |
| `AgentViews.swift:251` | Chart "Input" at accent 55 %: muddy on dark | 35 % of the adaptive accent |

Everything else uses hierarchical styles (`.secondary`, `.tertiary`, `.quaternary`, `.separator`) and
should adapt. Recommend one dark-mode screenshot pass of all 14 screens after items 1 and 4 land.
