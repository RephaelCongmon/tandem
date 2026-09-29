# Testing Tandem

## Automated

```bash
scripts/test_all.sh
```

It runs:
- **304 core tests.** Wire codec, secure handshake (including man-in-the-middle, tamper and replay), real-TCP loopback sessions, H.264 encode→decode, image codec, context building, stores, AI clients against recorded streams, Markdown, Bluetooth stream transport, markup renderer and editor, hotkeys.
- **9 app tests.** Chat streaming, failure/retry, stop, snapshots, busy handling, settings persistence, hotkey overrides.
- **An app build** that fails on any warning.

## One-Mac end-to-end (what was verified during development)

`scripts/dev-two-macs.sh --mock-ai` starts a Source (profile A) and a Studio (profile B) with a synthetic test pattern and a mock Claude API. Drive them with `swift scripts/debug-command.swift <profile> <command>` and inspect state with `… dump` plus `/usr/bin/log show --predicate 'category == "Debug"'`.

Verified this way:
- auto-pairing over Bonjour (6-digit code sheets on both sides; codes match);
- session reconnect after restarts and after a hard kill of the Source;
- live view at 1920×1080, 30 fps, with 8–20 ms measured capture-to-display latency over loopback;
- stream pausing while the Studio window is hidden and resuming when it's visible;
- ask with a live snapshot, which produces a correct Anthropic request: `claude-opus-5-5`, adaptive thinking, `effort`, `fallbacks: "default"` plus its beta header, `cache_control`, and a base64 JPEG;
- streamed Markdown rendering, the reasoning disclosure, and reply mirroring to the Source;
- Source push with a note, and the quick-note panel;
- auto-capture every 5 s with "No change" detection and a 4-image context window;
- the markup editor, onboarding steps, and every Settings pane (rendered in-app with `snap`).

## Two-Mac hardware checklist

These need two real Macs (and permissions only a person can grant):

1. **Screen Recording.**
   - On the Source, choose a display and approve the macOS prompt; the live view appears on the Studio.
   - Switch to a window, then back to a display, from both the Source's picker and the Studio's **Source** menu.
   - Close the shared window: the Source falls back to the main display.
2. **Camera.** Choose a camera on the Source, approve the camera prompt, and confirm the live view and snapshots.
3. **Links.**
   - Same Wi-Fi: the badge shows *Wi-Fi*.
   - Wi-Fi on, different networks or none: the badge shows *P2P Wi-Fi*.
   - Thunderbolt/USB-C cable: the badge shows *Cable*, with lower latency in the HUD.
   - Turn Wi-Fi off on both and keep Bluetooth on: the badge shows *Bluetooth*, a small low-fps preview plays, and snapshots still arrive (slower).
   - **Connect by Address** with the Source's IP:47623.
4. **Latency.** Watch the ⚡ ms value in the Studio HUD, and move a window on the Source: the view should feel immediate on a cable or good Wi-Fi.
5. **Pairing.**
   - Codes match on both Macs. Declining closes the Studio sheet with a message.
   - Unpair on one side: the other shows "pairing is no longer valid" and can pair again.
6. **Shortcuts.**
   - ⌃⌥S and ⌃⌥N on the Source from another app work, and toasts confirm.
   - ⌃⌥Space and ⌃⌥C on the Studio work.
   - Changing and clearing a shortcut in Settings takes effect immediately.
7. **Privacy.**
   - Pause on the Source: the Studio shows *Sharing is paused* and snapshots are refused.
   - Lock the Source: sharing pauses and resumes on unlock.
   - With "Keep screenshots" off, relaunching the Studio shows *Not kept* placeholders.
8. **Real AI.**
   - Add an Anthropic key, press **Test** in Settings › AI, then ask with a screenshot.
   - Repeat with an OpenAI key.
   - Try an OpenAI-compatible local server (LM Studio at `http://localhost:1234/v1`).
9. **Sleep/wake.** Sleep the Studio, wake it: it reconnects on its own.
