# Tandem architecture

```
┌──────────────────────── Source Mac ────────────────────────┐        ┌──────────────────────── Studio Mac ─────────────────────────┐
│ CaptureService (ScreenCaptureKit / AVFoundation / debug)    │        │ LiveVideoRenderer → AVSampleBufferDisplayLayer (link queue) │
│   └─ frames → VideoFanout ─ H264Encoder (VideoToolbox, LL)  │        │ StudioEngine: stream requests, snapshots, automation         │
│                 └─ per-viewer ack flow control              │        │ ChatController: threads, composer, AI streaming              │
│ SourceEngine: viewers, status, snapshots, pushes, lock      │        │   └─ ContextBuilder → AIClient (Anthropic/OpenAI/compatible) │
│ AudioCaptureService (SCK audio) → AudioFanout (Opus)        │        │ TranscriptionService: AudioPipeline → SpeechAnalyzer         │
│ ConnectionManager: BonjourListener + BluetoothAdvertiser    │        │ ConnectionManager: BonjourBrowser + BluetoothBrowser         │
└──────────────┬──────────────────────────────────────────────┘        └──────────────┬──────────────────────────────────────────────┘
               │  PeerLink (framing · SecureSession · priority queues · ping/RTT/clock offset)  │
               └──────────── ByteTransport: NetworkTransport (TCP: Wi-Fi, P2P Wi-Fi, Ethernet, Thunderbolt) or StreamPairTransport (BLE L2CAP) ────────┘
```

## Layout

| Path | What lives there |
|---|---|
| `Core/Sources/TandemCore/Wire` | Length-prefixed framing, binary + JSON message codec (`PeerMessage`, `ControlMessage`) |
| `Core/Sources/TandemCore/Security` | `SecureSession` handshake state machine, `RecordProtector` (ChaCha20-Poly1305), device identity, Keychain key stores |
| `Core/Sources/TandemCore/Transport` | `ByteTransport` protocol, Network.framework TCP transport, Bonjour listener/browser, link classification, Bluetooth LE L2CAP advertiser/browser/transport |
| `Core/Sources/TandemCore/Session` | `PeerLink` (one secure session), `SnapshotAssembler` |
| `Core/Sources/TandemCore/Media` | Low-latency `H264Encoder`, `VideoSampleBufferFactory`, `ImageCodec` (JPEG, thumbnails, change fingerprints), `AudioCoding` (Opus/PCM frame codec, packetizer, levels, gain) |
| `Core/Sources/TandemCore/Speech` | Live on-device transcription (`SpeechAnalyzer` on macOS 26, `SFSpeechRecognizer` before), `AudioTimeline` (audio time → wall clock) |
| `Core/Sources/TandemCore/AI` | Provider-neutral types, SSE decoder, Anthropic Messages / OpenAI Responses / Chat Completions streaming clients, the Claude Code client (runs the local `claude` CLI), its session pool and locator, model catalog |
| `Core/Sources/TandemCore/Conversation` | Thread/message models, cache-friendly `ContextBuilder`, `LiveTranscript`/`TranscriptExcerpt`, skills, `ThreadStore`, `SnapshotStore` |
| `Core/Sources/TandemCore/Markdown` | Streaming-tolerant block parser |
| `Core/Sources/TandemUI` | Design system, `MarkdownView`, snapshot markup editor + renderer, global hotkeys + recorder |
| `App/Sources` | SwiftUI app: `AppModel`, `ConnectionManager`, `SourceEngine`, `StudioEngine`, `ChatController`, views, settings, menu bar, panels |

## Threading model

- **PeerLink** state is confined to its transport's serial queue. The main-actor `PeerConnection` wraps it; `LinkRouter` (also on the link queue) reassembles snapshots and routes messages:
  - video format/frames go straight to `LiveVideoRenderer` on the link queue — no main-thread hop per frame;
  - video acks go straight to `VideoFanout` on the link queue;
  - audio packets go straight to the Studio's `AudioPipeline` queue;
  - everything else hops to the main actor in FIFO order (`DispatchQueue.main.async`, never unordered `Task`s).
