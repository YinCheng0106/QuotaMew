# Changelog

All notable changes to QuotaMew will be documented in this file.

QuotaMew was previously known as QuotaPulse. Historical release entries retain the product name used at release time.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0-rc.1] - 2026-09-12

QuotaMew v0.2.0 feature development is complete. This first release candidate carries the Beta 3 product experience into final release validation and stability work.

### Changed

- Freeze the v0.2.0 feature scope for release-candidate stabilization.
- Carry forward the native menu bar experience, Codex quota presentation, onboarding, Settings, notifications, accessibility/localization improvements, and recovery lifecycle improvements from Beta 3.
- Complete deterministic XCTest, live Codex, and live system notification validation for the candidate baseline.

### Distribution

- The RC.1 DMG is Apple Development signed and is not Developer ID signed or notarized.
- macOS may require **System Settings → Privacy & Security → Open Anyway** on first launch.
- Claude Code remains **Experimental / Unverified**; Reset Intelligence remains deferred to v0.3.

## [0.2.0-beta.3] - 2026-09-08

### Added

- Added a native first-run onboarding experience covering provider status, privacy boundaries, quota presentation, provider pinning, Launch at Login, and optional notifications.
- Added configurable menu bar quota display modes: Single and Overview, with 5-hour, Weekly, and conservative Luna Reserve presentation.
- Added a native status-item context menu for Refresh Now, Settings…, and Quit QuotaMew.

### Changed

- Share duration-based 5-hour / Weekly window names across Dashboard, VoiceOver, and reset notifications, with a safe generic fallback.
- Present Luna Reserve as secondary fallback information, expanding it only for fresh regular-quota exhaustion; keep regular quota as the menu-bar metric and suppress Reserve reset notifications.
- Improve Remaining / Used presentation, provider pinning, accessibility semantics, intrinsic-width handling, and lifecycle/recovery behavior.
- Update English and Traditional Chinese product and release documentation for the Beta 3 scope.

### Distribution

- Beta 3 is distributed as a QuotaMew DMG.
- Developer ID signing and Apple notarization are not yet available.
- Reset Intelligence remains deferred to v0.3; Claude Code remains Experimental / Unverified.

## [0.2.0-beta.2] - 2026-09-06

### Changed

- Renamed the product from QuotaPulse to **QuotaMew**.
- Renamed the Xcode project, application and test targets, schemes, Swift modules, and related source directories to the QuotaMew product name.
- Updated current user-facing application text, documentation, repository references, and public branding for QuotaMew.
- Updated the official documentation website to `https://quotamew.yincheng.app`.
- Updated the main project repository to `YinCheng0106/QuotaMew` and the documentation repository to `YinCheng0106/quotamew-docs`.
- Preserved existing compatibility-sensitive application identifiers so upgrades from QuotaPulse Beta 1 continue to use the same macOS application identity.

### Compatibility

- Production and development bundle identifiers continue to use the existing `dev.quotapulse.*` namespace.
- Existing persistence, notification, Launch at Login, diagnostics, and legacy provider identifiers that depend on the previous application identity remain unchanged where required for compatibility.
- Historical `v0.2.0-beta.1` release information and artifacts retain the original QuotaPulse name.

### Distribution

- The downloadable application and future release artifacts now use the **QuotaMew** product name.
- Developer ID signing and Apple notarization are not yet available.
- Automatic updates are not yet available.

## [0.2.0-beta.1] - 2026-09-05

### Added

- Configurable Remaining / Used quota presentation.
- Updated onboarding and presentation contracts.
- Privacy-safe compatibility diagnostics.
- Local provider-independent quota reset detection.

### Changed

- Migrated the menu bar status-item shell to a hybrid AppKit + SwiftUI architecture.
- Reorganized Settings by category.
- Improved menu bar recovery behavior.
- Defined the initial Reset Intelligence feed contracts and governance model.

### Distribution

- First publicly downloadable QuotaPulse beta distributed as a DMG.
- Developer ID signing and Apple notarization are not yet available.
- Automatic updates are not yet available.

## [0.1.1] - 2026-08-31

### Fixed

- Improved recovery when QuotaPulse has been hidden from the macOS menu bar.
- Fixed provider enable/disable lifecycle races that could affect pending reset notifications.
- Fixed stale provider refresh results being applied after provider eligibility changes.
- Fixed notification lifecycle handling across application restarts.
- Fixed a refresh scheduling edge case when notification evaluation overlaps a refresh deadline.

### Changed

- Disabled providers are omitted from the Dashboard and background provider work.
- Improved development/runtime identity isolation.

## [0.1.0] - 2026-08-28

### Added

- Native macOS menu bar app built with Swift and SwiftUI.
- Codex usage monitoring through the ChatGPT.app-integrated runtime, with compatible legacy and standalone discovery fallbacks.
- Usage percentages, reset times, and minute-level reset countdowns.
- Local reset-reminder notifications.
- Native Settings for Launch at Login, provider enablement, and notification thresholds.
- English and Traditional Chinese localization.
- Experimental / Unverified Claude Code snapshot-reader support; the opt-in bridge and subscribed-account validation are not complete.

### Security

- Provider credentials, prompts, transcripts, raw provider responses, and coding history are outside QuotaPulse's data model and logging boundary.

### License

- Released under the MIT License.

### Known limitations

- Requires macOS 14 or later; Apple silicon is validated and Intel is not yet validated.
- Developer ID signing, notarization, and the production App Icon are deferred.
- Claude Code remains Experimental / Unverified.
- Usage history, cloud sync, iPhone support, and Reset Intelligence are not included.
