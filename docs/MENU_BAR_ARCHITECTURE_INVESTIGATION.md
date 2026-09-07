# Menu Bar Architecture Investigation

Date: 2026-09-01 — final acceptance update 2026-09-02
Historical scope: MenuBar architecture only; Milestone C and unrelated v0.2 work were stopped during this investigation. Current v0.2 scope and the subsequent right-click menu are documented in [V0_2_PLAN.md](V0_2_PLAN.md) and [ARCHITECTURE.md](../ARCHITECTURE.md).

This investigation was completed before the public product rename. `QuotaPulse` references in measured evidence below intentionally retain the name used by the tested build; current product documentation uses QuotaMew.

## Decision

Adopt and implement **a hybrid architecture**: keep the existing SwiftUI dashboard, settings, cards, `AppModel`, and `SettingsModel`, but replace only the `MenuBarExtra` shell with one app-owned `NSStatusItem` and a SwiftUI-hosted transient popover.

Implementation update, 2026-09-02: production now has exactly one `StatusItemController`, one `NSStatusItem`, and one SwiftUI-hosted transient popover. App-hosted XCTest skips controller creation entirely and parallel execution is restored. Final acceptance is complete: automated controller/test-host gates and the documented manual lifecycle, layout, accessibility, recovery, and clean-user Release checks passed. Physical visibility remains a system-observation boundary rather than an app API claim.

The hybrid is recommended because `NSStatusItem.isVisible`, KVO, `autosaveName`, and explicit creation/removal give QuotaPulse a more deterministic shell and make it possible for XCTest hosts to create no item at all. It does **not** grant private Control Center access, prove on-screen visibility, change the owning bundle identifier, or sever an existing application-level Control Center association.

Confidence: **high for controller ownership, explicit show/hide logic, recovery policy, test isolation, and the clean-user Release result; medium for any macOS system-managed visibility behavior because no public API exposes the complete Control Center state**.

## Implemented architecture

```text
QuotaPulseApp / AppDelegate
        |
        v
StatusItemController (one NSStatusItem, stable per-bundle autosaveName)
        |
        v
NSPopover(.transient) + NSHostingController
        |
        v
Existing DashboardView + shared AppModel / SettingsModel
```

The controller is the sole status-item and observation owner. Persisted intent drives explicit hide/show; KVO projects `NSStatusItem.isVisible` into logical runtime state without corrupting intent; presentation changes update only the standard status button label and accessibility metadata. Recovery can force-show the same retained item. Teardown invalidates the observer, clears target/action, closes the popover, and removes the item exactly once. No second refresh, notification, provider, network, timer, polling, or scheduler path was introduced.

## Current state chain

```text
SettingsStore.isMenuBarItemRequested
Persisted QuotaPulse preference (user intent)
                 |
                 v
NSStatusItem.isVisible -> SettingsModel.isMenuBarItemVisible
Current-process public logical visibility
                 |
                 v
Control Center status-item host
A registered system host owned by the QuotaPulse process
                 |
                 v
macOS allowance + layout + available width + active display
Actual on-screen visibility, which the app cannot authoritatively observe
```

The four layers are related but are not equivalent. In particular, `NSStatusItem.isVisible == true` is not proof that pixels are visible, and a system-driven false KVO change must not silently rewrite the persisted QuotaPulse preference.

## Pre-migration show/hide failure and minimal fix

The ordinary Settings OFF -> ON path worked in one process: Control Center changed `clientRequestsVisibility` false -> true, removed and recreated the displayable, and the PID remained alive.

The failing path was:

1. Settings OFF removed the item and left the process alive.
2. The Settings window was closed.
3. Reopening the app presented the recovery window.
4. The recovery action set persisted intent to true and immediately closed its AppKit-hosted SwiftUI window in the same action.
5. The runtime insertion state fell back to false before `MenuBarExtra` processed the request. Control Center received no true transition.
6. Settings consequently showed requested ON but runtime not inserted. A later OFF -> ON cycle from Settings recovered it.

The minimal fix removes the immediate `dismiss()` / `NSWindow.close()` calls from the show action. The existing observation closes recovery only after the shared model has propagated the insertion transition. No timer, polling, new owner, or provider change was added.

