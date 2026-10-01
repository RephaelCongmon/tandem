# Glance Inject

Build a comparison candidate in `codex/glance-inject`, based on Tandem 1.6.2. The asking Mac can inject pasted text or a selected AI response into a translucent overlay on the sending Mac and adjust its position and scroll in real time. Use the existing `~/Desktop/Dev/glance` project as the reference for passive, non-key, click-through presentation. Integrate the overlay into Tandem; no separate Glance process or new dependency is required.

## Behavior

- Studio has a Glance Inject toolbar panel with a persistent text draft and Inject action. AI messages have an Inject into Glance action. Neither action calls an AI service or changes the Source clipboard.
- Content renders as Markdown, including code, in a dark translucent panel. Text remains opaque. The panel never takes keyboard focus and clicks pass through to the underlying app.
- Studio controls normalized placement by dragging a miniature display, chooses the Source display, adjusts width, height, opacity and font size, and scrolls with a slider or overlapping 80-point steps. Content submission resets scroll to the top. Show/hide and clear are explicit controls.
- Layout and scroll changes are coalesced to at most 30 control messages per second; only the last pending state is sent. Text is sent only when injected. Source acknowledges actual placement and scroll so the Studio can show its state.
- Approved connected Studios can inject while Source sharing is enabled and unlocked. Explicit content injection takes ownership of the single overlay; only its owner can subsequently move, scroll, hide or clear it. Source can hide or disable injection. Disconnect, pause, lock, role change and shutdown clear the owner's overlay. Reconnect never replays old text.
- Source advertises `glanceInject`. Older peers show an update explanation and receive no new commands. The existing encrypted control connection carries the feature. Reject non-finite geometry and text over 64 KiB before changing state; clamp finite layout and scroll to safe ranges.
- Support macOS 14+. Keep the release version unchanged and leave the worktree/branch intact for comparison. Do not merge, install over the user's app, or publish a release.

## Components and flow

`TandemCore/Glance` defines the payloads, bounded session state and normalized geometry. Source owns an AppKit nonactivating panel with an NSScrollView and a passive Markdown renderer using the existing parser, with wrapped code and vertically stacked table columns. SourceEngine gates messages using its current session approval/sharing policy. Studio owns a controller for drafts, capability state, acknowledgements and coalesced updates. SwiftUI controls and AI message actions call that controller. Source UI and menu bar expose visibility and a local Hide action.

Default layout occupies roughly a third of the selected display, near its upper-right corner. Placement uses the Source display's usable frame, with top-left normalized coordinates. Resizing and monitor changes keep the overlay on screen. The normal Tandem setting to exclude its own windows applies to this overlay; other apps' recording filters remain outside Tandem's control.

## Validation

Test wire round trips, Unicode text, size/geometry limits, ownership, stale revisions, clear/reset behavior, display geometry including negative origins, Source approval and pause/disconnect gates, focus/pass-through window properties, real scrolling with long content, and Studio capability/lifecycle/coalescing. Run the full core/app suite and a warning-free build. Use isolated local Source/Studio profiles with a test screen and mock AI to verify pasted content, response injection, placement, scrolling and Source hide/pause, then package a signed comparison build.
