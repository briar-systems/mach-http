# Changelog

## [Unreleased]

### Changed

- **Breaking.** `http.h3.connection.Storage` requires a caller-owned pending-release array and `Config` requires its `max_pending_release` bound. Every caller of `http.h3.connection.init` must supply both.

### Fixed

- A rejected HTTP/3 request no longer fails the connection. `release` means the stream is settled on the wire, which a stream this side has just reset cannot be until the peer acknowledges it, so blocked releases are now retried from `process` instead of being treated as transport failures. Exhausting the pending-release bound is a defined excessive-load failure.
- A QPACK Stream Cancellation naming a stream with no outstanding section is a no-op rather than a decoder-stream connection error, matching RFC 9204, which defines that error only for Section Acknowledgment. A peer rejecting a request always cancels, whether or not the field section used the dynamic table.
- The in-file HTTP/3 transport fake models the real release precondition instead of accepting any live stream, so its results cannot disagree with the driver again.

## [0.4.0] - 2026-08-28

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
- Bounded client protocol selection, DNS resolution, connection pooling, retry classification, cancellation scopes, and complete exchange lifecycle management.
- Allocation-free HTTP/3 client and server engines with critical streams, request multiplexing, common exchange binding, cancellation, GOAWAY, and two-stage graceful close.
- Split-delivery QUIC stream adapter contract with copied partial writes, explicit receive credit, generation-safe handles, and exact final-size validation.
- Qualification of the HTTP/3 engine against the real `mach-quic` connection driver over a loopback protocol, covering bodies in both directions, sustained multiplexing, QPACK-blocked credit retention, reset, cancellation, GOAWAY, datagram loss, and partial I/O.

### Security

- Bounded HPACK encoded input, Huffman expansion, strings, field count, decompressed field-list size, dynamic memory, entries, indices, and table updates independently.
- Rejected oversized, truncated, mis-scoped, self-dependent, invalidly padded, duplicate-setting, and zero-window HTTP/2 frames.
- Preserved HPACK state while refusing saturated streams and rejected invalid pseudo-fields, uppercase or connection-specific fields, hostile authorities, priority cycles, content-length mismatches, and DATA on bodyless responses.
- Enforced mask direction, reserved bits and opcodes, minimally encoded lengths, independent frame and message limits, fragment limits, valid close codes, and protocol-correct 1002, 1007, 1009, and 1006 outcomes.
- Rejected misplaced and reserved HTTP/3 frames, duplicate or reserved settings, duplicate critical streams, client push streams, malformed typed payloads, and truncated variable-length integers.
- Bounded QPACK table bytes, physical entries, wire instructions, encoded sections, blocked streams, outstanding sections, references, field count, decompressed field-list size, individual strings, and Huffman expansion independently.
- Required terminal request and response bodies before exchange completion, forbade reuse after upgrades and tunnels, and rejected overlapping ownership descriptors before dereference.
- Enforced independent HTTP/3 request, response, informational, trailer, target, body byte, DATA frame, and stream admission limits.
- Rejected duplicate or closed critical streams, invalid frame sequences, hostile final sizes, blocked-stream saturation, QPACK cancellation abuse, nonmonotonic GOAWAY, and stale transport outcomes.

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
