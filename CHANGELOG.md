# Changelog

Technical changes to Rapto, for developers. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). What changed for users is in
[RELEASE_NOTES.md](RELEASE_NOTES.md) and on [rapto.app/changelog](https://rapto.app/changelog).

This file starts with 5.77. Releases 5.77 and 5.78 came out of the closed repository; 6.0 is
the first open-source release. Earlier releases, 2.0 to 5.76, are described on
[rapto.app/changelog](https://rapto.app/changelog).

## [Unreleased]

### Fixed
- Changing `windowGap` or `screenEdgeGap` now updates visible snapped windows in Drag to Snap
  right away (`DragSnapService.reapplyGaps`, recording each snapped window's `relativeFrame` until
  manually resized) and reapplies gaps across every connected display instead of only the active
  screen's mode (`AppState.reapplyLayoutWithNewGaps`).
- Removed the duplicate `2+1+2` built-in layout (`PredefinedTemplates.twoOneTow`), which had
  identical zones and fill order to `Center + Split Sides`. Saved preferences, screen/space
  configurations, saved layouts, workspaces, layout shortcuts, and AppleScript calls targeting its
  retired UUID (`00000001-0000-0000-0000-00000000000E`) now resolve automatically to
  `Center + Split Sides` via `PredefinedTemplates.canonicalID(for:)`.
- Switching back to an Auto-tiling desktop while an App-Napped Mac Catalyst app (such as Apple Maps)
  was waking up could cause Auto-tiling to drop that window as temporarily unresponsive, collapse
  the grid from 3 slots to 2, and treat the window as new once it answered — swapping it into the
  largest slot. `AutoTilingService`, `AppState+Modes`, and `AppState+Spaces` now preserve visible
  windows that match the current or saved layout while their app is temporarily unresponsive, and
  `AppState.returnWindowsToSlots(ofApp:)` also returns Auto-tiling windows if they drifted off
  their slot before waking.
- Moving a cold App-Napped Mac Catalyst window (such as WhatsApp) from another desktop via the
  Desktops Bar could still fail on the first attempt because `SettingsWindowDetector` and
  `WindowUsageTracker` synchronously ran 1 s Accessibility calls on `didActivateApplicationNotification`
  while the app was mid-wake, starving the raise deadline. `SettingsWindowDetector`,
  `WindowUsageTracker`, `AutoTilingService`, `FloatingWindowService`, and unassigned-window restore
  now stand down while `SpaceBarController.isDrivingMouse` is active, and `SpaceBarController`
  coordinates waking apps off the main thread (`DesktopMoveGrabPlanner.classifyQuickAXProbe`,
  3 s wake budget with periodic WindowServer nudges, 0 ms extra delay for awake apps).
- Moving a window to a Manual desktop where every slot is occupied no longer lets a stale slot
  memory entry from an earlier session yank the window out of the slot whose size and position it
  already matches (`AppState.slotForRememberedWindow` now preserves `current` when the old stored
  slot is occupied and no empty slot is available; same-session returns still take their prior slot).
- Moving an App-Napped background window (such as WhatsApp) from another desktop via the Desktops
  Bar could abort with a beep after hitting the 1 s Accessibility timeout before the app woke up.
  `SpaceBarController` now pings the target process off the main thread during the desktop switch,
  marks the move active before waking/raising the window via `NSRunningApplication.activate()` +
  WindowServer, uses a short `0.15 s` per-element Accessibility timeout (avoiding false
  `AppResponsiveness` bans), and falls back immediately to Core Graphics frame bounds and
  frame-relative grab memory if Accessibility is still waking up. `WindowHighlightService` also
  stands down while `SpaceBarController.isDrivingMouse` is active so `WindowClassifier` never
  stalls the main thread for 1 s on a waking app mid-move.
- Restoring a Manual layout (such as switching back from Auto-tiling to Manual) could stack an
  unassigned window into an occupied slot by frame overlap while leaving another slot empty.
  `AppState.processUnassignedWindowsAfterRestore` now excludes all windows already restored into
  any slot group (not only each slot's front window), skips floating/non-tilable windows, and
  uses a two-pass `unassignedRestoreSlots(containingSlots:initialWindowCounts:)` pass so windows
  already over an empty slot keep it and remaining unassigned windows fill empty slots before
  joining occupied ones.

### Changed
- **Magnetic snapping, one-click split, and clean draft completion in the custom layout editor** (`ZoneCreatorView`,
  `ZoneEditorGeometry`, `OverlayView`, `AppState+Layouts`): moving or resizing a zone now snaps
  within `12 pt` to screen edges, neighboring zone edges/centers, and `1/4`, `1/3`, `1/2`, `2/3`,
  `3/4` guides with visual guide lines (bypassed while holding Option), and adds one-click vertical
  and horizontal split buttons centered with the zone controls with a hover cut-line preview.
  Confirming a draft zone now places it and closes the draft cleanly (use `+ Add Zone` or click an
  empty area to add another zone, or `×` to dismiss an unwanted draft).
- **Simultaneous parallel window swaps** (`WindowSwapService`, `AppState+Hotkeys`): mouse
  drag-drop swaps and keyboard slot swaps now move both windows concurrently via
  `AccessibilityService.batchSetWindowFrames` with a calm highlight border fade-in instead of
  repositioning one window after the other.
- **Calmer, single-beat window transitions without focus theft** (`AccessibilityService`,
  `WindowHighlightService`, `AppState+Modes`, `AutoTilingService`, `AppState+Layouts`):
  - Switching from Auto-tiling to Manual now inherits the live Auto-tiling grid in place (zero
    window moves) and discards stale Manual snapshots instead of yanking windows back to an older
    Manual layout; returning from None or Drag-to-Snap still restores the kept Manual snapshot.
  - Added `AccessibilityService.batchSetWindowFrames(_:onWillMove:)`, which skips windows already
    within `1.5 pt` of their target frame, dispatches distinct app PIDs concurrently while keeping
    same-app order, and shares a single `20 ms` verification/retry cycle instead of serial domino
    repositioning across `AutoTilingService`, `putWindowsBack`, `applyManualModeTemplate`, and
    `restoreLayoutToOriginal`.
  - Replaced activating `raiseWindow(_:)` loops during batch restores and redistributions with
    silent `AXRaiseAction` (`raiseWindow(axWindow:)`) on grouped slots (`2+` windows) only,
    preventing menu-bar flashing and background apps from stealing keyboard focus.
  - Added `WindowHighlightService.beginLayoutTransition()` / `endLayoutTransition()` so the active
    window highlight and group indicators step aside during multi-window moves and fade smoothly
    back in (`0.14 s`, or `0.08 s` under Reduce Motion) once frames settle.
- **More reliable and faster desktop window move grabbing** (`DesktopMoveGrabPlanner`,
  `DesktopMoveGrabMemory`, `SpaceBarController`):
  - Computes widest empty horizontal gaps between top-strip Accessibility controls (and checks
    `AXTitleUIElement`) instead of relying only on fixed pixel offsets.
  - Scans up to three title-bar rows (primary, top hairline strip, lower toolbar) with
    width-adaptive X coverage and supports windows without standard traffic-light buttons.
  - Rejects any element whose Accessibility ancestor chain or subrole belongs to an interactive
    control (`AXGroup < AXButton`, `AXTabButton`, etc.) and prioritizes native chrome before web
    and container fallbacks.
  - Escalates drags from `5 pt` to `14 pt` inward without releasing the mouse button (handling
    Catalyst/Electron drag thresholds), verifies movement via both Core Graphics and Accessibility,
    recovers late followers on release, builds fallback candidates lazily instead of eagerly, and
    replaces the synchronous 250 ms main-thread sleep with an async retry.
  - Caches proven per-app relative grab anchors in session memory (invalidating automatically if
    a cached spot stops dragging or a move fails).
  - Filters system overlay layers (`layer < 0` or `layer >= 20`, including Dock's full-screen
    layer-20 container on macOS 26 and Window Server) out of `windowsFrontToBack` so system
    overlays no longer cause `windowIsOnTop` to reject every title-bar spot.

## [6.2] - 2026-11-26

### Added
- **Redesigned Window Flow–styled onboarding and two-part interactive tour**
  (`WindowFlowOnboardingStyle`, `OnboardingView`, `OnboardingStepViews`, `InteractiveTourView`,
  `InteractiveTourController`, `TourSandboxWindows`): shortened first-launch setup (Accessibility
  only up front, auto-tune display summary, equal mode cards without a Recommended bias,
  `Arrange Now` with one-click `Put Back` Undo, and `Launch at Login`) followed by a floating
  mouse-first tour covering the chosen mode (Part 1) and the Desktops Bar + Window Flow (Part 2,
  with dynamic second-desktop creation and temporary sandbox windows when the screen has fewer
  than two windows).
- **Window Flow button on the Desktops Bar and quick menus** (`SpaceBarView`,
  `SpaceBarController`, `WindowFlowController.toggle(onDisplayID:)`, `RaptoApp`, `SpaceBarMenu`):
  circular Flow button on the left of each display's bar matching the `+` button on the right,
  opening Window Flow on the clicked display, plus `Open Window Flow` entries in both menus.
- **Pause Rapto / Resume Rapto** (`AppState.isPaused`, `handlePauseStateChanged`,
  `MenuBarIconPaused`): temporarily suspends tiling services, watchers and global shortcuts
  without changing saved desktop modes or layouts.
- **Display profile auto-tuning** (`DisplayProfile`, `AutoTilingPreferencesStorage.settleUnsaved`,
  `PredefinedTemplates.standard` / `.ultrawide`): tunes single-window Auto-tiling layout
  (`Full` vs `Center Focus`), `maxWindows` (2–5, with per-screen overrides for multi-display
  laptops), starter Manual layout, and tucks ultrawide layouts into an `Ultrawide` submenu on
  non-ultrawide screens while keeping existing users' saved preferences unchanged.
- **Progressive discovery and notch hints** (`OneTimeHints`, `ProgressiveDiscoveryPolicy`,
  `SpaceBarHint`): upward-pointing notch hint for the hidden Desktops Bar on notched MacBooks
  (retires immediately on reveal), Auto-tiling snap-back tip, and 2-display capped progressive
  tips for multi-desktop switching, Window Flow at 4+ windows, and Workspaces after 48 hours.

### Changed
- New installations default `showsMenuBarIcon` to `true` via
  `AppState.settleUnsavedMenuBarIcon(in:)` with a redesigned monochrome grid icon (`MenuBarIcon`),
  while existing installs keep their prior setting.
- Clarified Manual mode copy across onboarding, `TilingMode`, and `Settings → Guide` to describe
  fixed slots, automatic grouping, and group-indicator switching; hid the terminal/VM scanner
  notice in Guide when none are installed.
- Aligned `SpaceBarHint` HUD glass and accent palette with Window Flow.

### Fixed
- Fresh installations (and newly unconfigured desktops) failed to start Drag to Snap, Manual, or
  Auto-tiling when selected in onboarding or `Settings → Guide → Starter Profiles`: writing
  `defaultModeForNewSpaces` first caused `AppState.mode(for:)` to report the new mode via
  `ScreenConfiguration.userDefault`, so `setMode` was skipped and no service started until the
  user manually toggled modes. `AppState.ensureModeActive(_:on:)` (`needsModeActivation`) now
  checks both explicit desktop configuration and live service state and activates screens before
  updating `defaultModeForNewSpaces`.
- Moving a window to another desktop failed for Yab: the middle of its top strip answers as a
  plain group of the window, was taken as a confirmed drag area, and the desktop switched without
  the window. A confirmed spot that does not move the window within the wait is now let go and up
  to five other spots are probed (`SpaceBarController.tryFallbacks`, `fallbackSpots`,
  `fallbackOrder(after:candidates:limit:)`); if none drags, the move goes on from the confirmed
  spot as before. The spots are also looked for only once the window is in front: before, they
  were answered by the window still covering it.
- An app whose windows come from a process without a bundle identifier (MetaTrader 5 and other
  apps run through Wine: the windows belong to a `wine` helper inside the app bundle) could not
  be ignored: `Ignored Apps` matches by bundle identifier, the helper has none, and the app was
  missing from `Add Running App`. Such a process now counts as the app whose bundle its
  executable lies in (`AppBundleLookup`), for the window list, Drag to Snap, the Desktops Bar
  and the Settings list. Limits: a Wine outside every app bundle still has no identifier, and
  the programs of one launcher (CrossOver) count as that launcher. The Ignored Apps text in
  Settings says so.
- A window dropped on another window (a move, not a swap) was given the target window's own
  frame. When that window did not sit in its slot (an app that refuses the slot's size), the
  dragged window left the layout with it. `WindowSwapService.performMove` now uses the target's
  slot (`moveTargetFrame`), as the swap already does, and skips the move when the target is in
  no slot, so snap-back returns the dragged window.
- Moving a window to another desktop failed for apps that draw their title bar as a page and
  have controls right after the window buttons (Orca): the spot next to the buttons answers as
  a group inside web content, was taken as a confirmed drag area and pressed without checking,
  and the window stayed behind. `SpaceBarController.grabPlan` now treats a spot that counts as a
  drag area only because web content was let through as a guess and probes it, followed by the
  guessed spots along the title bar (`probeOrder(first:then:)`).

## [6.1] - 2026-11-25

### Added
- **Window Flow** (`WindowFlowController`, `WindowFlowBackdropArt`, `WindowUsageTracker`): visual
  3D window strip across all desktops of the active display, bound to `⌃⌥S` in the Rapto preset
  (`⌥S` in Vim Style) and customizable in `Settings → Shortcuts → Window Focus`
  (`HotkeyAction.openWindowFlow`). Includes 4 persistent backdrop themes (`Sky · Azure`,
  `Sky · Dusk`, `Sky · Night`, `Glass` cycled via `B`), frecency window ordering (current window
  at slot 0, previous genuine window at slot 1, 2.5-hour half-life decay with noise filtering and
  capped active dwell at slots 2+), bounded thumbnail cache, seamless cross-desktop handoff using
  per-space `SLSCopyWindowsWithOptionsAndTags` z-order, and an app-icon overlay fallback with a
  Settings shortcut banner when Screen Recording permission is off. Cached previews are kept at
  side-card size. Keys are read through a session event tap while browsing; under Secure Input the
  panel takes the keyboard as a key window instead. A user whose own shortcut already uses the
  Window Flow default keeps it, and Window Flow stays unbound
  (`HotkeyPresetStorage.customBindings`).

### Fixed
- Resize shortcuts (`Shrink / Grow Width / Height`) changed only the size of the focused slot's
  windows, anchored at the top left: neighbours did not follow, a slot could grow over its
  neighbour or past the screen, and the rightmost and bottom slots could not be resized
  toward their neighbours. `WindowResizeService.resizeSlot` now moves the border the slot
  shares with a neighbour (right or bottom first, otherwise left or top;
  `steppedFrame(ofSlot:direction:step:slotFrames:)`) through the same divider code as a drag,
  so gaps, groups and minimum window sizes behave the same. A press that can't move anything
  beeps.

### Security
- Sparkle 2.8.1 → 2.10.1 (`Package.resolved`; the project now asks for 2.10.1 or later).
  Versions up to 2.9.1 have two medium-severity advisories, GHSA-hg88-v3cw-3qrh (symlinks in
  delta updates) and GHSA-g3hp-f6mg-559v (unvalidated connection to the installer); both
  are fixed in 2.9.2.

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
