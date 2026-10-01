# Testing Tandem

## Automated

```bash
scripts/test_all.sh
```

It runs:
- **424 core/UI tests** (plus opt-in live checks). Wire codec, secure handshake (including man-in-the-middle, tamper and replay), real-TCP loopback sessions, H.264 encode→decode, image codec, context building, stores, AI clients against recorded streams, Markdown, Bluetooth stream transport, markup renderer and editor, hotkeys.
  - Listening: audio messages on the wire, Opus and PCM round trips, packetizing, gain and levels, the audio timeline, transcript excerpts and their context text, skills that carry transcripts, and a **live on-device transcription** of a sentence spoken by `say`, streamed in 100 ms chunks (macOS 26; the SFSpeechRecognizer variant runs only where that permission was granted).
  - Parakeet: the utterance segmenter (captions while speaking, finishing at pauses, cutting long speech in its quietest moment, ignoring clicks and hum), and a live Parakeet transcription of two spoken questions (`TANDEM_PARAKEET_MODELS`; `scripts/test_all.sh` sets it when the app's model is downloaded). The Hugging Face fallback download is opt-in with `TANDEM_PARAKEET_DOWNLOAD_TEST=1`.
  - Updates between the Macs: the new messages on the wire, and the package assembler (intact, damaged, oversized and foreign packages).
  - Codex: launch arguments (only known features, MCP servers from config), sign-in parsing (never keeps an API key), error mapping. The client is tested against a stand-in `codex app-server` (Python): streaming, safety parameters, screenshots as files removed afterwards, thread reuse and folding, failures, declined approvals, interrupt on Stop, and the model list. `TANDEM_LIVE_CODEX=1 swift test --filter CodexLiveTests` asks the real Codex twice in one thread and checks it remembers.
  - The Claude Code client is tested against recorded CLI output and a fake `claude` script: streaming, stdin contents, errors, a CLI that quits without reading, cancellation, idle timeout, and live sessions (a follow-up reuses the process and sends only the new message; a changed history starts over; the spare process; a failed answer isn't kept).
  - `TANDEM_LIVE_CLAUDE=1 swift test --filter AIClaudeCodeLiveTests` (in `Core/`) checks the real installed CLI's version and sign-in.
- **19 app tests.** Chat streaming, failure/retry, stop, snapshots, busy handling, settings persistence, hotkey overrides, converting ScreenCaptureKit audio buffers, and transcripts attached to questions (Follow-up carries the spoken question, then only newer speech; nothing when Listen or the setting is off).
- **An app build** that fails on any warning.

## One-Mac end-to-end (what was verified during development)

`scripts/dev-two-macs.sh --mock-ai` starts a Source (profile A) and a Studio (profile B) with a synthetic test pattern and a mock Claude API. Drive them with `swift scripts/debug-command.swift <profile> <command>` and inspect state with `… dump` plus `/usr/bin/log show --predicate 'category == "Debug"'`.

Verified this way:
- the region tool (debug commands `regionTool on`, `regionDrag x y w h`, `regionDown`/`regionUp`, `regionBurst N`): on a static screen (`TANDEM_TEST_PATTERN_STATIC=1`) each crop was in the composer 40–56 ms after release with no preview, including four drags back to back; on the animated pattern a held drag got the Source's preview (~72 KB) and the crop came from that still; a click without a region added nothing; five pictures reached the mock request as five images; the live view resumed from a keyframe after every drag
- deliberate region selection (1.6.1 sheet, still served to older Studios): the returned crop retains the frozen timestamp even as the live screen changes; multiple selected regions coexist; excluded pictures stay in the composer and a skill sends zero images; including them sends exactly those two crops; pause/resume invalidates an old selection and Retake recovers;
- auto-pairing over Bonjour (6-digit code sheets on both sides; codes match);
- session reconnect after restarts and after a hard kill of either side, with no prompt, window or focus change on the Source;
- a Source opened at login (`-TandemSimulateLoginLaunch YES`, launched with `open -g`) staying window-less while it pairs, reconnects and answers captures, and its window opening from the Dock or menu bar afterwards;
- a pairing request bringing the hidden Source's window forward with the code sheet, without activating it;
- live view at 1920×1080, 30 fps, with 8–20 ms measured capture-to-display latency over loopback;
- stream pausing while the Studio window is hidden and resuming when it's visible;
- the Debug and Follow-up skills through Claude Code: each answer followed its skill's instructions, and the typed text arrived as extra context;
- asking through the real Claude Code CLI on a subscription, with a follow-up question that relies on the earlier answer and screenshot;
- asking with selected regions, which produces a correct Anthropic request: `claude-opus-5-5`, adaptive thinking, `effort`, `fallbacks: "default"` plus its beta header, `cache_control`, and a base64 JPEG;
- streamed Markdown rendering, the reasoning disclosure, and reply mirroring to the Source;
- Source push with a note, and the quick-note panel;
- auto-capture every 5 s with "No change" detection and a 4-image context window;
- the markup editor, onboarding steps, and every Settings pane (rendered in-app with `snap`);
- **listening**, with `TANDEM_TEST_AUDIO` playing a two-question meeting clip on the Source. Captions follow the speech. **Follow-up** pressed about a second after each question got the complete question, and only the new speech the second time. Claude restated it with speech-to-text mistakes fixed ("cash invalidation" → cache invalidation) and answered, with first words 2.3 s after the click for a new thread and 1.7 s in a thread with a live Claude Code session;
- **Parakeet** in the app: the model downloaded from the `speech-models-1` mirror (checksum-checked) 46 s after the Studio started, then loaded in 0.3 s. On the two-question clip it heard "write path" and "cache invalidation" where Apple's recognizer heard "right path" and "cash invalidation". Follow-up got both questions complete, with first words 2.2–2.4 s after the click. A 40-clip Earnings-22 bake-off on this Mac gave 14.4% word errors for Parakeet (Core ML) against 19.7% for Apple, at 93× real time;
- **Codex** (0.159.2, signed in with ChatGPT). Settings showed its status and your account's live model list. The two-question clip with GPT-6.1 Sol got both questions right with the Follow-up format, with first words at 3.8 s (new thread) and 2.7 s (the follow-up in the same thread). The real Codex refused to run anything with Tandem's launch flags ("NO TOOLS");
- **updates between the Macs**, with a 0.0.0 Source and a 9.0.0 Studio (both signed with the team's Apple Development certificate). The Studio sent its 19 MB app on connect. The Source checked and installed it in 0.2 s, relaunched with its arguments, and reconnected on 9.0.0 3 s after the offer;
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
8. **Codex.** Choose **Codex — your ChatGPT subscription** in Settings › AI. The status says *signed in with ChatGPT*, **Test** answers, and the model menu lists your plan's models. Ask with a screenshot, then a follow-up that relies on the first answer.
9. **Listening.**
   - Join a call or play a video on the Source. On the Studio, turn on **Listen**: the caption shows the speech about a second behind, and the Source's window shows *Hearing this Mac's audio*.
   - Have someone ask a question, press **Follow-up**: the answer restates that question and answers it.
   - Ask a second question in the same thread: its **Transcript** chip holds only the newer speech.
   - Pause or lock the Source: the caption explains why there's no audio, and it resumes afterwards.
   - Turn off Settings › Sharing › *Let the other Mac hear this Mac's audio* on the Source: the Studio says audio sharing is off.
   - On a Studio running macOS 14 or 15, the first Listen asks for Speech Recognition permission.
10. **Real AI.**
   - With Claude Code signed in on the Studio, Settings › AI shows the account and plan. **Test** answers in a few seconds. Sign out (`claude auth logout`): the chat shows how to sign in again.
   - Add an Anthropic key, press **Test** in Settings › AI, then ask with a screenshot.
   - Repeat with an OpenAI key.
   - Try an OpenAI-compatible local server (LM Studio at `http://localhost:1234/v1`).
11. **Sleep/wake.** Sleep the Studio, wake it: it reconnects on its own.
12. **Background Source.** Turn on **Open at login** on the Source, log out and in: no window appears, the menu bar icon does, and the Studio connects. Clicking the Dock icon or **Open Tandem** shows the window.
13. **Updates.** On the asking Mac, **Update Now**; within seconds of it restarting, the shared Mac shows the new version too (Settings › General › Updates › *Shared Mac*), with nothing done on it.
14. **Updates from GitHub.** With an older version installed, **Tandem › Check for Updates…** shows the toolbar's **Update** button and its panel. **Update Now** replaces the app and relaunches the new version; from a disk image, it installs into Applications. Without GitHub access, Settings › General › Updates explains how to add it.
