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

### Control messages

- `hello`
- `sourceStatus`
- `streamRequest`
- `keyframeRequest`
- `videoAck`
- `snapshotRequest`, `snapshotHeader`, `snapshotUnchanged`, `snapshotFailed`
- `sourceCatalogRequest`, `sourceCatalog`, `selectSource`
- `automationStatus`
- `replyMirror`
- `ping`/`pong` (NTP-style clock offset)
- `goodbye`

Unknown messages are ignored, so newer peers can add them.

### Scheduling

`PeerLink` keeps three queues:
- **control** (acks, requests, status): sent first;
- **bulk** (snapshots): sent next;
- **video**: sent last.

Records are sealed when they're handed to the transport, so counters always match wire order.
