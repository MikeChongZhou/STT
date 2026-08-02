# Shared Sync Contract

This directory contains the JSON contract every Screen Time Guardian platform must use for P2P sync.

- `screen-session.schema.json` defines the durable screen usage unit.
- `sync-snapshot.schema.json` defines a P2P exchange payload.
- `encrypted-envelope.schema.json` defines the encrypted transport envelope that carries a snapshot.

The macOS, iOS, Windows, and Android implementations write these records locally and exchange encrypted `sync_snapshot` payloads through the P2P transport.

Version 1.0.9 adds optional capability negotiation. Peers advertise supported features in Bonjour TXT, encrypted envelopes, and snapshots. Current cross-platform capabilities include incremental sync (`delta_sync`), gzip-compressed encrypted payloads (`gzip`), and local-only historical archive/summary support (`history_compaction`). Capability names such as `weekly_manifest`, `daily_summary`, and `tombstone_ack` are reserved for compatible future expansion. Optional fields must be ignored when unsupported.
