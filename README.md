# Tandem

**Two Macs, one conversation.** Tandem pairs two nearby Macs. One Mac (the **Source**) streams its screen, a window, or its camera to the other (the **Studio**) in real time. The Studio sends snapshots of that screen — with your own context, markup and redactions — to **Claude** or **OpenAI's GPT models**, and shows the answers as a conversation thread. It can also **listen**: the Source's computer audio (a meeting or call) is transcribed live on the Studio, so a question someone asks out loud can be answered with one click.

It's built for moments like: your work laptop can't run AI tools but your personal one can; a demo or rehearsal where a second Mac watches and advises; a long-running job you want summarized every few minutes; or simply keeping the AI conversation off the screen you're working on.

## Highlights

- **Real-time live view.** Hardware H.264 with low-latency rate control, ack-based flow control that bounds queuing to about one round trip, and adaptive bitrate, at 1080p/30–60 fps. The live HUD shows measured capture-to-display latency; two instances on one Mac measured **8–20 ms**, and between Macs you add your link's round-trip time (a cable or good Wi-Fi keeps it in the tens of milliseconds).
- **Any link.** Wi-Fi/LAN, **peer-to-peer Wi-Fi** (no shared network needed — like AirDrop), **Thunderbolt/Ethernet cable**, or **Bluetooth LE** as a last resort. Tandem picks the best automatically and shows which one is in use.
- **Ask Claude or OpenAI.** Streaming answers with Markdown, code blocks, tables and an optional reasoning summary. By default Tandem asks Claude through **Claude Code on your Claude subscription**, with no API key. Claude Opus 5.5 is the default (Fable 5.1, Sonnet 5.5 and Haiku 4.5 are available). Or use **Codex on your ChatGPT subscription**, also with no API key, for GPT-6.1 Sol (default), GPT-6 Astra, Sol and Luna, and whatever else your plan offers. An Anthropic or OpenAI API key (GPT‑6 Astra/Sol/Luna), or any OpenAI-compatible server (LM Studio, Ollama, vLLM), also works.
- **Your context, your way.** Drag over the live view to pick exactly the parts of the screen you mean, as many as you like in a row, or ask with no pictures. The shared Mac sends only the selected region at full quality. Annotate it (boxes, arrows, pen, highlight, text), **crop** further or **redact** before sending it to AI.
- **On demand, by shortcut, or on a schedule.** Global shortcuts on both Macs, a "send with note" panel on the Source, and auto-capture every N seconds — optionally only when the screen actually changed (detected on the Source, so unchanged screens aren't even sent), with an hourly cap.
- **Hears the meeting, too.** Turn on **Listen** and the Source's computer audio streams to the Studio (Opus, about 30 kbps) and is transcribed on-device as it's spoken, about a second behind, by NVIDIA's **Parakeet** model on the Neural Engine (about a quarter fewer mistakes than Apple's recognizer on conversation). **Follow-up** finds the question just asked out loud, or on screen, and answers it in a few plain sentences. The transcript also goes with every other question, so the AI knows what's being discussed.
- **Remembers the conversation.** With Claude Code, each thread keeps a live session, so a follow-up sends only what's new and starts answering sooner. Earlier questions, answers, screenshots and transcripts stay in context.
- **Answers on both Macs.** Replies can be mirrored back to the Source's window and menu bar.
- **Private by design.** Pairing is confirmed with a 6-digit code; every session is end-to-end encrypted and mutually authenticated. Screenshots go only to the AI provider you choose, on your own subscription or key, and stay in memory unless you opt to keep them.

## Requirements

