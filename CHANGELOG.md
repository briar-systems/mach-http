# Changelog

## Unreleased

### Added

- Strict incremental HTTP/2 frame parsing and serialization with continuation sequencing and typed payload validation.
- Transactional HPACK decoding and encoding with the complete static table, dynamic table eviction, canonical integers, and RFC Huffman coding.
- Allocation-free HTTP/2 client and server connection engines with preface and settings negotiation, stream state, push, ping, reset, GOAWAY, and two-phase graceful drain.
- Completion-driven HTTP/2 reads and writes with partial I/O, copied outbound DATA, borrowed inbound events, generation-safe exchange binding, and retry handoff.
- Independent connection and stream flow control with consumption-driven window replenishment and bounded weighted DATA scheduling.
- HTTP/1 WebSocket upgrade and HTTP/2 or HTTP/3 extended CONNECT negotiation through the common service exchange.
- Allocation-free incremental WebSocket decoding and encoding with masking, fragmentation, streaming UTF-8, control frames, and close validation.
- Completion-driven WebSocket connections with exact borrowed-input release, copied-output ownership, partial I/O, backpressure, cancellation, timeout, and close outcomes.
- Incremental HTTP/3 frame, SETTINGS, control-stream, and unidirectional stream codecs with exact borrowed payload ownership.
- Complete QPACK static and dynamic tables, encoder and decoder instruction streams, all field-line representations, Huffman strings, blocked-section retry, and protected reference lifetimes.

### Security

- Bounded HPACK encoded input, Huffman expansion, strings, field count, decompressed field-list size, dynamic memory, entries, indices, and table updates independently.
- Rejected oversized, truncated, mis-scoped, self-dependent, invalidly padded, duplicate-setting, and zero-window HTTP/2 frames.
- Preserved HPACK state while refusing saturated streams and rejected invalid pseudo-fields, uppercase or connection-specific fields, hostile authorities, priority cycles, content-length mismatches, and DATA on bodyless responses.
- Enforced mask direction, reserved bits and opcodes, minimally encoded lengths, independent frame and message limits, fragment limits, valid close codes, and protocol-correct 1002, 1007, 1009, and 1006 outcomes.
- Rejected misplaced and reserved HTTP/3 frames, duplicate or reserved settings, duplicate critical streams, client push streams, malformed typed payloads, and truncated variable-length integers.
- Bounded QPACK table bytes, physical entries, wire instructions, encoded sections, blocked streams, outstanding sections, references, field count, decompressed field-list size, individual strings, and Huffman expansion independently.

## [0.3.0] - 2026-08-28

### Added

- Bounded compile-once routing with caller-owned route and segment storage.
- Exact, wildcard, port-specific, and host-independent authority matching.
- Literal, parameter, terminal catch-all, root, trailing-slash, asterisk-form, and authority-form routing.
- Deterministic host, path, and method precedence independent of registration order.
- Generation-bound captures, handler invocation, and caller-buffer percent decoding.
- Actionable conflict and capacity diagnostics with zero dispatch allocation.

### Security

- Rejected malformed encodings, encoded separators, backslashes, controls, dot segments, hostile authorities, duplicate Host fields, invalid methods, and invalid target forms before dispatch.

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