## Public API boundary

### MenuBarExtra

- `MenuBarExtra(isInserted:)` allows the app to request insertion/removal and reports user removal by changing the binding.
- Apple explicitly notes that the item may still not be visible when the menu bar has insufficient room.
- Apple does not document this binding as the macOS System Settings “Allow in Menu Bar” preference.
- There is no public API here to read or write that system preference authoritatively, nor a callback that proves actual on-screen pixels.

### NSStatusItem

- `NSStatusBar` explicitly creates and removes app-owned status items.
- `NSStatusItem.isVisible` is public read/write state and KVO-observable. User removal changes it to false.
- `autosaveName` gives the item a stable public persistence identity.
- Apple documents that `isVisible` can remain true while the item is temporarily absent because the menu bar has insufficient room. It is therefore still not actual-pixel visibility.
- Apple does not document `isVisible` or `autosaveName` as authoritative read/write access to the macOS 26 System Settings database.

### Direct answers

| Question | Answer |
| --- | --- |
| Can `MenuBarExtra` authoritatively read “Allow in Menu Bar”? | No documented public API. |
| Can it authoritatively write it? | No documented public API. |
| Does `isInserted` update that exact setting? | Not documented; it updates the scene's insertion request and receives removal. |
| Does `NSStatusItem` update that exact setting? | Not documented as the same preference; it does provide public `isVisible` state and persistence. |
| What callback exists for a system/user hide? | `MenuBarExtra` can receive a false binding; `NSStatusItem.isVisible` is KVO-observable when removal changes it. Neither proves why all pixels are absent. |
| What visibility is public? | Requested/insertion state for `MenuBarExtra`; public logical visibility for `NSStatusItem`; neither is authoritative physical visibility. |

No supported URL was found for opening the exact Menu Bar settings pane. QuotaPulse should not ship an undocumented `x-apple.systempreferences:` deep link. A generic “Open System Settings” action is public but is not useful enough to replace concise guidance.

## OpenAI / Codex association evidence

Current runs are not owned by OpenAI/Codex:

- Direct `open` launch: QuotaPulse had PPID 1, LaunchServices bundle `dev.quotapulse.development.app`, UIElement application type, and a Control Center host named with that same bundle identifier.
- Codex-descendant launch: QuotaPulse was a direct child of the Codex process, whose parent was ChatGPT, but LaunchServices and Control Center still attributed the item to `dev.quotapulse.development.app`.
- Running while ChatGPT was visible did not change the owner.
- System Settings showed separate ChatGPT, Codex Computer Use, and QuotaPulse rows.
- The temporary `NSStatusItem` spike also produced a Control Center host beginning with `dev.quotapulse.development.app`; only the stable `autosaveName` suffix differed.

Therefore process ancestry and `MenuBarExtra` hosting are disproved as sufficient current causes. Control Center is the rendering broker for both shells, but the client/host identity in current logs is QuotaPulse.

The remaining association is historical stale Control Center tracking, not a current bundle/executable identity failure. A previous machine-local record associated QuotaPulse item identifiers with the `com.openai.codex` owner. The exact historical write event is no longer provable from retained public logs, and this task intentionally did not read or modify private Control Center state.

The original reproducible contamination source was app-hosted XCTest. With the old shell and parallel execution, a full suite launched seven QuotaPulse test-host processes and every process registered a Control Center status-item host. The hybrid composition root now omits controller creation before any AppKit status-item call in XCTest, and the scheme has returned to parallel execution.

## Controlled experiments

Environment: macOS 26.6.2 (25G83), Xcode 26.6 (17F113). PID values are evidence from this run, not stable identifiers.

