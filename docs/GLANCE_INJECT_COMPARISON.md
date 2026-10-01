# Glance Inject — Codex comparison candidate

Branch: `codex/glance-inject`, based on Tandem 1.6.2 (`023af98`). This candidate stays separate from main and from the other implementation.

## Run on both Macs

1. Extract `Tandem-Glance-Inject-Codex.zip` on each Mac. Quit any other Tandem instance before comparing candidates.
2. Open **Launch Glance Inject Codex.command**, keeping it beside the included `Tandem.app`. The launcher opens that exact app with the `GlanceInjectCodex` profile: separate preferences, pairing keys and conversation history. It disables automatic updates for this profile so both Macs keep this candidate.
3. Complete onboarding: **Share this Mac** on the sending Mac (Source), **Ask from this Mac** on the asking Mac (Studio), then pair them normally. Existing Tandem permissions may apply; grant the usual recording and network access if macOS requests them.

Use the launcher each time to retain isolation. The app is signed with an Apple Development certificate and has not been notarized. The packaged app keeps version 1.6.2; capability negotiation identifies support for Glance Inject. Both Macs need this candidate for the feature.

## Compare the experience

- Click **Glance Inject** in the asking Mac's toolbar, paste/type text and click **Inject Text**. Text appears on the sending Mac in a passive, translucent panel; its keyboard focus and mouse interaction stay with the underlying app.
- Click the overlay icon beside a completed AI answer to inject it directly, without copying or making another AI request.
- Drag the panel in the miniature display or use the placement presets. Choose a display; adjust width, height, background opacity and text size. Move through long content with the scroll slider or up/down buttons.
- **Hide Overlay** preserves content for **Show Overlay**; **Clear** removes it. Replacing text resets scroll. Closing and reopening the controls preserves the draft.
- The Source's **Glance Inject** card and menu bar can hide the panel. The card or Settings › Sharing can disable injection. Pause, lock, capture interruption and the controlling Studio disconnecting clear the content; reconnect does not replay it.

The current owner controls placement and scrolling. A second approved Studio can take ownership by injecting its own content. Commands use Tandem's encrypted control connection; movement and scrolling send the newest state at up to 30 Hz, with no repeated text payloads. Injection is limited to 64 KiB of UTF-8 text. Code wraps; table columns stack vertically so everything remains reachable in a click-through panel.

## Verification

435 core tests (6 optional checks skipped) and 32 app tests passed. The app builds without Swift warnings; Debug and universal Release builds succeeded and the Release signature verifies. Independent review findings on capture interruption, lock policy and wide Markdown were fixed with failing-then-passing tests.

Paired local Source/Studio instances verified text injection, AI-answer injection, remote placement presets, scrolling, Source-local hide, and pause clearing. App tests verify window focus/pass-through properties, scroll bounds, stale revisions, ownership, capability handling and connection cleanup. Physical two-Mac latency, fullscreen/Spaces behavior and monitor unplugging remain hardware checks; geometry tests include negative display origins and tiny usable frames.

To rebuild from this branch: run `scripts/build-release.sh`, then `scripts/package-glance-comparison.sh`. The comparison package is written to `dist/Tandem-Glance-Inject-Codex.zip`.
