# Tandem

**Two Macs, one conversation.** Tandem pairs two nearby Macs. One Mac (the **Source**) streams its screen, a window, or its camera to the other (the **Studio**) in real time. The Studio sends snapshots of that screen — with your own context, markup and redactions — to **Claude** or **OpenAI**, and shows the answers as a conversation thread.

It's built for moments like: your work laptop can't run AI tools but your personal one can; a demo or rehearsal where a second Mac watches and advises; a long-running job you want summarized every few minutes; or simply keeping the AI conversation off the screen you're working on.

## Highlights

- **Real-time live view.** Hardware H.264 with low-latency rate control, ack-based flow control that bounds queuing to about one round trip, and adaptive bitrate, at 1080p/30–60 fps. The live HUD shows measured capture-to-display latency; two instances on one Mac measured **8–20 ms**, and between Macs you add your link's round-trip time (a cable or good Wi-Fi keeps it in the tens of milliseconds).
- **Any link.** Wi-Fi/LAN, **peer-to-peer Wi-Fi** (no shared network needed — like AirDrop), **Thunderbolt/Ethernet cable**, or **Bluetooth LE** as a last resort. Tandem picks the best automatically and shows which one is in use.
- **Ask Claude or OpenAI.** Streaming answers with Markdown, code blocks, tables and an optional reasoning summary. Claude Opus 5.5 by default (Fable 5.1, Sonnet 5.5, Haiku 4.5 available); OpenAI GPT‑6 Astra/Sol/Luna; or any OpenAI-compatible server (LM Studio, Ollama, vLLM).
- **Your context, your way.** Type a question; attach a fresh screenshot automatically; annotate it first (boxes, arrows, pen, highlight, text), **crop** to what matters and **redact** anything private before it leaves the Mac.
- **On demand, by shortcut, or on a schedule.** Global shortcuts on both Macs, a "send with note" panel on the Source, and auto-capture every N seconds — optionally only when the screen actually changed (detected on the Source, so unchanged screens aren't even sent), with an hourly cap.
- **Answers on both Macs.** Replies can be mirrored back to the Source's window and menu bar.
- **Private by design.** Pairing is confirmed with a 6-digit code; every session is end-to-end encrypted and mutually authenticated. Screenshots go only to the AI provider you choose, with your own key, and stay in memory unless you opt to keep them.

## Requirements

- Two Macs running **macOS 14 Sonoma or later** (Liquid Glass chrome on macOS 26).
- An API key for Anthropic or OpenAI (or a local OpenAI-compatible server) on the Studio Mac.

## Getting started

1. Install Tandem on both Macs and open it.
2. On the Mac you want to see, choose **Share this Mac**. Allow **Screen Recording** when macOS asks (System Settings › Privacy & Security › Screen & System Audio Recording) and approve **Local Network** access.
3. On the other Mac, choose **Ask from this Mac**, add your API key, and pick the first Mac from the list.
4. Both Macs show the same 6-digit code. Confirm it matches and click **Allow** on the shared Mac. That's it — from now on the Macs reconnect automatically.

### Using it

**On the Studio (asking) Mac**
- The left panel is the live view; the right panel is the conversation. Double-click the live view (or the ⤢ button) for focus mode.
- Type a question and press ↩. With **Live screen** on, a fresh screenshot is attached when you send.
- Press the capture button (or ⇧⌘S) to grab a screenshot into the composer, then click it to **annotate, crop or redact** before sending.
- **Ask** (⇧⌘↩) captures and asks in one step using your typed text or the default prompt. Quick prompts live behind the ✦ menu.
- The ⏱ control turns on **auto-capture** and sets the interval; the menu also chooses whether each capture asks the AI or just updates the composer, and whether to skip unchanged screens.
- The toolbar model menu switches provider, model and reasoning effort.
- The **Source** menu on the live view lets you choose which display, window or camera the other Mac shares (if it allows that).

**On the Source (shared) Mac**
- The window shows exactly what's being shared, who's watching, and over which link.
- **Send Snapshot** (⌃⌥S from any app) pushes a screenshot; **Send with Note…** (⌃⌥N) opens a small panel to add context first. The answer appears on the Studio and, optionally, on this Mac too.
- **Pause** (⌃⌥P) stops all capture instantly. Sharing also pauses automatically while the Mac is locked.

### Global shortcuts (defaults — change them in Settings › Shortcuts)

| Mac | Shortcut | Action |
|---|---|---|
| Source | ⌃⌥S | Send snapshot |
| Source | ⌃⌥N | Send snapshot with note… |
| Source | ⌃⌥P | Pause / resume sharing |
| Studio | ⌃⌥Space | Capture & ask |
| Studio | ⌃⌥C | Capture to composer |
| Studio | ⌃⌥A | Toggle auto-capture |
| Both | ⌃⌥T | Show Tandem |

### Connections

Tandem advertises itself over Bonjour on every interface and races the available paths, preferring cables, then Wi-Fi, then peer-to-peer Wi-Fi. When the Macs share no network at all, **peer-to-peer Wi-Fi** still works as long as Wi-Fi is on. Connect the Macs with a Thunderbolt/USB-C cable for the lowest latency (macOS creates a *Thunderbolt Bridge* automatically). **Bluetooth LE** is used only when nothing else is reachable; its live view is a small, low-frame-rate preview, while snapshots still arrive at full quality.

If discovery is blocked (guest or corporate Wi-Fi with client isolation), use **+ › Connect by Address** in the Studio sidebar with the address shown in the Source's Settings › Devices (default port 47623).

## Privacy & security

- **Pairing** uses an X25519 key exchange with a commitment scheme and a 6-digit numeric comparison (as in Bluetooth LE Secure Connections): a man-in-the-middle can only succeed with probability 10⁻⁶ per attempt, and only if the user approves mismatched codes.
- **Sessions** mix a fresh ephemeral key agreement with the long-term pairing key (forward secrecy, mutual authentication) and protect every record with ChaCha20-Poly1305; replayed, reordered or modified data is rejected.
- **Keys** — pairing keys and API keys — are stored in the Keychain. Unpair a Mac any time in Settings › Devices.
- **Capture** only runs while a paired Studio is actually watching (and never while paused or locked). macOS shows its screen-recording indicator whenever capture is active.
- **Screenshots** are sent only to the AI provider you configured, directly from the Studio Mac. By default they are kept **in memory only**; turn on Settings › Privacy › *Keep screenshots after quitting* to keep them with history. Threads older than your retention setting are deleted automatically.
- Tandem has no servers, accounts, analytics or telemetry.

## Troubleshooting

- **The other Mac doesn't appear.** Make sure Tandem is open on both Macs with opposite roles, that Local Network access is allowed (System Settings › Privacy & Security › Local Network), and that Wi-Fi is on. Try a cable or Connect by Address.
- **"Screen Recording permission is needed."** Enable Tandem in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen Tandem on the shared Mac.
- **"The pairing is no longer valid."** One Mac was reset or unpaired. Pair again from the Studio.
- **Live view is off / paused.** The Studio pauses the stream while its window is hidden, and the Source pauses while it's locked or paused — snapshots and asking still work whenever the Source is sharing.
- **AI errors.** Check the key in Settings › AI (the **Test** button lists your available models). Rate limits and overloads show a retry option on the message.

## Building from source

```bash
brew install xcodegen
scripts/test_all.sh          # core tests (300+) + app build with warnings as errors
open App/Tandem.xcodeproj     # after scripts/test_all.sh or `cd App && xcodegen generate`
scripts/build-release.sh     # signed Release build → dist/Tandem-<version>.zip and .dmg
```

For public distribution, sign with a **Developer ID Application** certificate (set `CODE_SIGN_IDENTITY` in `App/project.yml`) and notarize; the default Apple Development signing is for running on your own Macs.

The project uses a SwiftPM package (`Core/`: `TandemCore` + `TandemUI`) consumed by an XcodeGen-generated app target (`App/`). Run `xcodegen generate` in `App/` after adding files. Signing uses the Apple Development team configured in `App/project.yml`; notarize release builds with `xcrun notarytool`.

### Developing on one Mac

`scripts/dev-two-macs.sh --mock-ai` starts a Source and a Studio side by side (isolated profiles via `-TandemProfile`), pairs them automatically over loopback, streams a synthetic test pattern (no Screen Recording permission needed), and points the Studio at a local mock of the Claude streaming API (`scripts/mock_ai_server.py`). Debug builds accept commands for automated checks:

```bash
swift scripts/debug-command.swift B ask "What's on my screen?"   # Studio asks with a live snapshot
swift scripts/debug-command.swift A push "Why is this red?"      # Source pushes a snapshot with a note
swift scripts/debug-command.swift B auto 5                       # auto-capture every 5 s
swift scripts/debug-command.swift B dump                         # log engine state (log show --predicate 'category == "Debug"')
```

None of the debug hooks are compiled into Release builds. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PROTOCOL.md](docs/PROTOCOL.md) for the design.