| Experiment | QuotaPulse PID / parent | Bundle / Control Center host | Result |
| --- | --- | --- | --- |
| A. Direct launch with `open` | 39528 / 1 | `dev.quotapulse.development.app` / same-bundle `Item-0-39528` | Standalone LaunchServices UIElement; real item inserted and clickable. |
| B. Launch as a Codex descendant | 40073 / 3360 (Codex; parent 3112 ChatGPT) | `dev.quotapulse.development.app` / same-bundle `Item-0-40073` | Codex/ChatGPT ancestry did not alter ownership. |
| C. Build only | none | Debug artifact `dev.quotapulse.development.app` | Build created no process and no status-item host. |
| D. Full XCTest before containment | 40317, 40319...40324 / XCTest | seven same-bundle test hosts | Suite passed, but parallel app-hosted execution created seven short-lived hosts; one briefly requested visibility. |
| D2. Full XCTest after serial containment | 42235 / XCTest | one same-bundle test host | 268 tests passed, 2 skipped; one host still requested true then false within about 15 ms. |
| E. Launch after XCTest | 40461 / 1 | `dev.quotapulse.development.app` / same-bundle `Item-0-40461` | Normal standalone host; no OpenAI owner. |
| F. Run while ChatGPT/Codex visible | same A/B processes | unchanged QuotaPulse host | No ownership or visibility coupling observed. |
| G. Toggle ChatGPT/QuotaPulse through System Settings | not run | read-only UI showed separate ChatGPT, Codex Computer Use, and QuotaPulse rows | Mutation requires explicit action-time approval; absence of this experiment is not presented as a pass. |

## Temporary NSStatusItem spike

The isolated `/tmp` spike used the same Debug bundle identifier, one public `NSStatusItem`, a stable `autosaveName`, the QuotaPulse SF Symbol, static `42%`, and a minimal SwiftUI popover.

Observed results:

- `isVisible` began true and was KVO-observable.
- Setting false removed the displayable while the same process stayed alive.
- Setting true recreated it immediately.
- Control Center still brokered the status item and attributed the host to `dev.quotapulse.development.app`.

The spike proves stronger explicit shell control. It disproves the idea that changing shell alone changes bundle ownership. It is temporary and is removed after evidence collection.

## Validation

- Full parallel XCTest after the post-migration fixes: **passed**, 278 passed, 2 explicitly skipped live tests, 0 failures (280 total).
- Debug build: **passed**; generated identity `dev.quotapulse.development.app`, display name `QuotaPulse Debug`, `LSUIElement = true`.
- Release build: **passed**; generated identity `dev.quotapulse.app`, display name `QuotaPulse`, `LSUIElement = true`.
- `git diff --check` and staged diff check: **passed**.
- No private API, private preference/database access, Control Center modification, bundle-ID change, provider change, networking, scheduler/timer, or unbounded task was added.
- Controller fakes passed create-once, hide/show, external-removal projection, recovery force-show, bounded 100-cycle popover exercise, teardown, accessibility, delegate no-duplicate, and hidden login-item no-create tests. A read-only Control Center log over the parallel full-suite window contained no QuotaPulse/status-item host event.
- A live Debug launch created exactly one same-bundle `NSStatusItem` host with the stable autosave suffix and `clientRequestsVisibility: true`; this is host/ownership evidence, not proof of actual pixels or interaction.
- Unit/build evidence does not prove System Settings synchronization, actual menu-bar pixels, VoiceOver, multiple-display behavior, signing for distribution, notarization, or release readiness.

## Formal comparison

`BETTER` / `SIMILAR` / `WORSE` are relative to QuotaPulse requirements, not general framework quality.

