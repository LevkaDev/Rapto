# Contributing to Rapto

Thank you for helping. Rapto is used every day by people who rely on their windows staying
where they put them, so the most valuable contributions are precise bug reports and small,
focused fixes.

## Reporting a bug

Open an issue and include:

- Rapto version (Settings → About) and macOS version.
- Your setup: number of displays, number of desktops, the mode in use (Manual, Auto Tiling,
  Drag to Snap or None).
- Steps to reproduce, what you expected and what happened. A short screen recording helps.
- The app involved, if the problem is with one app's windows.
- A log, if you can: turn on file logging in Settings, reproduce the problem and attach
  `~/Library/Logs/Rapto/debug.log`. The log can contain app names and window titles, so
  look through it before sharing.

Security problems should not go in public issues; see [SECURITY.md](SECURITY.md).

## Suggesting a feature

Open an issue and describe the problem you are trying to solve before proposing a
solution. Rapto aims to stay small and predictable, so not every idea will be accepted.

## Pull requests

- For anything larger than a small fix, open an issue first so we can agree on the
  approach before you spend time on it.
- Keep each pull request to one change. Do not mix refactoring with behaviour changes.
- Build instructions are in the [README](README.md#building-from-source). Make sure the
  project builds without new warnings and the `RaptoTests` target passes.
- Before your first commit, run `git config core.hooksPath .githooks`. The hooks run
  `scripts/check-repo.sh`, which keeps build output, local configuration and personal data
  out of the repository; CI runs the same check and builds the project.
- A new file or folder at the top level of the repository needs the maintainer's agreement
  (the check lists the allowed ones). Do not add notes, plans or other documents.
- Test by hand in the modes your change touches, with more than one desktop and, if you
  can, more than one display. Say in the pull request what you tested.

## Commits

- One logical change per commit. The project builds and the tests pass at every commit.
- Subject: English, imperative mood, at most 72 characters, no trailing period, no
  version numbers or prefixes: `Fix window groups losing their order after sleep`.
- Body, when the subject is not enough: what was wrong or missing, why this is the fix,
  anything a reviewer should know. Wrap at 72 characters.
- Versions appear only in release commits (`Release 5.78`) and tags (`v5.78`).
- The commit-msg hook and CI check the subject: length, no trailing period, no `fix:`-style
  prefix, no version number.

## Release notes

`RELEASE_NOTES.md` is shown to users in What's New and in the update window. A change that
users will notice gets a line in the top block:

- Plain English for people who use the app, not for developers. Say what the user sees
  now, in one or two lines.
- No causes and no explanation of how it was fixed. No file, class, function or API names,
  and no technical words (CPU, memory, process, events, cache, pixels).
- Sections `### New`, `### Improvements` and fixes grouped by area: `### Fixes: Multiple
  displays`, `### Fixes: Auto Tiling`, `### Fixes: Manual and groups`, `### Fixes: Layouts
  and overlay`, `### Fixes: Desktops and workspaces`, `### Fixes: Shortcuts and Settings`,
  `### Fixes: Other`. Only the sections that have items.
- Keep the block format: `## Version X.Y`, sections, and a closing `---` line. The release
  script reads the first block; it sets the version number itself.

| Instead of | Write |
|------------|-------|
| Onboarding window level changed from .floating to .normal | The first launch is smoother |
| Fixed a crash caused by a force unwrap after the cache was cleared | Rapto no longer quits unexpectedly after snapping many windows |

## Changelog

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and is for
developers. Add one line per change under `## [Unreleased]`, in `### Added`, `### Changed`,
`### Fixed` or `### Removed`: what changed, technically and briefly. The full story belongs
in the commit body and the pull request.

## Code style

- Swift, following the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Code, comments, logs and commit messages are in English.
- Comment the why, not the what: constraints, invariants and macOS quirks the code cannot
  show. Do not leave commented-out code or notes about how the code used to work.
- A workaround for system behaviour gets a marker and an explanation:

  ```swift
  // MARK: - Workaround: short name
  // Cause: what macOS does.
  // Context: what Rapto does about it.
  ```

- Log with `debugLog("Category", "message")`, not `print`. Do not log inside code that
  runs many times per second.
- Do not rename or change the meaning of stored settings keys, file names or bundle IDs:
  existing users' settings depend on them. The same goes for the AppleScript commands and
  their JSON fields in `Scripting.swift`, which the Raycast extension uses.

## License of contributions

Rapto is licensed under the [GNU General Public License](LICENSE), version 3 or, at your
option, any later version (`GPL-3.0-or-later`). By submitting a contribution you agree
that it is licensed under the same terms.