- **VideoFanout** owns the encoder on its own queue. Capture writes into a one-slot mailbox, so a busy encoder always takes the newest frame.
- **Engines and views** are `@MainActor @Observable`. Only the streaming message view observes per-token updates (`StreamingReply`), which are flushed at ~30 Hz.

## Latency design

1. ScreenCaptureKit only delivers frames when pixels change (`queueDepth` 5, 420v, 709 matrix).
2. VideoToolbox encodes with **low-latency rate control**, no frame reordering, `MaxFrameDelayCount = 0`, and keyframes only on demand.
3. Each viewer acknowledges every frame. A viewer receives a new frame only while fewer than `⌈RTT / frame interval⌉ + 1` are unacknowledged; if no viewer can take one, the frame isn't encoded (no queueing, no forced keyframes). Skipped frames drive an AIMD bitrate controller.
4. The Studio enqueues sample buffers with *display immediately* into `AVSampleBufferDisplayLayer`'s renderer.
5. TCP uses `noDelay`, `.interactiveVideo` service class and short keepalives. Snapshots travel as chunks at bulk priority (ahead of video, behind control) so a capture never waits behind the stream.
6. Latency is measured end to end: frames carry the Source's wall-clock capture time, and the link's NTP-style ping exchange estimates the clock offset (lowest-RTT sample).

## Listening

1. **Source.** `AudioCaptureService` runs its own ScreenCaptureKit stream: a display filter, `capturesAudio`, 16 kHz mono and `excludesCurrentProcessAudio`, with a 2×2, 1 fps picture that's thrown away. It's separate from the video stream, so it runs whenever an approved Studio sent `audioRequest(enabled)`, whether or not anyone is watching. It stops when sharing is paused, the Mac locks, audio sharing is turned off, or the stream is stopped from the menu bar. ScreenCaptureKit delivers continuous 20 ms buffers, silence included.
2. **Wire.** `AudioFanout` encodes each listener's audio with `AVAudioConverter` Opus (32 kbps, one 20 ms frame per buffer) and sends 100 ms `audioPacket`s on the link's **audio** queue, ahead of snapshots and video. A link with 5 s of audio already queued drops new packets.
3. **Studio.** `AudioPipeline` (its own queue) decodes the packets and applies a slow automatic gain (quiet callers are lifted, silence isn't). While the recognizer loads it holds up to 30 s of audio and replays it, so nothing said right after turning on Listen is lost. English goes to `ParakeetTranscriber`: NVIDIA Parakeet TDT 0.6B v2 through FluidAudio's Core ML `AsrManager` on the Neural Engine. Parakeet reads whole clips (up to 15 s per pass), so `UtteranceSegmenter` cuts the stream at pauses using an adaptive-noise-floor voice detector. While someone speaks, the utterance so far is re-read every 0.8 s (about 80 ms for 10 s of audio) as the live caption. A 0.6 s pause, or 14 s of talk cut at its quietest moment, finishes it with a final pass. `ParakeetModelStore` installs the model (451 MB) once: from the pinned `speech-models-1` release through the update feed's GitHub access, SHA-256 checked, else from Hugging Face. It then warms it up so Core ML's Neural Engine compile is cached (load: about 0.3 s afterwards). Other languages use `SpeechAnalyzer` + `SpeechTranscriber` with `volatileResults` and `fastResults`, which report the newest words about once a second and finish sentences shortly after. `AudioTimeline` maps audio time to wall-clock time through the Source's capture timestamps, corrected by the link's clock offset, and starts a new anchor after a gap. Results update a `LiveTranscript` of finished segments plus the volatile tail. On macOS 14–15, `SFSpeechRecognizer` with on-device recognition stands in: one request per stretch of speech, ended at a 1.2 s pause or after 50 s.
4. **Asking.** When a question is sent, `ChatController` waits up to 0.8 s for the recognizer to catch up with the newest speech (`AudioPipeline.isCaughtUp`). It then attaches a `TranscriptExcerpt` to the message: segments that ended after the thread's previous excerpt, within the configured window, plus words still being recognized. `ContextBuilder` renders it as a timestamped block (with a note that it's speech-to-text) before the question, so every later question in the thread carries earlier transcripts too.

