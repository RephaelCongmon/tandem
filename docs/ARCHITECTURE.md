# Tandem architecture

```
┌──────────────────────── Source Mac ────────────────────────┐        ┌──────────────────────── Studio Mac ─────────────────────────┐
│ CaptureService (ScreenCaptureKit / AVFoundation / debug)    │        │ LiveVideoRenderer → AVSampleBufferDisplayLayer (link queue) │
│   └─ frames → VideoFanout ─ H264Encoder (VideoToolbox, LL)  │        │ StudioEngine: stream requests, snapshots, automation         │
│                 └─ per-viewer ack flow control              │        │ ChatController: threads, composer, AI streaming              │
│ SourceEngine: viewers, status, snapshots, pushes, lock      │        │   └─ ContextBuilder → AIClient (Anthropic/OpenAI/compatible) │
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
| `Core/Sources/TandemCore/Media` | Low-latency `H264Encoder`, `VideoSampleBufferFactory`, `ImageCodec` (JPEG, thumbnails, change fingerprints) |
| `Core/Sources/TandemCore/AI` | Provider-neutral types, SSE decoder, Anthropic Messages / OpenAI Responses / Chat Completions streaming clients, the Claude Code client (runs the local `claude` CLI) and its locator, model catalog |
| `Core/Sources/TandemCore/Conversation` | Thread/message models, cache-friendly `ContextBuilder`, `ThreadStore`, `SnapshotStore` |
| `Core/Sources/TandemCore/Markdown` | Streaming-tolerant block parser |
| `Core/Sources/TandemUI` | Design system, `MarkdownView`, snapshot markup editor + renderer, global hotkeys + recorder |
| `App/Sources` | SwiftUI app: `AppModel`, `ConnectionManager`, `SourceEngine`, `StudioEngine`, `ChatController`, views, settings, menu bar, panels |

## Threading model

- **PeerLink** state is confined to its transport's serial queue. The main-actor `PeerConnection` wraps it; `LinkRouter` (also on the link queue) reassembles snapshots and routes messages:
  - video format/frames go straight to `LiveVideoRenderer` on the link queue — no main-thread hop per frame;
  - video acks go straight to `VideoFanout` on the link queue;
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

## AI context

`ContextBuilder` turns a thread into provider-neutral turns:
- images first, then a deterministic caption (source, title, capture time), then text;
- only the newest *N* screenshots are sent. The window moves in steps (e.g. 2) so the cached prompt prefix changes only every few turns; older screenshots become a text placeholder;
- failed/cancelled answers are skipped and consecutive user turns are merged;
- assistant turns replay text only (no thinking blocks), keeping history append-only.

**Claude Code** (the default provider) runs the user's `claude` CLI once per question. The command is `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --safe-mode --tools "" --no-session-persistence`, with `--model`, `--effort` and `--system-prompt`. `--safe-mode` keeps the user's hooks, plugins, MCP servers, skills and CLAUDE.md out, while the CLI's own subscription sign-in still works (`--bare` would not read it). The CLI can't be handed earlier assistant turns, so the conversation is folded into a single stream-json user message: a labelled transcript with screenshots in place, ending with the new question. The CLI relays Messages API stream events, parsed by the same `AnthropicStreamParser`. Its failures (signed out, model unavailable, usage limit) arrive as a synthetic assistant `error` plus a `result` with `is_error`, and are mapped to friendly errors. `ClaudeCodeLocator` finds the binary in the usual install locations or through the login shell, and reads `claude auth status`. This is why the app isn't sandboxed.

Anthropic API requests use `claude-opus-5-5` by default with adaptive thinking, `output_config.effort`, automatic prompt caching (`cache_control` at the top level) and server-side refusal fallbacks (`fallbacks: "default"`). Capabilities per model live in `ModelCatalog`; unsupported parameters are dropped and retried once if a server rejects them.

## Updates

`UpdateController` reads the latest release of the GitHub repository named by `TandemUpdateRepository` in Info.plist. It uses a saved token through the REST API, which never forwards the token across the asset download's redirect, or else `gh release view` / `gh release download`. A release is offered when its tag's version is newer than `CFBundleShortVersionString`. **Update Now** unzips the release with `ditto` and checks the bundle ID and version. It then checks the code signature against `anchor apple generic`, the bundle ID and the running app's Team ID (`SecStaticCodeCheckValidity`, strict and nested). The app is swapped in place with `replaceItemAt`, or installed into Applications when running from a read-only disk image or a translocated path. A detached shell reopens it after this process exits. `scripts/release.sh` is the only way versions are published.

## Persistence

| Data | Where |
|---|---|
| Settings | `UserDefaults` (per profile) |
| API keys, pairing keys, GitHub update token | Keychain (generic passwords, per profile) |
| Paired device metadata | `UserDefaults` |
| Threads | `Application Support/Tandem/Threads/<id>.json`, coalesced atomic writes |
| Screenshots | Memory (LRU, 768 MB cap); optionally `Application Support/Tandem/Snapshots` |

## Testing

`Core` has 300+ XCTest cases, including:
- real-TCP loopback pairing and session tests;
- hardware encode → wire → decode round trips;
- man-in-the-middle, tamper and replay tests;
- SSE and provider stream fixtures;
- Markdown fuzzing;
- markup renderer pixel tests.

For the app, `scripts/dev-two-macs.sh` runs both roles on one Mac with a synthetic test pattern and a mock AI server; debug-only distributed-notification commands drive it (see README).
