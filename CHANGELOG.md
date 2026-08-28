# Changelog

## [0.2.1] - 2026-08-28

### Fixed

- Synchronized the exported library version with the package release version.

### Added

- Added a release check that rejects manifest and exported version drift.

## [0.2.0] - 2026-08-28

### Added

- Version-neutral bounded request, response, informational, trailer, and streaming body exchange.
- Completion-driven plaintext and secured ordered-byte transport adapters.
- Strict incremental HTTP/1.0 and HTTP/1.1 request and response parsing.
- Bounded HTTP/1 serialization, framing, trailers, and close-delimited bodies.
- Bounded HTTP/1 client and server pipeline engines with backpressure and exact slot ownership.
- Upgrade and CONNECT tunnel handoff with exact unread-byte preservation.
- Absolute connection deadlines, cancellation, graceful drain, and close sequencing.

### Changed

- Pinned `mach-std` to `v0.29.0` for hierarchical cancellation and completion-based I/O.

## [0.1.0] - 2026-08-27

### Added

- Initial HTTP protocol, transport, routing, client, server, and WebSocket contracts.