## Staying connected

The Studio keeps reconnecting to its Source with backoff (up to 15 s), and right away when the Source reappears on the network, after wake, and after a network change. Every reconnect is a new TCP connection to the Source's `BonjourListener`, so the listener sets no `newConnectionLimit`: in Network.framework that value counts down with every connection ever delivered (it isn't a cap on open ones), and a limit of 8 once left Sources deaf after a few sleeps. TCP still connected, but Tandem never answered the handshake. `ConnectionManager` caps concurrent sessions instead.

macOS can also keep Tandem off the local network while System Settings shows it allowed. Local network privacy recognizes an app by its main executable's UUID, and after an in-place update it only picks up the new one when the system-wide LaunchServices registers the app ("apps installed") or the Local Network settings change. Which of those happens after a swap is a race. A blocked connection to a Bonjour service just sits in *preparing*, so `LocalNetworkAccess` asks directly: a UDP flow (nothing is sent) to another host on the local subnet is `.ready` when allowed and waits with `localNetworkDenied` when not. The host must not be the router, a DNS server or a proxy, because traffic to those never needs permission (the router is usually the DNS server; 1.5.1 probed it and so never saw the block). `ConnectionManager` checks on start, after wake and network changes, and when a network attempt never reached the other Mac. While blocked, it re-checks every 5 s, shows a banner that opens Privacy & Security › Local Network (switching Tandem off and on rebuilds the rule), and reconnects as soon as access is back. A connection that the other Mac accepted but never answered gets its own message: Tandem there isn't responding.

## Updates between the Macs

`SharedMacUpdater` (Studio) and `PeerUpdateReceiver` (Source) keep the shared Mac on the Studio's version. Both hellos carry the `update` capability and the app version. When the Source is older (and the link isn't Bluetooth), the Studio zips its own signed bundle with `ditto` and sends `updateOffer` with the size and SHA-256. The Source accepts only from an approved viewer, only a newer version, only when its own copy is signed by a team. The package then travels as `updateChunk`s at bulk priority. `UpdatePackageAssembler` checks the size and checksum. `UpdateInstaller.prepare` checks the bundle ID, the version and the code signature against the Source's own Team ID, exactly as for GitHub updates. The app is swapped in place and relaunched with its launch arguments (`AppRelauncher`), reporting `updateStatus` phases along the way. The Studio retries the connection quickly while the Source restarts. A network path that appears while a Bluetooth attempt is pending now wins right away, instead of waiting out the Bluetooth timeout. Measured: offer to reconnected on the new version in about 3 s.

## AI context

`ContextBuilder` turns a thread into provider-neutral turns:
- images first, then a deterministic caption (source, title, capture time), then text;
- only the newest *N* screenshots are sent. The window moves in steps (e.g. 2) so the cached prompt prefix changes only every few turns; older screenshots become a text placeholder;
- failed/cancelled answers are skipped and consecutive user turns are merged;
- assistant turns replay text only (no thinking blocks), keeping history append-only.

**Claude Code** (the default provider) runs the user's `claude` CLI: `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --safe-mode --tools "" --no-session-persistence`, with `--model`, `--effort` and `--system-prompt`. `--safe-mode` keeps the user's hooks, plugins, MCP servers, skills and CLAUDE.md out, while the CLI's own subscription sign-in still works (`--bare` would not read it).

