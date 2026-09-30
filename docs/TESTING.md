# Testing Tandem

## Automated

```bash
scripts/test_all.sh
```

It runs:
- **346 core tests** (plus one opt-in live check). Wire codec, secure handshake (including man-in-the-middle, tamper and replay), real-TCP loopback sessions, H.264 encode→decode, image codec, context building, stores, AI clients against recorded streams, Markdown, Bluetooth stream transport, markup renderer and editor, hotkeys.
  - The Claude Code client is tested against recorded CLI output and a fake `claude` script: streaming, stdin contents, errors, a CLI that quits without reading, cancellation, and idle timeout.
  - `TANDEM_LIVE_CLAUDE=1 swift test --filter AIClaudeCodeLiveTests` (in `Core/`) checks the real installed CLI's version and sign-in.
- **9 app tests.** Chat streaming, failure/retry, stop, snapshots, busy handling, settings persistence, hotkey overrides.
- **An app build** that fails on any warning.

## One-Mac end-to-end (what was verified during development)

`scripts/dev-two-macs.sh --mock-ai` starts a Source (profile A) and a Studio (profile B) with a synthetic test pattern and a mock Claude API. Drive them with `swift scripts/debug-command.swift <profile> <command>` and inspect state with `… dump` plus `/usr/bin/log show --predicate 'category == "Debug"'`.

Verified this way:
- auto-pairing over Bonjour (6-digit code sheets on both sides; codes match);
- session reconnect after restarts and after a hard kill of either side, with no prompt, window or focus change on the Source;
- a Source opened at login (`-TandemSimulateLoginLaunch YES`, launched with `open -g`) staying window-less while it pairs, reconnects and answers captures, and its window opening from the Dock or menu bar afterwards;
- a pairing request bringing the hidden Source's window forward with the code sheet, without activating it;
- live view at 1920×1080, 30 fps, with 8–20 ms measured capture-to-display latency over loopback;
- stream pausing while the Studio window is hidden and resuming when it's visible;
- asking through the real Claude Code CLI on a subscription, with a follow-up question that relies on the earlier answer and screenshot;
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
   - Close the shared window: sharing pauses and the Source asks what to share next.
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
   - With Claude Code signed in on the Studio, Settings › AI shows the account and plan. **Test** answers in a few seconds. Sign out (`claude auth logout`): the chat shows how to sign in again.
   - Add an Anthropic key, press **Test** in Settings › AI, then ask with a screenshot.
   - Repeat with an OpenAI key.
   - Try an OpenAI-compatible local server (LM Studio at `http://localhost:1234/v1`).
9. **Sleep/wake.** Sleep the Studio, wake it: it reconnects on its own.
10. **Background Source.** Turn on **Open at login** on the Source, log out and in: no window appears, the menu bar icon does, and the Studio connects. Clicking the Dock icon or **Open Tandem** shows the window.
11. **Updates.** With an older version installed, **Tandem › Check for Updates…** shows the toolbar's **Update** button and its panel. **Update Now** replaces the app and relaunches the new version; from a disk image, it installs into Applications. Without GitHub access, Settings › General › Updates explains how to add it.