| Area | MenuBarExtra | NSStatusItem hybrid | Why |
| --- | --- | --- | --- |
| 1. macOS 14 support | SIMILAR | SIMILAR | Both are public and supported. |
| 2. macOS 26 behavior | WORSE | BETTER | AppKit exposes logical visibility, KVO, and stable autosave identity. |
| 3. System menu-bar integration | SIMILAR | SIMILAR | Both are brokered by the native status-item system. |
| 4. Show/hide control | WORSE | BETTER | SwiftUI binding has a recovery race; AppKit has direct `isVisible`/create/remove. |
| 5. Runtime insertion/removal | WORSE | BETTER | AppKit owns the item explicitly. |
| 6. Process lifecycle | WORSE | BETTER | AppKit does not tie the shell to a Scene's automatic termination semantics. |
| 7. `LSUIElement` behavior | SIMILAR | SIMILAR | Both work in an agent app. |
| 8. Reopen/recovery | WORSE | BETTER | A retained controller can recreate/show the item directly. |
| 9. Launch at Login | SIMILAR | SIMILAR | `SMAppService.mainApp` is independent of shell. |
| 10. Control Center interaction | SIMILAR | SIMILAR | Neither grants Control Center preference access or different bundle ownership. |
| 11. Item identity/ownership | WORSE | BETTER | `autosaveName` and one controller make ownership explicit and stable. |
| 12. Icon + percentage | SIMILAR | SIMILAR | Both support image plus dynamic title. |
| 13. Dynamic text updates | SIMILAR | SIMILAR | SwiftUI observation versus controller-driven button update. |
| 14. Pinned provider | SIMILAR | SIMILAR | Existing `MenuBarPresentation` can remain the source. |
| 15. Remaining / Used | SIMILAR | SIMILAR | Existing `UsagePresentation` remains unchanged. |
| 16. Keyboard navigation | BETTER | WORSE | SwiftUI supplies more behavior automatically; AppKit shell needs explicit focus work. |
| 17. VoiceOver | BETTER | WORSE | Existing semantics work; the hybrid needs explicit button/popover verification. |
| 18. Reduced transparency/accessibility | BETTER | WORSE | SwiftUI window style is automatic; a custom popover/window needs validation. |
| 19. Multiple displays | BETTER | WORSE | MenuBarExtra delegates more placement behavior; custom popover placement must be tested. |
| 20. Notch/menu-bar overflow | SIMILAR | SIMILAR | Both remain subject to macOS layout and available width. |
| 21. Settings integration | WORSE | BETTER | `NSStatusItem.isVisible` provides a clearer public logical state. |
| 22. Automated testing | WORSE | BETTER | A controller can be injected and omitted; Scene construction cannot be cleanly omitted from app-hosted XCTest. |
| 23. App-hosted XCTest isolation | WORSE | BETTER | Current SwiftUI scene still registers hosts even with a false binding. |
| 24. Memory/CPU overhead | SIMILAR | SIMILAR | One retained native item/popover should be negligible; measure Release before claiming. |
| 25. Implementation complexity | BETTER | WORSE | Hybrid adds a controller and presentation/focus lifecycle. |
| 26. Maintenance burden | BETTER | WORSE | More AppKit code and manual regression coverage. |
| 27. Compatibility risk | SIMILAR | BETTER | `NSStatusItem` is mature and explicit, but macOS 26 still needs manual verification. |
| 28. Migration risk | BETTER | WORSE | Keeping current code has no migration; hybrid must preserve all presentation behavior. |

## Weighted decision

Scores are 1-5; weight follows QuotaPulse's declared priority order.

| Priority | Weight | MenuBarExtra | Hybrid |
| --- | ---: | ---: | ---: |
| Reliability | 30 | 3 | 5 |
| Low resource usage | 20 | 5 | 4 |
| Privacy | 15 | 5 | 5 |
| Predictable native UX | 12 | 4 | 5 |
| Accessibility | 10 | 5 | 4 |
| Maintainability | 8 | 5 | 3 |
| Extensibility | 5 | 3 | 5 |
| Weighted total | 100 | **4.18 / 5** | **4.54 / 5** |

The hybrid wins because reliability has the largest weight. Its accessibility and maintenance deficits are migration acceptance work, not reasons to leave an unreliable shell in place.

## What NSStatusItem would and would not solve

| Observed problem | Solved? | Boundary |
| --- | --- | --- |
| OpenAI/Codex grouping | **No** | Both shells use the QuotaPulse process/bundle and Control Center broker. Historical stale state remains system-owned. |
| System visibility synchronization | **Partially** | Public logical `isVisible` + KVO + autosave, but no authoritative Control Center preference or pixel visibility. |
| Explicit Show/Hide reliability | **Yes** | One controller directly changes/removes/recreates one item. |
| Hidden-app lifecycle | **Yes, with policy work** | The app/controller can remain alive independently of item visibility; login-item and quit rules remain explicit. |

## Post-migration Control Center and width evidence

On macOS 26.6.2, both the shipping Debug identity `dev.quotapulse.development.app.primary-status-item` and a temporary `dev.quotapulse.development.app.primary-status-item-v2` host followed the ChatGPT System Settings toggle. In both runs Control Center moved the correctly identified QuotaPulse host to its blocked list, `NSStatusItem.isVisible` KVO changed to `false`, QuotaPulse persisted intent remained `true`, and restoring ChatGPT unblocked the host and returned KVO to `true`. A new autosave identity therefore does not cross the coupling boundary and is not retained.