`ClaudeCodeSessionPool` keeps processes running between questions. Stdin stays open after an answer, so the CLI holds the conversation in memory. The next question in the same thread writes only the new user message, and the CLI's prompt cache covers everything before it (measured: 8–12k cached tokens per follow-up and a faster start). A session is reused only when the configuration (model, effort, instructions) and the thread's message IDs (`AIConversationKey`) match exactly what it has seen. A retry, deleted message, switched thread or changed setting starts over. A new conversation takes the **spare** process started ahead of time (launch costs about 0.4 s) and sends the history folded into a single stream-json user message: a labelled transcript with screenshots in place, ending with the new question. There's at most one live session and one spare (about 200 MB each). They're stopped after 20 and 10 minutes idle, when a question fails or is stopped, and when Tandem quits. The CLI relays Messages API stream events, parsed by the same `AnthropicStreamParser`. Its failures (signed out, model unavailable, usage limit) arrive as a synthetic assistant `error` plus a `result` with `is_error`, and are mapped to friendly errors. `ClaudeCodeLocator` finds the binary in the usual install locations or through the login shell, and reads `claude auth status`. This is why the app isn't sandboxed.

**Codex** runs `codex app-server` (JSON-RPC over stdio) through `CodexSessionPool`: one process, kept between questions, with a live thread per recent conversation. `CodexLaunch` starts it like `--safe-mode`. It disables every tool feature this Codex version reports in `codex features list` (shell, unified exec, code mode, apps, browser, computer use, image generation, multi-agent, plugins and more; unknown names are an error, so only known ones are passed). It sets `web_search="disabled"` and turns off each MCP server listed in `~/.codex/config.toml`. A test asking it to list the home folder confirmed it can't run anything. Threads start with `baseInstructions` = Tandem's system prompt, `ephemeral`, a `read-only` sandbox and `approvalPolicy: never`. Any approval request is declined anyway. Turns send text and screenshots as `localImage` files, which are deleted after the turn, plus the model, effort and reasoning summary. They stream `item/agentMessage/delta` and reasoning summary deltas, and end on `turn/completed`; Stop sends `turn/interrupt`. Reuse works as with Claude Code: the same conversation with the same history sends only the new message, and anything else starts a new thread with the history folded in. Codex error codes (`unauthorized`, `usageLimitExceeded`, `contextWindowExceeded`, …) become readable messages. The model list comes from `model/list`.

Anthropic API requests use `claude-opus-5-5` by default with adaptive thinking, `output_config.effort`, automatic prompt caching (`cache_control` at the top level) and server-side refusal fallbacks (`fallbacks: "default"`). Capabilities per model live in `ModelCatalog`; unsupported parameters are dropped and retried once if a server rejects them.

## Updates

`UpdateController` reads the latest release of the GitHub repository named by `TandemUpdateRepository` in Info.plist. It uses a saved token through the REST API, which never forwards the token across the asset download's redirect. Failing that it uses `gh release view` / `gh release download`, and otherwise the anonymous REST API (the repository is public). A release is offered when its tag's version is newer than `CFBundleShortVersionString`. **Update Now** unzips the release with `ditto` and checks the bundle ID and version. It then checks the code signature against `anchor apple generic`, the bundle ID and the running app's Team ID (`SecStaticCodeCheckValidity`, strict and nested). The app is swapped in place with `replaceItemAt`, or installed into Applications when running from a read-only disk image or a translocated path. A detached shell reopens it after this process exits. `scripts/release.sh` is the only way versions are published.

## Persistence

| Data | Where |
|---|---|
| Settings | `UserDefaults` (per profile) |
| API keys, pairing keys, GitHub update token | Keychain (generic passwords, per profile) |
| Paired device metadata | `UserDefaults` |
| Threads | `Application Support/Tandem/Threads/<id>.json`, coalesced atomic writes |
| Screenshots | Memory (LRU, 768 MB cap); optionally `Application Support/Tandem/Snapshots` |

## Testing

`Core` has 380+ XCTest cases, including:
- real-TCP loopback pairing and session tests;
- hardware encode → wire → decode round trips;
- man-in-the-middle, tamper and replay tests;
- SSE and provider stream fixtures;
- Markdown fuzzing;
- markup renderer pixel tests;
- Opus round trips, live on-device transcription of a spoken clip, transcript excerpting, and Claude Code live sessions driven by a fake CLI.

For the app, `scripts/dev-two-macs.sh` runs both roles on one Mac with a synthetic test pattern and a mock AI server; debug-only distributed-notification commands drive it (see README).
