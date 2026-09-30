# Testing Tandem

## Automated

```bash
scripts/test_all.sh
```

It runs:
- **385 core tests** (plus opt-in live checks). Wire codec, secure handshake (including man-in-the-middle, tamper and replay), real-TCP loopback sessions, H.264 encode→decode, image codec, context building, stores, AI clients against recorded streams, Markdown, Bluetooth stream transport, markup renderer and editor, hotkeys.
  - Listening: audio messages on the wire, Opus and PCM round trips, packetizing, gain and levels, the audio timeline, transcript excerpts and their context text, skills that carry transcripts, and a **live on-device transcription** of a sentence spoken by `say`, streamed in 100 ms chunks (macOS 26; the SFSpeechRecognizer variant runs only where that permission was granted).
  - The Claude Code client is tested against recorded CLI output and a fake `claude` script: streaming, stdin contents, errors, a CLI that quits without reading, cancellation, idle timeout, and live sessions (a follow-up reuses the process and sends only the new message; a changed history starts over; the spare process; a failed answer isn't kept).
  - `TANDEM_LIVE_CLAUDE=1 swift test --filter AIClaudeCodeLiveTests` (in `Core/`) checks the real installed CLI's version and sign-in.
- **14 app tests.** Chat streaming, failure/retry, stop, snapshots, busy handling, settings persistence, hotkey overrides, converting ScreenCaptureKit audio buffers, and transcripts attached to questions (Follow-up carries the spoken question, then only newer speech; nothing when Listen or the setting is off).
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
- the Debug and Follow-up skills through Claude Code: each answer followed its skill's instructions, and the typed text arrived as extra context;
- asking through the real Claude Code CLI on a subscription, with a follow-up question that relies on the earlier answer and screenshot;
- ask with a live snapshot, which produces a correct Anthropic request: `claude-opus-5-5`, adaptive thinking, `effort`, `fallbacks: "default"` plus its beta header, `cache_control`, and a base64 JPEG;
- streamed Markdown rendering, the reasoning disclosure, and reply mirroring to the Source;
- Source push with a note, and the quick-note panel;
- auto-capture every 5 s with "No change" detection and a 4-image context window;
- the markup editor, onboarding steps, and every Settings pane (rendered in-app with `snap`);
- **listening**, with `TANDEM_TEST_AUDIO` playing a two-question meeting clip on the Source. Captions follow the speech. **Follow-up** pressed about a second after each question got the complete question, and only the new speech the second time. Claude restated it with speech-to-text mistakes fixed ("cash invalidation" → cache invalidation) and answered, with first words 2.3 s after the click for a new thread and 1.7 s in a thread with a live Claude Code session;
- the app's real `AudioCaptureService`, compiled into a harness running with the terminal's Screen Recording permission, capturing system audio while `afplay` played the clip. The audio went through Opus and the wire codec, and the full transcript came out (about 21 kbps).

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
8. **Listening.**
   - Join a call or play a video on the Source. On the Studio, turn on **Listen**: the caption shows the speech about a second behind, and the Source's window shows *Hearing this Mac's audio*.
   - Have someone ask a question, press **Follow-up**: the answer restates that question and answers it.
   - Ask a second question in the same thread: its **Transcript** chip holds only the newer speech.
   - Pause or lock the Source: the caption explains why there's no audio, and it resumes afterwards.
   - Turn off Settings › Sharing › *Let the other Mac hear this Mac's audio* on the Source: the Studio says audio sharing is off.
   - On a Studio running macOS 14 or 15, the first Listen asks for Speech Recognition permission.
9. **Real AI.**
   - With Claude Code signed in on the Studio, Settings › AI shows the account and plan. **Test** answers in a few seconds. Sign out (`claude auth logout`): the chat shows how to sign in again.
   - Add an Anthropic key, press **Test** in Settings › AI, then ask with a screenshot.
   - Repeat with an OpenAI key.
   - Try an OpenAI-compatible local server (LM Studio at `http://localhost:1234/v1`).
10. **Sleep/wake.** Sleep the Studio, wake it: it reconnects on its own.
11. **Background Source.** Turn on **Open at login** on the Source, log out and in: no window appears, the menu bar icon does, and the Studio connects. Clicking the Dock icon or **Open Tandem** shows the window.
12. **Updates.** With an older version installed, **Tandem › Check for Updates…** shows the toolbar's **Update** button and its panel. **Update Now** replaces the app and relaunches the new version; from a disk image, it installs into Applications. Without GitHub access, Settings › General › Updates explains how to add it.