Read-only Control Center state showed the QuotaPulse Debug bundle location inside the tracked `com.openai.codex` application entry. A raw Mach-O launch from the Codex-owned shell had the correct QuotaPulse bundle and executable but an inferred ChatGPT `parentASN`; launching the same bundle through LaunchServices with `open` produced a normal application launch from PID 1 with no inferred parent. This is evidence for avoiding raw executable menu-bar acceptance launches from a foreign app-owned shell. It does not provide a supported way to delete or rewrite the historical mapping, and no private state was changed.

With the standard button and variable length, measured widths for `—`, `0%`, `61%`, and `100%` were 47.5, 55.5, 62.5, and 69.5 points. The 15-point image, 2-point image/title gap, measured title, and approximately 10 points at each button edge accounted for those widths. `imageHugsTitle = true` preserved the same measurements. Setting `length` from the native intrinsic width reduced all four widths by exactly 16 points to 31.5, 39.5, 46.5, and 53.5 points, retaining approximately 2 points at each edge and the native 2-point image/title gap. The implementation therefore keeps the standard `NSStatusBarButton`, derives length after every title update, and does not use a fixed width or custom view. Spacing outside the button frame after item rearrangement remains macOS-owned placement spacing.

## Product UX

Use the concise label **“Show Menu Bar Item”**. Helper text should say: **“macOS may also control visibility in System Settings.”**

Do not expose “persisted intent”, “runtime insertion”, or “Control Center host” in normal Settings. If requested ON but the public runtime state is false, show one concise recovery message and an **Open System Settings** button only if it opens the generic public System Settings app; do not use an undocumented pane URL. Do not claim “Visible” unless an accessibility/manual check actually observed the item.

## Foreign-association prevention

1. Keep permanent Debug `dev.quotapulse.development.app` and Release `dev.quotapulse.app` identities.
2. Build-only runs must never launch a menu-bar process.
3. Run manual menu-bar acceptance from one fresh Debug artifact, with exactly one QuotaPulse process.
4. Do not create status items in helper processes.
5. Keep `StatusItemController` omitted from app-hosted XCTest; parallel tests must continue to create zero status items.
6. Do not infer ownership from PPID alone; verify LaunchServices bundle identity and Control Center host logs.
7. Launch the app bundle through Finder, Spotlight, or LaunchServices; do not run its Mach-O directly from a ChatGPT/Codex-owned shell for menu-bar acceptance. Record ancestry only alongside the app's own LaunchServices identity and Control Center host logs.
8. Never repair stale association through private Control Center files, protected preferences, private frameworks, or `defaults` workarounds.

## Final acceptance record

The production switch and automated controller/test-host gates are complete. Manual acceptance passed for Settings OFF → ON in the same PID, hidden explicit reopen and recovery, click toggling, outside-click dismissal, Settings and Quit actions, keyboard focus, VoiceOver, light/dark mode, reduced transparency, multiple displays, notch/overflow, icon + percentage, Remaining/Used, pinning, unavailable placeholders, wake/sleep, compact status-item width, and one-process ownership. A clean macOS user account also passed Release Finder／LaunchServices startup with independent QuotaPulse and ChatGPT visibility. These are recorded separately from build, XCTest, and Control Center host evidence.

The primary development account's ChatGPT → QuotaPulse cascade is historical user-scoped macOS Control Center stale application association caused by prior unusual development/testing launch topology. It is not a normal user-facing product issue and is not classified as a current QuotaPulse Release architecture defect. Do not clear or repair that state programmatically, rotate bundle identifiers or `autosaveName`, use private Control Center APIs, or claim the state is impossible on every macOS installation. Preventive practice is to launch the `.app` through Finder, Spotlight, or LaunchServices／`open` for manual menu-bar testing, rather than directly executing its Mach-O from a Codex／ChatGPT-owned shell.

Final status: **Hybrid NSStatusItem migration COMPLETE. Milestone A COMPLETE / frozen. Milestone B COMPLETE. Milestone C NEXT / NOT STARTED.**
