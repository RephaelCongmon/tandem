# Glance Inject Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for inline implementation. Preserve the separate comparison worktree.

**Goal:** Inject text and AI responses onto the paired Source's passive overlay, with immediate remote placement and scrolling controls.

**Architecture:** Add capability-gated encrypted control payloads and a bounded single-owner session. A native Source panel renders the state; a Studio controller coalesces geometry/scroll changes and the SwiftUI panel exposes them.

**Tech Stack:** Swift, AppKit, SwiftUI, existing TandemCore/TandemUI, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-09-30-glance-inject-design.md`.

## Global Constraints

64 KiB content limit; macOS 14+; no new dependency; maximum 30 updates/sec; approved, active Source sessions only; keep current version; no main merge or public release.

## Review Focus

- Stale acknowledgements must not rewind an actively dragged placement.
- Closing, unapproved or paused connections must not create or resurrect an overlay.
- An extremely long Markdown/code response must remain scrollable and bounded.
- Monitor removal and negative display origins must keep the overlay visible.
- Opening or updating the overlay must preserve the Source app's keyboard focus.

### Task 1: Wire and session

Create `Core/Sources/TandemCore/Glance/GlanceInject.swift` and `Core/Tests/TandemCoreTests/GlanceInjectTests.swift`; extend `Wire/Messages.swift` with capability, command and status cases. Payloads are `GlanceContent`, `GlanceLayout`, `GlanceCommand`, `GlanceDisplay`, `GlanceStatus`. `GlanceSession.apply(_:from:)` validates and changes owner/content/layout/visibility/scroll only for valid current revisions. `GlanceLayout.frame(in:)` produces bounded Source geometry.

- [x] Write and run failing round-trip, Unicode/oversize, non-finite layout, ownership/stale revision and geometry tests.
- [x] Implement the minimal model and codec integration; run `swift test --package-path Core --filter GlanceInjectTests`.

### Task 2: Source overlay and policy

Create `App/Sources/Glance/GlanceOverlayController.swift` and `App/Tests/GlanceOverlayTests.swift`; integrate SourceEngine, SettingsStore/SettingsView and capability advertisement. Controller applies a validated `GlanceCommand`, clamps panel frame to an available display, renders Markdown, updates actual scroll and publishes status. SourceEngine accepts only approved connected viewers while sharing is active and injection allowed. Clear on owner disconnect/pause/lock/deactivation; locally Hide or disable through Source UI/menu.

- [x] Write and run failing window, long-content scroll, ownership reset and Source policy tests.
- [x] Implement panel and policy; run focused app tests and build with no Swift warnings.

### Task 3: Studio controls and end-to-end verification

Create `App/Sources/Glance/GlanceInjectController.swift`, `App/Sources/Studio/Views/GlanceInjectView.swift`, and `App/Tests/GlanceInjectControllerTests.swift`; integrate StudioEngine lifecycle, Studio toolbar and AI reply actions. Attach to the current connection, query status only when supported, and cancel pending updates on detach. Text submits immediately. Coalesce only layout/scroll updates using the newest revision; ignore stale successful acknowledgements. Preserve drafts across popover dismissal.

- [x] Write and run failing capability, coalescing, revision and disconnect tests.
- [x] Implement controller and controls; verify real injection, movement and scroll with isolated local profiles.
- [x] Run the full core/app checks, review the candidate independently, package a signed build, update docs, commit and push `codex/glance-inject`. Leave comparison branch/worktree intact.

## Evidence

- Full checks: 435 core tests (6 optional skips), 32 app tests, zero failures; app build succeeds without Swift warnings.
- Independent review's three findings fixed with failing-then-passing tests: capture interruption, lock gating and wide Markdown reachability.
- Paired local instances verified text/AI-answer injection, remote placement presets and scrolling, Source Hide, and pause/resume clearing without replay.
- Signed universal comparison package: `dist/Tandem-Glance-Inject-Codex.zip`; isolated-profile launcher disables updates. Hardware-only checks are recorded in `docs/GLANCE_INJECT_COMPARISON.md`.
- Preserve `codex/glance-inject` and this worktree for comparison; commit/push this candidate without merging or publishing a release.
