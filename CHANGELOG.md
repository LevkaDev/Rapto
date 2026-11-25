# Changelog

Technical changes to Rapto, for developers. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). What changed for users is in
[RELEASE_NOTES.md](RELEASE_NOTES.md) and on [rapto.app/changelog](https://rapto.app/changelog).

This file starts with 5.77. Releases 5.77 and 5.78 came out of the closed repository; 6.0 is
the first open-source release. Earlier releases, 2.0 to 5.76, are described on
[rapto.app/changelog](https://rapto.app/changelog).

## [Unreleased]

### Fixed
- Resize shortcuts (`Shrink / Grow Width / Height`) changed only the size of the focused slot's
  windows, anchored at the top left: neighbours did not follow, a slot could grow over its
  neighbour or past the screen, and the rightmost and bottom slots could not be resized
  toward their neighbours. `WindowResizeService.resizeSlot` now moves the border the slot
  shares with a neighbour (right or bottom first, otherwise left or top;
  `steppedFrame(ofSlot:direction:step:slotFrames:)`) through the same divider code as a drag,
  so gaps, groups and minimum window sizes behave the same. A press that can't move anything
  beeps.

## [6.0] - 2026-11-23

The first open-source release.

### Added
- `Settings → About → Troubleshooting → Report a Problem` opens the repository's bug form or a
  mail to support with the Rapto and macOS versions, displays, desktops and modes filled in
  (`ProblemReport`). The app sends nothing itself.
- `Settings → Guide`: when the default mode for new desktops is Manual or Drag to Snap, the
  step also offers the layout for new desktops (the same `defaultTemplateForNewSpaces` as
  `General → New Space Defaults`).
- `Settings → About` has an Open Source section with buttons that open the repository on
  GitHub, and Settings search finds it.
- The app bundle carries `THIRD_PARTY_NOTICES.md` and `LICENSE`. `Settings → About →
  Acknowledgements` shows them in a sheet (`AcknowledgementsView`, parsed by
  `Acknowledgements.blocks(fromMarkdown:)`).

### Fixed
- Windows of other desktops are no longer taken for newly opened ones. While macOS animates
  between desktops the on-screen window list holds the windows of every desktop;
  `checkForNewWindows` now leaves out the ones `SpaceManager.windowsOnHiddenDesktops` reports,
  so they are not moved into the slots of the current desktop or raised.
- `DoubleClickGuard` removes its click tap when it goes away, and the tap callback holds a
  context that points to the guard weakly. The callback used to hold a plain pointer, so a click
  after an `AppState` made in a test was dropped crashed the test host.
- `AutoTilingModeTests.overlappingSpaceChanges` uses wider time margins; it failed on a busy
  machine.
- A swap in Manual mode puts both windows on their slots' frames, as in Auto Tiling. It used
  the dragged window's frame from the window list, which already showed the window moved when
  the press landed on an inactive app's window, so the other window ended up off its slot.
  The lookup is `AppState.swapSlotFrame(holding:on:)`.

### Changed
- `Settings → Appearance`: the highlight option for Drag to Snap is a switch like the other
  rows ("Hide in Drag to Snap"), not a checkbox. The stored setting is the same.
- The app and the tests build without compiler warnings. Plain data types (`GridTemplate`,
  `Zone`, `PredefinedTemplates`, `HotkeyBinding`, `LayoutOperationMode`) are no longer tied to
  the main actor, method references passed as closures are written out as closures, and the
  completion handlers of the preview and picker fade-outs state that they run on the main
  thread.
- Comments that restated the code, described its history or pointed to internal documents are
  removed; the code itself is unchanged.
- Rapto is open source under the GNU General Public License v3.0 or later.
- The development team is read from `Config/Signing.local.xcconfig` instead of the Xcode
  project; `build.sh` and `release.sh` read signing identifiers and local paths from
  `release.local.env`.
- `build.sh` builds a release only from committed code.
- The project, targets, scheme and folders are named Rapto instead of GridSnap.
- `AppState.swift` is split into `AppState.swift` (state and initializer) and ten
  `AppState+*.swift` extensions; the code is unchanged apart from access levels.

### Removed
- About 2,800 lines of unused code and 46 debug log lines that fired many times per second.

## [5.78] - 2026-11-23

Released from the closed repository, before the first open-source release. The code is the
same as here.

### Added
- Inline guidance in the Custom Layout editor (`OverlayView`, `ZoneCreatorView`): status pill
  next to `Save Layout` explaining missing zones or layout name (focusing and highlighting the
  name field on click), a first-zone `+` prompt inside the draft frame, a `1 → 2 → 3` fill-order
  note in the bottom bar, and a `Use Open Windows` button to populate zones from the current
  display's open windows.
- `OneTimeHints` (`manualNeedsLayout`, `snapBack`, `groupBadge`, `focusMode`) shown immediately
  up to ten times per Mac (`shownHintCounts`), click-to-dismiss and custom placements on
  `SpaceBarHint`, immediate group-indicator refresh after slot drops, plus a live Desktops Bar
  drag hint ("Move to Desktop N · Hold ⌥ …") that updates on `⌥` press/release and retires
  modifier prompts after ten uses.
- Live `hasAccessibilityPermission` monitoring (app activation, menu/Settings/overlay checks
  and a 3 s recovery poll while off) with warnings in Settings, the Desktops Bar and the menu
  bar icon, plus a `SpaceBarHint` notice when pressing the overlay shortcut on an Auto-tiling
  desktop (`AppState.overlayToggleDecision`).
- `DragHint`, `HintKeyStore` and `HintLabel`: slot and snap-zone highlights in Manual,
  Auto-tiling and Drag to Snap now state what dropping a window will do ("Move here", "Swap",
  "Snap here", "Groups with …") and which modifier flips the action (plus a first-time caption
  above `DragSnapLayoutPicker`), hiding modifier prompts once used ten times.
- Per-app `<App Name>` submenu (`Always Ignore` and `Pause Shortcuts`) when right-clicking an
  app icon in the Desktops Bar (`SpaceBarMenu`, `SpaceBarGlyphFramesKey`) and in the menu bar
  icon's Quick Actions (`RaptoApp`), with immediate slot eviction and hotkey pause updates
  (`AppState+Apps`).
- `Guide` as the first tab in Settings (`GuideSettingsView`, opened from the final step of
  onboarding via "Open Setup Guide"), with one-click starter profiles, a four-step setup
  checklist, `AppSuggestionScanner` for installed terminals/VMs and optional untiled apps,
  live gesture & shortcut cards (`GuideGestureCopy`), and the `showsHints` setting.
- `SettingsSearch` and a `⌘F` search box in the Settings sidebar, matching setting titles,
  sections and common synonyms.
- `Behavior` tab in Settings (`BehaviorSettingsView`), with a single three-option `DragModifierMode`
  selector over `swapRequiresOption` / `moveRequiresShift` and zone miniatures in Auto-tiling rows.
- Live miniature preview of window gaps, screen-edge gaps and the active-window border in
  `AppearanceSettingsView`.

### Changed
- Pressing or releasing `⌃` or `⇧` while holding a window in `WindowSwapService` now switches
  the pending swap/move action, highlight color and hint immediately without moving the mouse.
- Settings tabs are split into `Views/Settings/`: `Focus Mode` and `Floating Windows` move from
  `Appearance` to `Behavior`, `Window Gaps` move from `General` to `Appearance`, and
  `Passthrough Apps` move from `Shortcuts` to `Apps` alongside an explanation of `WindowClassifier`.
- Manual mode is named "Manual" instead of "Manual (Hotkey)" in menus and pickers, and onboarding
  describes all three modes accurately and notes the Desktops Bar when the menu bar icon is hidden.
- Default `windowGap` and `screenEdgeGap` in `AppState` are 4 px instead of 0 px; an explicit 0 px
  saved in `UserDefaults` is preserved on launch (`AppState.loadedGap`). An install that finished
  onboarding before this default existed keeps 0 px (`AppState.settleUnsavedGap`).

## [5.77] - 2026-11-22

Released from the closed repository, before the first open-source release. The code is the
same as here.

### Added
- `AppResponsiveness`: an app whose Accessibility request waits out the whole 1 s messaging
  timeout is skipped until it answers a probe sent once a second from a background thread.
  After two missed probes the user is told once, and the group indicator and the Desktops Bar
  dim the app's icon.

### Changed
- Hints under the Desktops Bar are drawn in the bar's own look (Dark, Glass or Plain, light or
  dark with the menu bar) and are a little larger.

### Fixed
- `HotkeyManager.resumeHotkeys()` registered the group cycling hotkey again without its
  dispatch entry, so after the first suspend the key was taken from every app and did nothing.
- `applyHotkeyPreset` releases the overlay, float, group cycling, swap, move and move-to-display
  hotkeys when the preset no longer binds them; before, a cleared shortcut stayed registered
  until the next launch, and Control+Tab came back at every launch.
- Swap and move-to-slot hotkeys are registered per direction (`HotkeyPreset.directionBindings`);
  clearing one direction no longer drops all four.
- The presets no longer bind `applyTemplate1`…`9`, which nothing registers and no Settings row
  shows; the bindings only blocked those shortcuts in the conflict check.
- Deleting a custom layout removes its hotkey, and hotkeys of layouts that no longer exist are
  dropped at launch.
- `LayoutState.findSlotIndex(forPID:windowOrigin:)` picks the nearest slot, so the swap, move and
  resize hotkeys find the right slot when two windows of one app sit side by side.
- The resize hotkeys start from the slot frame and write the new frame back, so repeated
  presses add up and the size is saved with the layout.
- A hung app froze Rapto on its desktop: every Accessibility request to it waited 1 s on the
  main thread (two or three per click on the group indicator, six per switch to a Manual
  desktop). Requests to an app that is not answering are no longer sent.
- When an app answers again, its windows are put into their slots if the layout changed
  while it did not answer (a swap, new gaps, a resized slot): `returnWindowsToSlots(ofApp:)`.
- A swap with a window of an app that is not answering moved the dragged window and left
  the layout unchanged. It now counts as a swap; the other window follows when its app
  answers.
- A cached window element is kept when the app does not answer instead of being dropped as
  stale.
- A window moved from the Desktops Bar to a Manual desktop it has no remembered slot on kept
  the slot the layout restore gave it by frame overlap, sharing it with the window already
  there while another slot was empty. It now takes the first empty slot
  (`AppState.emptySlotInsteadOfShared`).
- A slot remembered for an app from an earlier run of Rapto put the window back among other
  windows while another slot was empty. Such a stored slot is now taken only while it is
  free; a window that left its slot in this session still returns to it
  (`AppState.slotForRememberedWindow`).
- The slot a window leaves was not remembered when the move started from another desktop:
  the window was grabbed before the layout of its desktop was back in place. The slot is now
  also looked up in the layout saved for that desktop (`AppState.savedSlotIndex`).
- `checkForWindowsNeedingIntegration` runs 0.5 s after a window moved and could fire between
  a desktop switch and its handling: every window of the new desktop was then put into the
  layout of the desktop just left, and that layout was saved for the new one. It now stands
  down during a Desktops Bar move and while a desktop change is unhandled, like
  `checkForNewWindows` does.
- A slot's saved frame drifted after desktop moves: `updateSlotFramesFromWindows` took the
  frame of the window the Desktops Bar was holding, which the real mouse still drags while the
  desktop switches. That window is skipped (`SpaceBarController.movingWindowID`).
- Simplenote could not be moved to another desktop: its title bar answers `AXSplitGroup`,
  which was no spot to grab. Any spot that is not a control is now a guess to probe.
- A window that starts following the mouse late (Hark) was sometimes left behind by a desktop
  move: the desktop switched before the drag had begun. After the press the move now drags
  the window a few points and waits, up to 0.45 s, until it has moved.
- Moving a window to another desktop from the Desktops Bar failed for apps whose title bar
  answers `AXWebArea` everywhere (Antigravity): the one guessed grab spot did not drag the
  window. Guessed spots, now also `AXGroup` hits, are probed one by one (press, drag 5 pt, then
  7 pt, check that the window moved from where it was just before the press). A spot that
  does not drag is released outside the window, and a window shifted by that is put back.
- While the Desktops Bar moves a window with synthetic mouse events, the drag watchers
  (`WindowSwapService`, `DragSnapService`, `SnapBackService`, `WindowResizeService`) and
  `checkForNewWindows` stand down (`SpaceBarController.isDrivingMouse`). A release during a
  move scheduled a new-window check that ran mid-switch and filed the incoming desktop's
  windows into the layout of the desktop being left.
