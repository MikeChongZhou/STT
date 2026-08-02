# Screen Time Guardian P2P Sync

Screen Time Guardian sync is moving from a user-selected cloud-drive folder to local-first P2P exchange.

## Goals

- No cloud-drive directory is required.
- Every platform stores the same `screen_session` records locally.
- P2P sync exchanges append/update records between trusted devices.
- Reports aggregate all synced records by date, device, and platform.
- Conflict resolution is deterministic and works offline.

## Transport

The shared application protocol exchanges the same encrypted `sync_snapshot` payload on every platform.

- LAN peer discovery: Bonjour/DNS-SD service `_stg-sync._tcp.local` over standard mDNS UDP port `5353`.
- Bonjour TXT records carry `device_id`, `device_name`, `platform`, `app_version`, `pairing_verifier`, and comma-separated `capabilities` so all platforms use the same pairing discovery contract.
- Payload transport: TCP with a 4-byte big-endian length prefix. The TCP port is dynamic and is published through the Bonjour SRV record. Current receivers accept frames up to 16 MiB.
- Encrypted envelope metadata may also carry `sender_tcp_port` so a receiver can show and later reconnect to an inbound peer even when Bonjour discovery is temporarily one-way.
- Payload encryption: AES-GCM using a key derived from the pairing code.
- Newer peers currently advertise `delta_sync`, `gzip`, and `history_compaction`. Capability names such as `weekly_manifest`, `daily_summary`, and `tombstone_ack` are reserved for compatible future expansion. A sender only uses an optional behavior when the receiver advertised the relevant capability.

Relay/cloud sync can be added later as a separate transport without changing the record schema.

## Pairing

Each device has a six-digit `p2p_pairing_code`. Devices are discovered when they use the same code, but data sync happens only after the remote device is approved in the local P2P settings. A packet from an unapproved device may be used to show that device as pending, but it must not be decrypted, merged, or answered with a local snapshot.

Discovered devices can be:

- `pending`: visible, waiting for the user to approve or reject.
- `trusted`: allowed to send and receive encrypted snapshots.
- `rejected`: ignored until the user approves it later.

The encryption key is:

```text
SHA256("STG-P2P-v1:" + pairing_code)
```

Each encrypted envelope also includes a short verifier:

```text
prefix16(hex(SHA256("STG-P2P-verify:" + pairing_code)))
```

The verifier is used only to avoid trying to decrypt packets from a different pairing group. The sync snapshot itself is sent only inside the AES-GCM payload.

## Encrypted Envelope

The TCP frame body is JSON:

```json
{
  "protocol_version": 1,
  "type": "sync_snapshot",
  "sender_device_id": "device-uuid",
  "sender_device_name": "Mike's MacBook",
  "platform": "macos",
  "sender_tcp_port": 54321,
  "capabilities": ["delta_sync", "gzip", "history_compaction"],
  "payload_encoding": "gzip",
  "pairing_verifier": "0123456789abcdef",
  "payload": "base64(aes-gcm-combined)",
  "sent_at_utc": "2026-07-10T12:00:00Z"
}
```

`payload` contains AES-GCM combined bytes. If `payload_encoding` is `gzip`, the snapshot JSON is gzip-compressed before encryption; if it is `plain` or omitted, the encrypted bytes are the raw snapshot JSON:

```text
nonce(12 bytes) + ciphertext + tag(16 bytes)
```

## Identity

Each device owns a stable `device_id` generated on first launch and stored separately from normal settings. A human-readable `device_name` can change without changing identity.

The `device_id` survives IP changes, Wi-Fi changes, app restarts, and settings rewrites. When platform APIs allow it, the first ID is derived from a device-stable source so app replacement or reinstall can keep the same identity:

- macOS: host UUID, then persisted `device_id`.
- iOS/iPadOS: `identifierForVendor`, then persisted `device_id`.
- Windows: MachineGuid-derived UUID, then persisted `device_id`.
- Android: Android ID-derived UUID, then persisted `device_id`.

If the operating system resets the underlying device identifier or the user erases all app/vendor data, a new identity may still be created.

## Conflict Rules

`screen_session.id` is globally unique. When the same `id` appears from two peers:

1. Keep the record with the greater `revision`.
2. If revisions match, keep the record with the later `updated_at_utc`.
3. If both match, keep the lexicographically greater JSON encoding to make the tie deterministic.

Devices only create or edit their own active sessions. Imported peer records are treated as read-only for timing, but may be re-shared to other trusted peers.

## Snapshot Shape

```json
{
  "protocol_version": 1,
  "capabilities": ["delta_sync", "gzip", "history_compaction"],
  "device": {
    "device_id": "device-uuid",
    "device_name": "Mike's MacBook",
    "platform": "macos",
    "app_version": "V1.0.9",
    "capabilities": ["delta_sync", "gzip", "history_compaction"],
    "updated_at_utc": "2026-07-10T12:00:00Z"
  },
  "cursor": {
    "since_updated_at_utc": "2026-07-01T00:00:00Z"
  },
  "sessions": []
}
```

When both peers support `delta_sync`, the sender uses the receiver's stored `last_sync_at_utc` minus a small overlap window as `cursor.since_updated_at_utc`. Older peers, unknown peers, and peers without `delta_sync` receive a full snapshot.

`sessions` contains `screen_session` records using the schema in `shared/sync/screen-session.schema.json`. `deleted_sessions` contains tombstone deletes and is filtered by the same cursor.

## Historical Data

Current week and previous week remain as detailed records in `sessions.json`. For records older than that two-week window, each platform now writes a local-only history archive under `history/`:

- `history/screen_sessions/screen_sessions_<week>.jsonl.gz`
- `history/weekly_summaries/weekly_usage_<week>.json`

These archive files are not synced. They are a safe compaction foundation: they preserve old detail locally and expose weekly summaries for future report acceleration. Detailed records are not physically deleted until all report paths can read summaries and all trusted devices have acknowledged the relevant historical window.

## Report Aggregation

Reports use all locally stored sessions, regardless of origin. The platform field is normalized to:

- `macos`
- `ios`
- `ipados`
- `windows`
- `android`
- `unknown`

The weekly report shows:

- Total average daily screen time across all platforms.
- Average daily screen time for each platform.
- Platform totals for the same week.
