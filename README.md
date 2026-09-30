# Tandem

**Two Macs, one conversation.** Tandem pairs two nearby Macs. One Mac (the **Source**) streams its screen, a window, or its camera to the other (the **Studio**) in real time. The Studio sends snapshots of that screen — with your own context, markup and redactions — to **Claude** or **OpenAI**, and shows the answers as a conversation thread. It can also **listen**: the Source's computer audio (a meeting or call) is transcribed live on the Studio, so a question someone asks out loud can be answered with one click.

It's built for moments like: your work laptop can't run AI tools but your personal one can; a demo or rehearsal where a second Mac watches and advises; a long-running job you want summarized every few minutes; or simply keeping the AI conversation off the screen you're working on.

## Highlights

- **Real-time live view.** Hardware H.264 with low-latency rate control, ack-based flow control that bounds queuing to about one round trip, and adaptive bitrate, at 1080p/30–60 fps. The live HUD shows measured capture-to-display latency; two instances on one Mac measured **8–20 ms**, and between Macs you add your link's round-trip time (a cable or good Wi-Fi keeps it in the tens of milliseconds).
- **Any link.** Wi-Fi/LAN, **peer-to-peer Wi-Fi** (no shared network needed — like AirDrop), **Thunderbolt/Ethernet cable**, or **Bluetooth LE** as a last resort. Tandem picks the best automatically and shows which one is in use.
- **Ask Claude or OpenAI.** Streaming answers with Markdown, code blocks, tables and an optional reasoning summary. By default Tandem asks Claude through **Claude Code on your Claude subscription**, with no API key. Claude Opus 5.5 is the default (Fable 5.1, Sonnet 5.5 and Haiku 4.5 are available). An Anthropic or OpenAI API key (GPT‑6 Astra/Sol/Luna), or any OpenAI-compatible server (LM Studio, Ollama, vLLM), also works.
- **Your context, your way.** Type a question; attach a fresh screenshot automatically; annotate it first (boxes, arrows, pen, highlight, text), **crop** to what matters and **redact** anything private before it leaves the Mac.
- **On demand, by shortcut, or on a schedule.** Global shortcuts on both Macs, a "send with note" panel on the Source, and auto-capture every N seconds — optionally only when the screen actually changed (detected on the Source, so unchanged screens aren't even sent), with an hourly cap.
- **Hears the meeting, too.** Turn on **Listen** and the Source's computer audio streams to the Studio (Opus, about 30 kbps) and is transcribed on-device as it's spoken, about a second behind. **Follow-up** finds the question just asked out loud, or on screen, and answers it in a few plain sentences. The transcript also goes with every other question, so the AI knows what's being discussed.
- **Remembers the conversation.** With Claude Code, each thread keeps a live session, so a follow-up sends only what's new and starts answering sooner. Earlier questions, answers, screenshots and transcripts stay in context.
- **Answers on both Macs.** Replies can be mirrored back to the Source's window and menu bar.
- **Private by design.** Pairing is confirmed with a 6-digit code; every session is end-to-end encrypted and mutually authenticated. Screenshots go only to the AI provider you choose, on your own subscription or key, and stay in memory unless you opt to keep them.

## Requirements

- Two Macs running **macOS 14 Sonoma or later** (Liquid Glass chrome on macOS 26).
- On the Studio Mac, one of:
  - [Claude Code](https://claude.com/claude-code), installed and signed in with your Claude account (run `claude` once in Terminal). This is the default, and questions count toward your Claude plan's usage.
  - An Anthropic or OpenAI API key.
  - A local OpenAI-compatible server.

## Getting started

1. Install Tandem on both Macs and open it.
2. On the Mac you want to see, choose **Share this Mac**. Allow **Screen Recording** when macOS asks (System Settings › Privacy & Security › Screen & System Audio Recording) and approve **Local Network** access.
3. On the other Mac, choose **Ask from this Mac**. If Claude Code is signed in there, it's picked for you, so just click **Continue**. Otherwise choose a provider and add its API key. Then pick the first Mac from the list.
4. Both Macs show the same 6-digit code. Confirm it matches and click **Allow** on the shared Mac. That's it — from now on the Macs reconnect automatically.

### Using it

**On the Studio (asking) Mac**
- The left panel is the live view; the right panel is the conversation. Double-click the live view (or the ⤢ button) for focus mode.
- Type a question and press ↩. With **Live screen** on, a fresh screenshot is attached when you send.
- Press the capture button (or ⇧⌘S) to grab a screenshot into the composer, then click it to **annotate, crop or redact** before sending.
- **Ask** (⇧⌘↩) captures and asks in one step using your typed text or the default prompt. Quick prompts live behind the ✦ menu.
- The ⏱ control turns on **auto-capture** and sets the interval; the menu also chooses whether each capture asks the AI or just updates the composer, and whether to skip unchanged screens.
- **Skills** are one-click buttons above the message field: **Debug**, **New Problem** and **Follow-up** to start with. Each one sends a fresh screenshot and what was just said (when **Listen** is on) plus that skill's detailed instructions, and anything you've typed goes along as extra context. The thread shows just the skill's name. ⌘1–⌘9 trigger the first nine. Add, edit and reorder skills in Settings › Skills, or with the ⚙ button next to them.
- **Listen** (next to Live screen, or ⌥⌘L) transcribes the shared Mac's computer audio. See [Listening](#listening-to-the-shared-macs-audio).
- The toolbar model menu switches provider, model and reasoning effort. The **Reasoning** chip under the message field changes the reasoning level (Fast, Balanced, Thorough, Deep, Maximum) from your next question on, offering only the levels the current model supports.
- The **Source** menu on the live view lets you choose which display, window or camera the other Mac shares (if it allows that).

**On the Source (shared) Mac**
- The window shows exactly what's being shared, who's watching, and over which link.
- **Send Snapshot** (⌃⌥S from any app) pushes a screenshot; **Send with Note…** (⌃⌥N) opens a small panel to add context first. The answer appears on the Studio and, optionally, on this Mac too.
- **Pause** (⌃⌥P) stops all capture instantly. Sharing also pauses automatically while the Mac is locked.

### Listening to the shared Mac's audio

Turn on **Listen** in the composer (next to **Live screen**), or press ⌥⌘L. The shared Mac starts sending what it plays: the other people on a call, a video, anything but Tandem's own sounds and its microphone. The Studio transcribes it on-device. A two-line live caption above the skill buttons shows the words about a second after they're spoken. The ❝ button next to it opens the whole transcript, with timestamps, **Copy** and **Clear**.

When someone asks you something out loud, press **Follow-up** (⌘3 in Tandem, or ⌃⌥F from any app). It sends the transcript, a fresh screenshot and the conversation so far. The answer starts with the question as Claude understood it, in italics with obvious speech-to-text mistakes fixed, followed by a direct answer in a few sentences. If you press it while the last words are still being recognized, Tandem waits a moment (up to 0.8 s) for them.

- Each question carries what was said **since the thread's previous question**, up to 10 minutes (Settings › Listening › At most). Earlier transcripts stay with their messages, so later questions keep the whole conversation in mind. Each sent message shows a **Transcript · N words** chip you can expand.
- Every question gets the transcript, not just Follow-up. Turn it off per skill in the skill's editor, or entirely in Settings › Listening.
- **Speed:** a question asked in a thread that already has answers typically starts streaming about 1.5–2 s after you click, and the first question of a thread in about 2–2.5 s.
- **Language:** Settings › Listening › Language (default: this Mac's). On macOS 26 Tandem uses Apple's SpeechAnalyzer; the first time a language is used, macOS may download its speech model, and the caption shows the progress. On macOS 14 and 15 it uses on-device speech recognition and asks for Speech Recognition permission once.
- **Nothing to set up on the shared Mac.** Audio uses the same Screen & System Audio Recording permission as the picture. It runs only while the Studio listens, sharing is on and the Mac is unlocked. The shared Mac's window shows **Hearing this Mac's audio** under that Studio, and macOS shows its own recording indicator. To never send audio, turn off Settings › Sharing › *Let the other Mac hear this Mac's audio* on the shared Mac.
- Both Macs need Tandem 1.3 or later. If the shared Mac is older, the caption says so; update it there with **Update Now**.

### Leaving the shared Mac alone

The Source never needs attention after pairing. Close its window and Tandem keeps listening from the menu bar; turn on **Settings › General › Open at login** and it starts that way after every login, with no window. When the Studio connects or reconnects (after Wi-Fi drops, sleep, or either app restarting), nothing appears on the shared Mac and it never takes focus. macOS shows its own screen-recording indicator in the menu bar while the screen is being captured.

The only things that put a prompt on the shared Mac are pairing a new Mac (or pairing again after one side forgot the other), and **Ask before each session** if you turn it on in Settings › Sharing. The window then comes forward with the prompt, without taking keyboard focus from the app in use.

### Updates

When a new version is published, an **Update** button appears in the window's toolbar. It opens what's new in that version, with **Later** and **Update Now**. The menu bar popover and **Tandem › Check for Updates…** offer the same thing. **Update Now** downloads the release and checks that it's signed by the same developer. It then replaces the app (moving it into Applications if it was running from a disk image) and restarts Tandem, and the other Mac reconnects by itself. Tandem checks every six hours; turn that off in Settings › General › Updates.

Releases live in the private GitHub repository, so each Mac needs read access to it. It's automatic when the [GitHub CLI](https://cli.github.com) is signed in on that Mac (`brew install gh && gh auth login`). Otherwise, paste a fine-grained access token with read-only **Contents** access to the repository in Settings › General › Updates.

### Global shortcuts (defaults — change them in Settings › Shortcuts)

| Mac | Shortcut | Action |
|---|---|---|
| Source | ⌃⌥S | Send snapshot |
| Source | ⌃⌥N | Send snapshot with note… |
| Source | ⌃⌥P | Pause / resume sharing |
| Studio | ⌃⌥Space | Capture & ask |
| Studio | ⌃⌥C | Capture to composer |
| Studio | ⌃⌥A | Toggle auto-capture |
| Studio | ⌃⌥F | Answer the follow-up (runs the Follow-up skill) |
| Studio | ⌃⌥L | Listen to the shared Mac's audio (on/off) |
| Both | ⌃⌥T | Show Tandem |

### Connections

Tandem advertises itself over Bonjour on every interface and races the available paths, preferring cables, then Wi-Fi, then peer-to-peer Wi-Fi. When the Macs share no network at all, **peer-to-peer Wi-Fi** still works as long as Wi-Fi is on. Connect the Macs with a Thunderbolt/USB-C cable for the lowest latency (macOS creates a *Thunderbolt Bridge* automatically). **Bluetooth LE** is used only when nothing else is reachable; its live view is a small, low-frame-rate preview, while snapshots still arrive at full quality.

If discovery is blocked (guest or corporate Wi-Fi with client isolation), use **+ › Connect by Address** in the Studio sidebar with the address shown in the Source's Settings › Devices (default port 47623).

## Privacy & security

- **Pairing** uses an X25519 key exchange with a commitment scheme and a 6-digit numeric comparison (as in Bluetooth LE Secure Connections): a man-in-the-middle can only succeed with probability 10⁻⁶ per attempt, and only if the user approves mismatched codes.
- **Sessions** mix a fresh ephemeral key agreement with the long-term pairing key (forward secrecy, mutual authentication) and protect every record with ChaCha20-Poly1305; replayed, reordered or modified data is rejected.
- **Keys** — pairing keys and API keys — are stored in the Keychain. Unpair a Mac any time in Settings › Devices.
- **Claude Code** answers run the `claude` command on the Studio Mac with its tools, plugins, hooks, MCP servers and CLAUDE.md files turned off, and Tandem's instructions in place of Claude Code's own. Nothing is saved to Claude Code's session history. Tandem never sees your Claude sign-in; the CLI uses its own.
- **Not sandboxed.** Tandem runs outside the App Sandbox so it can use your installed Claude Code and its sign-in. It is signed with the hardened runtime, and still asks macOS for camera, screen recording and local network access.
- **Capture** only runs while a paired Studio is actually watching (and never while paused or locked). macOS shows its screen-recording indicator whenever capture is active.
- **Audio** is captured only while a paired Studio has **Listen** on, and never while sharing is paused or the shared Mac is locked. It travels over the same encrypted session and is transcribed on the Studio Mac; no audio is recorded, saved or sent to the AI. Only the transcript text goes along with your questions, and it's saved with the thread like the rest of the conversation.
- **Screenshots** are sent only to the AI provider you configured, directly from the Studio Mac (through Claude Code when that's the provider). By default they are kept **in memory only**; turn on Settings › Privacy › *Keep screenshots after quitting* to keep them with history. Threads older than your retention setting are deleted automatically.
- Tandem has no servers, accounts, analytics or telemetry.

## Troubleshooting

- **The other Mac doesn't appear.** Make sure Tandem is open on both Macs with opposite roles, that Local Network access is allowed (System Settings › Privacy & Security › Local Network), and that Wi-Fi is on. Try a cable or Connect by Address.
- **"Screen Recording permission is needed."** Enable Tandem in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen Tandem on the shared Mac.
- **"The pairing is no longer valid."** One Mac was reset or unpaired. Pair again from the Studio.
- **Live view is off / paused.** The Studio pauses the stream while its window is hidden, and the Source pauses while it's locked or paused — snapshots and asking still work whenever the Source is sharing.
- **AI errors.** Check the key in Settings › AI (the **Test** button lists your available models). Rate limits and overloads show a retry option on the message.
- **Listen shows no words.** The caption says what's missing. The shared Mac may need an update, have audio sharing turned off, be paused or locked, or be missing Screen & System Audio Recording permission. If it says *Waiting for sound*, nothing is playing on the shared Mac. On macOS 14–15, allow Tandem in System Settings › Privacy & Security › Speech Recognition.

## Building from source

```bash
brew install xcodegen
scripts/test_all.sh          # core tests (380+) + app build with warnings as errors + app tests
open App/Tandem.xcodeproj     # after scripts/test_all.sh or `cd App && xcodegen generate`
scripts/build-release.sh     # signed Release build → dist/Tandem-<version>.zip and .dmg
scripts/release.sh minor     # new version: bump, test, build, tag, push, GitHub release
```

Every release gets a higher version and build number. `scripts/release.sh [patch|minor|major] ["notes"]` bumps both in `App/project.yml`, runs all tests, builds, commits and tags `vX.Y.Z`, pushes, and publishes a GitHub release with the zip and disk image. It also adds the notes, dated, to the top of the [Update log](#update-log) below. Without notes, it uses the commit subjects since the last release. That release is what **Update Now** installs.

For public distribution, sign with a **Developer ID Application** certificate (set `CODE_SIGN_IDENTITY` in `App/project.yml`) and notarize; the default Apple Development signing is for running on your own Macs.

The project uses a SwiftPM package (`Core/`: `TandemCore` + `TandemUI`) consumed by an XcodeGen-generated app target (`App/`). Run `xcodegen generate` in `App/` after adding files. Signing uses the Apple Development team configured in `App/project.yml`; notarize release builds with `xcrun notarytool`.

### Developing on one Mac

`scripts/dev-two-macs.sh --mock-ai` starts a Source and a Studio side by side (isolated profiles via `-TandemProfile`), pairs them automatically over loopback, streams a synthetic test pattern (no Screen Recording permission needed), and points the Studio at a local mock of the Claude streaming API (`scripts/mock_ai_server.py`). Debug builds accept commands for automated checks:

```bash
swift scripts/debug-command.swift B ask "What's on my screen?"   # Studio asks with a live snapshot
swift scripts/debug-command.swift A push "Why is this red?"      # Source pushes a snapshot with a note
swift scripts/debug-command.swift B auto 5                       # auto-capture every 5 s
swift scripts/debug-command.swift B dump                         # log engine state (log show --predicate 'category == "Debug"')
swift scripts/debug-command.swift B listen on                    # transcribe the Source's audio
swift scripts/debug-command.swift B skill 3                      # press Follow-up
swift scripts/debug-command.swift B transcript                   # log the live transcript
swift scripts/debug-command.swift B lastAnswer                   # log the last question, its transcript and the answer
```

To exercise listening without Screen Recording permission, give the Source a sound file to play in a loop as its "computer audio": `TANDEM_TEST_AUDIO=~/clip.aiff scripts/dev-two-macs.sh --mock-ai` (make one with `say -o ~/clip.aiff "…"`). Each question logs how long every step took (`log show --info --predicate 'category == "Chat"' | grep TANDEM-TIMING`).

None of the debug hooks are compiled into Release builds. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PROTOCOL.md](docs/PROTOCOL.md) for the design.

## Update log

Newest first. Each version is also published, with its download, on the repository's [Releases](https://github.com/RephaelCongmon/tandem/releases) page, and **Update Now** in the app installs it.

<!-- update-log:start -->
### 1.3.0 — September 29, 2026

- **Listen:** the shared Mac's computer audio (a meeting or call) is transcribed live on this Mac, on-device, about a second behind. Live captions sit above the skill buttons, and the full transcript is a click away.
- **Follow-up** now finds the question someone just asked out loud (or on screen), shows it as understood, and answers it. Every question carries what was said since the previous one, so the AI keeps the whole conversation in mind.
- **Faster answers with Claude Code:** each thread keeps a live session, and a spare is started ahead of time. First words now arrive about 1.5–2.5 s after you ask.
- **New shortcuts:** ⌃⌥F answers the follow-up and ⌃⌥L turns Listen on or off, from any app. ⌥⌘L works in the Capture menu.
- **New settings:** Settings › Listening (language, how much transcript to send, captions). On the shared Mac, Settings › Sharing › Audio.
- **Fixed:** on Bluetooth links, data sent just before the other Mac closed the connection could be lost.
- Listen needs this version on **both** Macs, so update the shared Mac too.

### 1.2.0 — September 29, 2026

- **Skills:** one-click buttons above the message field. **Debug**, **New Problem** and **Follow-up** each send a fresh screenshot with detailed instructions for that kind of question, and anything you've typed goes along as extra context.
- Add, edit and reorder skills in **Settings › Skills**. ⌘1–⌘9 send the first nine.

### 1.1.2 — September 29, 2026

- Opening Tandem always opens the copy in Applications, even on a Mac that also has a development build.

### 1.1.1 — September 29, 2026

- Updates now show as an **Update** button in the toolbar, with what's new, **Later** and **Update Now**, so they no longer cover the chat header.

### 1.1.0 — September 29, 2026

- **Update Now:** Tandem can now update itself from the toolbar, the menu bar, or Tandem › Check for Updates…
- **Claude Code on your subscription** is the default way to ask Claude, with no API key.
- **Reasoning level** can be changed from the chat, under the message field.
- The sharing Mac can run unattended in the menu bar and starts quietly at login.

### 1.0.0 — September 29, 2026

- First version: pair two Macs with a 6-digit code, see the other Mac's screen live over Wi-Fi, a cable or Bluetooth, and ask Claude or OpenAI about it in a conversation thread.
- Annotate, crop and redact screenshots before sending; capture on demand, with global shortcuts, or automatically on a schedule.
<!-- update-log:end -->
