# Tandem wire protocol (v1)

All traffic runs over an ordered, reliable byte stream: TCP on any interface, or a Bluetooth LE L2CAP channel.

## Framing

Every frame is `[UInt32 big-endian length][payload]`. Frames larger than 8 MiB are rejected. Snapshots are chunked at 128 KiB (16 KiB on Bluetooth).

## Discovery

- **Bonjour:** service type `_tandem._tcp`; instance name is the device name. TXT record: `id` (device UUID), `model`, `role` (`source`/`studio`), `v` (protocol version). The listener prefers port 47623. Browsing includes peer-to-peer Wi-Fi.
- **Bluetooth LE:** the Source advertises service `7A4D0001-3C1B-4F5E-9A8D-54414E44454D`. It publishes an L2CAP channel and exposes:
  - its PSM (`…0002`, UInt16 LE);
  - a JSON info characteristic (`…0003`: `{id, name, model, v}`).

## Handshake

Handshake frames are plaintext `[type][JSON]`. The initiator is the Studio. `H` is the running SHA-256 over every handshake frame, each prefixed by its 4-byte length.

### Session (already paired; long-term key `K`)

```
C → S  1 ClientHello  {v, mode:"session", id, name, model, eph, nonce}
S → C  2 ServerHello  {v, status:"ok"|"notPaired"|…, id, name, model, eph, nonce}
keys   = HKDF-SHA256(ikm: X25519(ephC, ephS) ‖ K, salt: H, info: "tandem/v1/session-keys", 96 B)
         → c2s key | s2c key | confirm key
C → S  record: Finished = HMAC(confirm, "tandem/v1/finished/client" ‖ H)
S → C  record: Finished = HMAC(confirm, "tandem/v1/finished/server" ‖ H)
```

This gives mutual authentication (both sides must know `K`) and forward secrecy (ephemeral X25519).

### Pairing (numeric comparison with commitment)

```
C → S  1 ClientHello  {v, mode:"pair", id, name, model, commit = SHA-256("tandem/v1/commit" ‖ ephC ‖ nonceC)}
S → C  2 ServerHello  {…, eph: ephS, nonce: nonceS}
C → S  3 ClientReveal {eph: ephC, nonce: nonceC}        (S verifies the commitment)
keys   = HKDF(ikm: X25519(ephC, ephS), salt: H, info: "tandem/v1/pair-keys")
code   = BE32(HMAC(confirm, "tandem/v1/sas")[0..<4]) mod 10⁶      → shown as "123 456" on both Macs
S → C  record: pairingDecision {accepted}               (after the Source user compares the codes)
C → S  record: pairingAck
K      = HKDF(X25519 secret, salt: H, info: "tandem/v1/pairing-key", 32 B)   stored in both Keychains
```

The initiator commits to its key before seeing the responder's, and the responder reveals before seeing the initiator's. A man-in-the-middle therefore cannot choose keys that make both sides' codes match, beyond a 10⁻⁶ chance per attempt. Each attempt needs a user decision, and a declined device is rate-limited.

## Records

After the handshake, every frame payload is `ciphertext ‖ tag` (ChaCha20-Poly1305). Nonces are implicit: 4 zero bytes followed by a 64-bit per-direction record counter. The plaintext is `[innerType][body]`: `0x10` handshake control (JSON) or `0x20` application message.

## Application messages

`[tag][body]`:

| Tag | Message | Body |
|---|---|---|
| 1 | control | JSON `ControlMessage` (below) |
| 2 | videoFormat | codec u8, width u16, height u16, count u8, then `count × (len u16, parameter set)` |
| 3 | videoFrame | flags u8 (bit 0 keyframe), sequence u32, pts µs u64, capturedAt ns u64, AVCC access unit |
| 4 | snapshotChunk | snapshot UUID (16 B), index u32, count u32, bytes |
| 6 | updateChunk | offer UUID (16 B), index u32, count u32, bytes |
| 5 | audioPacket | codec u8 (1 Opus, 2 PCM16 LE), sequence u32, sample rate u32, sample count u32, capturedAt ns u64 (Source clock, first sample), count u8, then `count × (len u16, frame)` |

