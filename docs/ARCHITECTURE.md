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
| `Core/Sources/TandemCore/AI` | Provider-neutral types, SSE decoder, Anthropic Messages / OpenAI Responses / Chat Completions streaming clients, model catalog |
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

Anthropic requests use `claude-opus-5-5` by default with adaptive thinking, `output_config.effort`, automatic prompt caching (`cache_control` at the top level) and server-side refusal fallbacks (`fallbacks: "default"`). Capabilities per model live in `ModelCatalog`; unsupported parameters are dropped and retried once if a server rejects them.

## Persistence

| Data | Where |
|---|---|
| Settings | `UserDefaults` (per profile) |
| API keys, pairing keys | Keychain (generic passwords, per profile) |
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