- Two Macs running **macOS 14 Sonoma or later** (Liquid Glass chrome on macOS 26).
- On the Studio Mac, one of:
  - [Claude Code](https://claude.com/claude-code), installed and signed in with your Claude account (run `claude` once in Terminal). This is the default, and questions count toward your Claude plan's usage.
  - [Codex](https://chatgpt.com/codex), installed (`brew install --cask codex`) and signed in with your ChatGPT account (`codex login`). Questions count toward your ChatGPT plan's usage.
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
- Type a question and press ↩. Sending a question or pressing a skill never takes a new screenshot.
- Click **Select region** (or ⇧⌘S) to turn on the region tool, then drag over the live view. The frame holds still while you drag, and when you let go that part of the shared screen lands in the composer at full resolution. Keep dragging to add more; **Whole Screen** adds the entire frame, and **Done** (esc, or ⇧⌘S again) turns the tool off. Until you drag, no picture is selected. Both Macs need Tandem 1.6.1 or later for regions (this version on the shared Mac makes them instant).
- Remove any thumbnail with ×, or click it to **annotate, crop or redact**. The picture chip chooses **Use on send** or **Excluded from send**; excluded pictures remain in the composer for later.
- **Ask** (⇧⌘↩) sends your text and selected pictures. Quick prompts live behind the ✦ menu.
- The ⏱ control turns on **auto-capture** and sets the interval; the menu also chooses whether each capture asks the AI or just updates the composer, and whether to skip unchanged screens.
- **Skills** are one-click buttons above the message field: **Debug**, **New Problem** and **Follow-up** to start with. Each uses your selected pictures when **Use on send** is on, what was just said (when **Listen** is on), that skill's instructions, and your typed context. With no selected pictures it sends no new screenshot. The thread shows just the skill's name. ⌘1–⌘9 trigger the first nine. Add, edit and reorder skills in Settings › Skills, or with the ⚙ button next to them.
- **Listen** (in the composer, or ⌥⌘L) transcribes the shared Mac's computer audio. See [Listening](#listening-to-the-shared-macs-audio).
- The toolbar model menu switches provider, model and reasoning effort. The **Reasoning** chip under the message field changes the reasoning level (Fast, Balanced, Thorough, Deep, Maximum) from your next question on, offering only the levels the current model supports.
- The **Source** menu on the live view lets you choose which display, window or camera the other Mac shares (if it allows that).

**On the Source (shared) Mac**
- The window shows exactly what's being shared, who's watching, and over which link.
- **Send Snapshot** (⌃⌥S from any app) pushes a screenshot; **Send with Note…** (⌃⌥N) opens a small panel to add context first. The answer appears on the Studio and, optionally, on this Mac too.
- **Pause** (⌃⌥P) stops all capture instantly. Sharing also pauses automatically while the Mac is locked.

### Listening to the shared Mac's audio

Turn on **Listen** in the composer, or press ⌥⌘L. The shared Mac starts sending what it plays: the other people on a call, a video, anything but Tandem's own sounds and its microphone. The Studio transcribes it on-device. A two-line live caption above the skill buttons shows the words about a second after they're spoken. Next to it, **✓ Captured** means the speaker paused and everything said so far is in the transcript, so it will go with your next question. **Transcribing…** means the last words are still being recognized; pressing Follow-up then waits a moment for them. The ❝ button next to it opens the whole transcript, with timestamps, **Copy** and **Clear**.

When someone asks you something out loud, press **Follow-up** (⌘3 in Tandem, or ⌃⌥F from any app). It sends the transcript, your selected pictures when **Use on send** is on, and the conversation so far. The answer starts with the question as Claude understood it, in italics with obvious speech-to-text mistakes fixed, followed by a direct answer in a few sentences. If you press it while the last words are still being recognized, Tandem waits a moment (up to 0.8 s) for them.

- Each question carries what was said **since the thread's previous question**, up to 10 minutes (Settings › Listening › At most). Earlier transcripts stay with their messages, so later questions keep the whole conversation in mind. Each sent message shows a **Transcript · N words** chip you can expand.
- Every question gets the transcript, not just Follow-up. Turn it off per skill in the skill's editor, or entirely in Settings › Listening.
- **Speed:** a question asked in a thread that already has answers typically starts streaming about 1.5–2 s after you click, and the first question of a thread in about 2–2.5 s.
- **Speech recognition:** English is transcribed by **Parakeet TDT 0.6B v2** (NVIDIA, through FluidAudio on the Neural Engine). It's downloaded once, to the asking Mac only (451 MB, from Tandem's own GitHub releases, or from Hugging Face if this Mac can't reach them), in the background right after Tandem starts, so it's ready before you need it. Settings › Listening shows it and can remove it. On real conversational audio (earnings calls) it made 14.4% word errors against Apple's 19.7%, and it runs about 90× faster than real time. Other languages, or **Apple — built in** in Settings › Listening, use Apple's recognizer (SpeechAnalyzer on macOS 26; on macOS 14–15 it asks for Speech Recognition permission once).
- **Names and terms:** list people, companies and jargon in Settings › Listening › Vocabulary. They go along with the transcript, so the AI spells them right when speech-to-text mishears them.
- **Language:** Settings › Listening › Language (default: this Mac's).
- **Nothing to set up on the shared Mac.** Audio uses the same Screen & System Audio Recording permission as the picture. It runs only while the Studio listens, sharing is on and the Mac is unlocked. The shared Mac's window shows **Hearing this Mac's audio** under that Studio, and macOS shows its own recording indicator. To never send audio, turn off Settings › Sharing › *Let the other Mac hear this Mac's audio* on the shared Mac.
- Both Macs need Tandem 1.3 or later. If the shared Mac is older, the caption says so; update it there with **Update Now** once. From 1.4 on, the asking Mac keeps it up to date for you (see [Updates](#updates)).

### Leaving the shared Mac alone

The Source never needs attention after pairing. Close its window and Tandem keeps listening from the menu bar; turn on **Settings › General › Open at login** and it starts that way after every login, with no window. When the Studio connects or reconnects (after Wi-Fi drops, sleep, or either app restarting), nothing appears on the shared Mac and it never takes focus. macOS shows its own screen-recording indicator in the menu bar while the screen is being captured.

The only things that put a prompt on the shared Mac are pairing a new Mac (or pairing again after one side forgot the other), and **Ask before each session** if you turn it on in Settings › Sharing. The window then comes forward with the prompt, without taking keyboard focus from the app in use.

### Updates

When a new version is published, an **Update** button appears in the window's toolbar. It opens what's new in that version, with **Later** and **Update Now**. The menu bar popover and **Tandem › Check for Updates…** offer the same thing. **Update Now** downloads the release and checks that it's signed by the same developer. It then replaces the app (moving it into Applications if it was running from a disk image) and restarts Tandem, and the other Mac reconnects by itself. Tandem checks every six hours; turn that off in Settings › General › Updates.

**The shared Mac updates itself from the asking Mac.** When the shared Mac connects with an older version, the asking Mac sends it its own copy of Tandem over the encrypted link. The shared Mac installs it only if it's the same app, a newer version, and signed by the same developer; then it restarts and reconnects, all in about 3 seconds. So **Update Now on the asking Mac updates both Macs**, and the shared Mac never needs GitHub access or an AirDropped disk image. (A shared Mac on 1.3 or earlier needs one last manual update to 1.4.) Turn it off with Settings › General › *Keep the shared Mac up to date* (asking Mac) or *Install updates sent by the other Mac* (shared Mac); over Bluetooth it's only done when you click **Update It Now**.

Releases are public at [github.com/RephaelCongmon/tandem/releases](https://github.com/RephaelCongmon/tandem/releases), so any Mac can check for and install updates with no sign-in. If the [GitHub CLI](https://cli.github.com) is signed in, or an access token is saved in Settings › General › Updates, Tandem uses that instead. That's only needed for a private fork, or to raise GitHub's rate limit (60 requests an hour per network without sign-in, far more than the six-hourly checks use).

### Global shortcuts (defaults — change them in Settings › Shortcuts)

| Mac | Shortcut | Action |
|---|---|---|
| Source | ⌃⌥S | Send snapshot |
| Source | ⌃⌥N | Send snapshot with note… |
| Source | ⌃⌥P | Pause / resume sharing |
| Studio | ⌃⌥Space | Ask with selected pictures |
| Studio | ⌃⌥C | Select region (turns the region tool on or off) |
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
- **Codex** answers run `codex app-server` on the Studio Mac with no tools (no shell, code execution, browser, apps, image generation or web search), with your plugins and MCP servers turned off, and with Tandem's instructions in place of Codex's own. Every conversation is an ephemeral, read-only thread that isn't saved to Codex's history. Codex still reads your `~/.codex/AGENTS.md`, which can't be turned off in this mode. Tandem never sees your ChatGPT sign-in; Codex uses its own.
- **Claude Code** answers run the `claude` command on the Studio Mac with its tools, plugins, hooks, MCP servers and CLAUDE.md files turned off, and Tandem's instructions in place of Claude Code's own. Nothing is saved to Claude Code's session history. Tandem never sees your Claude sign-in; the CLI uses its own.
- **Not sandboxed.** Tandem runs outside the App Sandbox so it can use your installed Claude Code and its sign-in. It is signed with the hardened runtime, and still asks macOS for camera, screen recording and local network access.
- **Capture** only runs while a paired Studio is actually watching (and never while paused or locked). macOS shows its screen-recording indicator whenever capture is active.
- **Updates between the Macs** travel only over the paired, encrypted session, only from a Studio this Mac approved, and are installed only when they're a newer version signed by the same developer team (checked with the code signature, like **Update Now**).
- **Audio** is captured only while a paired Studio has **Listen** on, and never while sharing is paused or the shared Mac is locked. It travels over the same encrypted session and is transcribed on the Studio Mac; no audio is recorded, saved or sent to the AI. Only the transcript text goes along with your questions, and it's saved with the thread like the rest of the conversation.
- **Screenshots** are sent only to the AI provider you configured, directly from the Studio Mac (through Claude Code when that's the provider). By default they are kept **in memory only**; turn on Settings › Privacy › *Keep screenshots after quitting* to keep them with history. Threads older than your retention setting are deleted automatically.
- Tandem has no servers, accounts, analytics or telemetry.

## Troubleshooting

- **The other Mac doesn't appear.** Make sure Tandem is open on both Macs with opposite roles, that Local Network access is allowed (System Settings › Privacy & Security › Local Network), and that Wi-Fi is on. Try a cable or Connect by Address.
- **"macOS isn't letting Tandem use the local network."** macOS sometimes keeps blocking an app after it updates, even though System Settings shows it allowed. Click **Open Settings** (Privacy & Security › Local Network), switch Tandem off and back on, and Tandem reconnects by itself.
- **"Tandem on it isn't answering."** The other Mac took the connection but Tandem there didn't respond. Quit and reopen Tandem on that Mac. Versions before 1.5.1 stopped answering after a few reconnects (for example after sleep); reopening once fixes it, and the Studio then updates it.
- **"Screen Recording permission is needed."** Enable Tandem in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen Tandem on the shared Mac.
- **"The pairing is no longer valid."** One Mac was reset or unpaired. Pair again from the Studio.
- **Live view is off / paused.** The Studio pauses the stream while its window is hidden, and the Source pauses while it's locked or paused — snapshots and asking still work whenever the Source is sharing.
- **Codex says it isn't signed in.** Run `codex login` in Terminal and choose ChatGPT, then **Check Again** in Settings › AI. If it's signed in with an API key instead, questions are billed to that key.
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
swift scripts/debug-command.swift B ask "What's on my screen?"   # Studio asks with the prepared pictures, if any
swift scripts/debug-command.swift A push "Why is this red?"      # Source pushes a snapshot with a note
swift scripts/debug-command.swift B auto 5                       # auto-capture every 5 s
swift scripts/debug-command.swift B dump                         # log engine state (log show --predicate 'category == "Debug"')
swift scripts/debug-command.swift B listen on                    # transcribe the Source's audio
swift scripts/debug-command.swift B skill 3                      # press Follow-up
swift scripts/debug-command.swift B transcript                   # log the live transcript
swift scripts/debug-command.swift B lastAnswer                   # log the last question, its transcript and the answer
swift scripts/debug-command.swift A drop                         # cut every link without a goodbye, like sleep
swift scripts/debug-command.swift B localNetwork denied          # show the blocked-network state (allowed ends it)
```

Development builds usually show the local-network banner: macOS doesn't recognize each new build, though the two instances still reach each other on the same Mac.

The live Parakeet test (`ParakeetLiveTests`) runs when `TANDEM_PARAKEET_MODELS` points at a folder holding `parakeet-tdt-0.6b-v2`; `scripts/test_all.sh` finds the app's downloaded model by itself. Development builds only update each other with `-TandemPeerUpdates YES`.

To exercise listening without Screen Recording permission, give the Source a sound file to play in a loop as its "computer audio": `TANDEM_TEST_AUDIO=~/clip.aiff scripts/dev-two-macs.sh --mock-ai` (make one with `say -o ~/clip.aiff "…"`). Each question logs how long every step took (`log show --info --predicate 'category == "Chat"' | grep TANDEM-TIMING`).

None of the debug hooks are compiled into Release builds.

### Credits

Speech recognition uses [Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) by NVIDIA (CC-BY-4.0), in the [Core ML conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) by FluidInference (CC-BY-4.0), run with [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0). Tandem mirrors the model files unchanged in its `speech-models-1` release. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PROTOCOL.md](docs/PROTOCOL.md) for the design.

## Update log

Newest first. Each version is also published, with its download, on the repository's [Releases](https://github.com/RephaelCongmon/tandem/releases) page, and **Update Now** in the app installs it.

<!-- update-log:start -->
### 1.6.2 — September 30, 2026

- **One-step Select region.** Click **Select region** (⇧⌘S) once and it becomes a tool. Drag over the live view, and when you let go that part of the shared screen is in the composer at full resolution, a fraction of a second later. Keep dragging to add more; **Whole Screen** adds the entire frame; **Done** (esc) turns the tool off.
- The frame holds still while you drag, so you get exactly what you selected. If the shared screen changed in that moment, its own picture replaces the frozen frame before you let go.
- Pictures are instant when both Macs run 1.6.2. A shared Mac still on 1.6.1 works too, a little slower, so update it as well.

### 1.6.1 — September 30, 2026

- **Deliberate pictures.** Sending a question, **Ask** or a skill no longer takes a screenshot. Only the pictures you pick go to the AI.
- **Select region** (⇧⌘S) freezes a frame of the shared screen. Drag over what matters, then click **Add region**. The shared Mac sends just that region, at full quality, cropped from the frozen frame. **Retake** gets a new frame; **Cancel** adds nothing.
- Select again to add several pictures. Remove one with ×, or click it to annotate, crop or redact. The picture chip switches between **Use on send** and **Excluded from send**; excluded pictures stay in the composer for later.
- Both Macs need 1.6.1 to select regions.

### 1.5.2 — September 30, 2026

- **The local network warning now works:** 1.5.1 checked the wrong address (your router, which macOS always allows), so it missed the block macOS can apply after an update. Tandem now checks a host macOS actually blocks, shows the banner with **Open Settings**, and reconnects by itself once you switch Tandem off and back on under Privacy & Security › Local Network.

### 1.5.1 — September 30, 2026

- **Reconnects after sleep, every time:** the shared Mac used to stop answering after a handful of reconnects (for example after its lid closed a few times), until Tandem was reopened on it. It now takes every reconnect. If your shared Mac is on an older version, quit and reopen Tandem on it once; the Studio then updates it.
- **Says when macOS blocks the local network:** after an update, macOS sometimes keeps Tandem off the local network even though Privacy & Security › Local Network shows it allowed. Tandem now notices, shows a banner with a button that opens that setting (switch Tandem off and back on), and reconnects by itself once it's fixed.
- Clearer messages when the other Mac takes the connection but Tandem on it doesn't answer, or when it can't be reached.

### 1.5.0 — September 30, 2026

- **Codex on your ChatGPT subscription:** pick **Codex — your ChatGPT subscription** in Settings › AI to ask GPT-6.1 Sol, GPT-6 Astra and the other models your plan offers. It works through the Codex app on this Mac, with no API key, just like Claude Code.
- It works the same as Claude: screenshots, the live transcript, skills, reasoning levels, and follow-ups that remember the conversation.
- **Safety:** Codex runs with no tools, plugins, MCP servers or web search. Conversations are private and aren't saved to Codex's history.
- Settings shows whether Codex is signed in with ChatGPT, and lists your account's models.

### 1.4.2 — September 30, 2026

- **Updates without signing in:** Tandem's releases are now public, so any Mac checks for and installs updates on its own. No GitHub CLI or token needed.
- **Captured badge:** next to the live caption, ✓ Captured shows once the speaker has paused and everything said is in the transcript. Transcribing… shows while the last words are still being recognized.
- **Fixed:** in long stretches of speech, a few words could appear twice in the transcript.

### 1.4.1 — September 30, 2026

- **Smaller download:** the app is about a third smaller. It leaves out a text-normalization library that transcription doesn't use.

### 1.4.0 — September 29, 2026

- **More accurate transcripts:** Listen now uses NVIDIA's Parakeet model on the Neural Engine. On real conversation it made about a quarter fewer mistakes than Apple's recognizer (14.4% vs 19.7% word errors), and it gets names and jargon right more often. The model (451 MB) downloads once, in the background, to the asking Mac only.
- **The shared Mac updates itself:** after Update Now on the asking Mac, it sends the new version to the shared Mac over the encrypted link. The shared Mac checks it's signed by the same developer, installs it and restarts, in about 3 seconds. No AirDrop and no GitHub access needed there. (Update the shared Mac to 1.4 by hand one last time.)
- **Names and terms:** list people, companies and jargon in Settings › Listening so the AI spells them right.
- **Faster reconnects** after the shared Mac restarts: about 3 seconds instead of about 15.
- **Listen starts in a fraction of a second,** and nothing said while it starts is lost.
- Settings › Listening can switch back to Apple's recognizer. Other languages use it automatically.
- Credits: Parakeet TDT 0.6B v2 by NVIDIA (CC-BY-4.0), Core ML conversion by FluidInference, and FluidAudio (Apache-2.0).

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