Audio is mono 16 kHz. Opus frames are 20 ms (32 kbps), and a packet carries five of them (100 ms). PCM16 is the fallback when a Mac can't encode Opus.

### Control messages

- `hello`
- `sourceStatus`
- `streamRequest`
- `keyframeRequest`
- `videoAck`
- `snapshotRequest`, `snapshotHeader`, `snapshotUnchanged`, `snapshotFailed`
- `releaseFrozenSnapshot {id}` (Studio → Source): region selection finished; free the held still (see below)
- `sourceCatalogRequest`, `sourceCatalog`, `selectSource`
- `automationStatus`
- `replyMirror`
- `audioRequest {enabled, codecs}` (Studio → Source): start or stop sending computer audio; `codecs` lists what the Studio can decode, best first
- `audioStatus {state, message, codec, sampleRate}` (Source → Studio): `off`, `starting`, `live`, `paused`, `needsPermission`, `notAllowed` or `error`
- `updateOffer {id, version, build, byteCount, sha256}` (Studio → Source): a newer Tandem, as a zip of the signed app; `updateReply {id, accepted, reason}`; then `updateChunk`s; `updateStatus {id, phase, fraction, message}` (Source → Studio): `receiving`, `verifying`, `installing`, `restarting` or `failed`
- `ping`/`pong` (NTP-style clock offset)
- `goodbye`

Unknown messages are ignored, so newer peers can add them. `hello.capabilities` advertises optional features: `"audio"` means the peer can send (Source) or transcribe (Studio) computer audio; `"update"` means a Source installs updates its Studio sends (after checking the version and the developer signature). A Studio uses it to tell the user that an older Source needs an update. `"regions"` means a Source supports region snapshots.

### Region snapshots

The Studio selects regions on a frozen live view, and the Source sends only those regions, cropped from one native-resolution still. Nothing is captured when the user sends a question.

1. **Freeze.** The Studio stops showing new live frames (they are still acked) and sends `snapshotRequest {freeze: {displayedFrameNanos}}`, where `displayedFrameNanos` is the `capturedAtNanos` of the frame it holds. The Source captures a native still and keeps it in memory for this Studio (one per Studio, two minutes after last use).
   - If no newer live frame was captured since `displayedFrameNanos`, the still shows exactly what the Studio holds. The Source replies `snapshotUnchanged {id}` and sends no image: the user can drag on the held frame immediately, before the reply arrives.
   - Otherwise (the screen changed, or there was no live frame), it replies with a preview of the still (`maxDimension` of the request, JPEG) as an ordinary snapshot. The Studio shows it in place of the held frame, so the selection is always on the picture that gets cropped.
2. **Crop.** For each region, `snapshotRequest {crop: {frozenID, region: {x, y, width, height}}}`, with the freeze request's `id` and a region normalized to 0…1 (top-left origin). The Source crops the held still before scaling to `maxDimension` and sends the result, keeping the still's capture time. Several crops can come from one freeze.
3. **Release.** `releaseFrozenSnapshot {id}` frees the still. The Studio resumes its live view from a keyframe.

A crop never falls back to a newer or full screen: an unknown or expired `frozenID`, a region outside the picture, or sharing paused, locked, interrupted or switched to another source fails with `snapshotFailed`. A Studio sends these requests only to Sources that advertise `"regions"` (older Sources would ignore the fields and send the whole screen); with an older Source it adds a whole-screen snapshot and suggests updating.

### Scheduling

`PeerLink` keeps four queues:
- **control** (acks, requests, status): sent first;
- **audio** (audio packets): next, so transcripts stay live behind a large snapshot;
- **bulk** (snapshots): next;
- **video**: sent last.

A Source stops queuing audio for a link that already has 50 packets (5 s) waiting, rather than let stale audio pile up.

Records are sealed when they're handed to the transport, so counters always match wire order.
